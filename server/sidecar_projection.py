"""Field-scoped sidecar projection shared with the app's stable flock protocol."""
from __future__ import annotations

from contextlib import contextmanager
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
from uuid import uuid4

import yaml

from sidecar_writer import yaml_value


class ProjectionError(RuntimeError):
    pass


class ProjectionConflict(ProjectionError):
    pass


def _sync_parent(path: Path) -> None:
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_durable(path: Path, data: bytes, *, exclusive=False) -> None:
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_uint16), ("commonattr", ctypes.c_uint32),
                ("volattr", ctypes.c_uint32), ("dirattr", ctypes.c_uint32), ("fileattr", ctypes.c_uint32), ("forkattr", ctypes.c_uint32)]


_ATTR_CMN_ADDEDTIME = 0x10000000


def _libc():
    libc = ctypes.CDLL(None, use_errno=True)
    for name in ("getattrlist", "setattrlist"):
        getattr(libc, name).argtypes = [ctypes.c_char_p, ctypes.POINTER(_AttrList), ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint]
        getattr(libc, name).restype = ctypes.c_int
    return libc


def _added_time(path: Path):
    """Finder's Date Added as a packed timespec, or None where the volume has none."""
    attributes = _AttrList(5, 0, _ATTR_CMN_ADDEDTIME, 0, 0, 0, 0)
    buffer = ctypes.create_string_buffer(64)
    if _libc().getattrlist(os.fsencode(path), ctypes.byref(attributes), buffer, len(buffer), 0) != 0:
        return None
    length = struct.unpack("=I", buffer.raw[:4])[0]
    return buffer.raw[4:20] if length >= 20 else None


def _set_added_time(path: Path, stamp: bytes) -> bool:
    attributes = _AttrList(5, 0, _ATTR_CMN_ADDEDTIME, 0, 0, 0, 0)
    return _libc().setattrlist(os.fsencode(path), ctypes.byref(attributes), stamp, len(stamp), 0) == 0


def _copy_metadata(source: Path, destination: Path) -> None:
    if sys.platform == "darwin":
        # COPYFILE_ALL = ACL | STAT | XATTR | DATA.
        libc = ctypes.CDLL(None, use_errno=True)
        copyfile = libc.copyfile
        copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
        copyfile.restype = ctypes.c_int
        if copyfile(os.fsencode(source), os.fsencode(destination), None, 15) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        # copyfile doesn't carry Finder's Date Added. A rename within the folder keeps
        # what's set here; a volume without the attribute just keeps its own date.
        stamp = _added_time(source)
        if stamp is not None:
            _set_added_time(destination, stamp)
    else:
        shutil.copy2(source, destination)


@contextmanager
def locked_sidecar(path: Path):
    path = path.parent.resolve() / path.name
    fd = os.open(path.with_name(f".{path.name}.nodraw-lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if path.is_symlink():
            raise ProjectionError(f"Refusing symbolic-link sidecar: {path}")
        yield path
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def parse_sidecar(content: str):
    match = re.match(r"\A\ufeff?---[^\S\r\n]*(\r?\n)(.*?)(^---[^\S\r\n]*(?:\r?\n|$))", content, re.S | re.M)
    if not match:
        raise ProjectionError("Sidecar has no complete YAML frontmatter")
    header = match.group(2)
    node = yaml.compose(header)
    if node is not None and not isinstance(node, yaml.MappingNode):
        raise ProjectionError("Sidecar frontmatter must be a mapping")
    keys = [key.value for key, _ in node.value] if node else []
    if len(keys) != len(set(keys)):
        raise ProjectionError("Sidecar has duplicate frontmatter keys")
    values = yaml.safe_load(header) or {}
    return match, header, node, values


# Foundation's CharacterSet.whitespaces, used by MetadataParser for tags.
_TAG_WHITESPACE = "\t \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u200b\u202f\u205f\u3000"


def user_values(values: dict) -> dict:
    tags = values.get("tags")
    if isinstance(tags, str):
        tags = [tag.strip(_TAG_WHITESPACE) for tag in tags.split(",")]
        tags = [tag for tag in tags if tag]
    elif isinstance(tags, list) and all(isinstance(tag, str) for tag in tags):
        tags = [tag.strip(_TAG_WHITESPACE) for tag in tags]
    else:
        tags = []
    notes = values.get("notes")
    if not isinstance(notes, str):
        notes = values.get("description")
    return {"tags": tags, "notes": notes if isinstance(notes, str) else ""}


def read_base(path: Path) -> dict:
    with locked_sidecar(path) as canonical:
        return user_values(parse_sidecar(canonical.read_bytes().decode("utf-8"))[3])


def project(path: Path, fields: dict, bases: dict) -> None:
    with locked_sidecar(path) as canonical:
        original = canonical.read_bytes()
        content = original.decode("utf-8")
        match, header, node, values = parse_sidecar(content)
        current = user_values(values)
        for field, proposed in fields.items():
            if current[field] != proposed and current[field] not in bases.get(field, [current[field]]):
                raise ProjectionConflict(json.dumps({"field": field, "base": bases[field], "current": current[field], "proposed": proposed}, ensure_ascii=False))
        newline = match.group(1)
        # An empty note masks a description; without that provenance, omit it.
        remove_notes = fields.get("notes") == "" and "description" not in values
        edits = []
        existing = set()
        for key, value in node.value if node else []:
            if key.value not in fields:
                continue
            if value.end_mark.index < key.start_mark.index:
                raise ProjectionError("An aliased metadata field needs an explicit value before editing")
            existing.add(key.value)
            if key.value == "notes" and remove_notes:
                end = value.end_mark.index
                if not header[key.start_mark.index:end].endswith("\n"):
                    end = header.find("\n", end) + 1 or len(header)
                edits.append((key.start_mark.index, end, ""))
                continue
            replacement = f"{key.value}: {yaml_value(fields[key.value])}"
            old = header[key.start_mark.index:value.end_mark.index]
            if old.endswith("\n"):
                replacement += newline
            edits.append((key.start_mark.index, value.end_mark.index, replacement))
        for start, end, replacement in reversed(edits):
            header = header[:start] + replacement + header[end:]
        for key, value in fields.items():
            if key == "notes" and remove_notes:
                continue
            if key not in existing:
                if header and not header.endswith("\n"):
                    header += newline
                header += f"{key}: {yaml_value(value)}{newline}"
        replacement = (content[:match.start(2)] + header + content[match.end(2):]).encode("utf-8")
        # Editing an anchored field must not leave dangling aliases in unknown
        # fields. Reject that edit durably instead of publishing invalid YAML.
        parse_sidecar(replacement.decode("utf-8"))
        if replacement == original:
            return
        # Copy metadata to the replacement (Finder Date Added, ACLs, xattrs).
        # Never expose a truncated original to readers that do not take the lock.
        backup = canonical.with_name(f".{canonical.name}.nodraw-backup-{hashlib.sha256(original).hexdigest()}")
        if not backup.exists():
            _write_durable(backup, original, exclusive=True)
        staged = canonical.with_name(f".{canonical.name}.nodraw-stage-{uuid4().hex}")
        try:
            _copy_metadata(canonical, staged)
            _write_durable(staged, replacement)
            _sync_parent(canonical)
            if canonical.read_bytes() != original:
                raise ProjectionConflict("Sidecar changed outside the writer lock")
            os.replace(staged, canonical)
            _sync_parent(canonical)
        finally:
            staged.unlink(missing_ok=True)
