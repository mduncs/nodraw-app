#!/usr/bin/env python3
"""Recoverable offline backfill for reviewed Mac-incompatible media.

The tool deliberately has no discovery mode that turns pipeline failures into
mutation candidates.  ``plan`` accepts an exact, human-reviewed allowlist of
item IDs, media indices, and source SHA-256 values.  Mutating commands refuse
to run while NoDraw, its database, or the download server is active.

The live archive is never used by the test suite.  Tests construct temporary
archives and inject a fake normalizer/process guard.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import enum
import hashlib
import importlib
import json
import mimetypes
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
from pathlib import Path
from typing import Any, Iterable, Mapping, Protocol, Sequence


MANIFEST_SCHEMA_VERSION = 1
ALLOWLIST_SCHEMA_VERSION = 1
JOURNAL_SCHEMA_VERSION = 1


class BackfillError(RuntimeError):
    """A fail-closed validation or backfill error."""


class NormalizerProtocol(Protocol):
    def probe(self, path: Path) -> Any: ...

    def classify(self, probe: Any) -> Any: ...

    def normalize_staged(self, path: Path) -> Any: ...


class ServerNormalizer:
    """Thin adapter around server/media_normalization.py.

    Import is lazy so read-only manifest/status commands and unit tests do not
    require ffmpeg or the production normalizer module.
    """

    def __init__(self) -> None:
        server_dir = Path(__file__).resolve().parents[1]
        if str(server_dir) not in sys.path:
            sys.path.insert(0, str(server_dir))
        try:
            module = importlib.import_module("media_normalization")
        except ImportError as exc:
            raise BackfillError(
                "server/media_normalization.py is unavailable; cannot probe or normalize"
            ) from exc
        self._normalizer = module.MediaNormalizer()
        self._classify = module.classify_media
        self._normalization_error = module.MediaNormalizationError

    def probe(self, path: Path) -> Any:
        try:
            return self._normalizer.probe(path)
        except self._normalization_error as exc:
            raise BackfillError(str(exc)) from exc

    def classify(self, probe: Any) -> Any:
        try:
            return self._classify(probe)
        except self._normalization_error as exc:
            raise BackfillError(str(exc)) from exc

    def normalize_staged(self, path: Path) -> Any:
        try:
            return self._normalizer.normalize_staged(path)
        except self._normalization_error as exc:
            raise BackfillError(str(exc)) from exc


@dataclasses.dataclass(frozen=True)
class DerivedPolicy:
    name: str
    reset_general_pipeline: bool
    reset_vision: bool
    reset_video_understanding: bool
    preserve_video_understanding: bool
    preserve_transcription: bool
    preserve_generated_caption: bool
    invalidate_thumbnails: bool
    invalidate_pipeline_store: bool
    requires_stream_equivalence: bool


POLICIES: dict[str, DerivedPolicy] = {
    # WebM is the intended WebKit playback representation.  The current native
    # video-analysis and transcription lanes are AVFoundation-only, so proven
    # stream/timeline equivalence preserves their terminal/complete state.
    "vp9_webm_stream_equivalent": DerivedPolicy(
        name="vp9_webm_stream_equivalent",
        reset_general_pipeline=False,
        reset_vision=False,
        reset_video_understanding=False,
        preserve_video_understanding=True,
        preserve_transcription=True,
        preserve_generated_caption=True,
        invalidate_thumbnails=True,
        invalidate_pipeline_store=False,
        requires_stream_equivalence=True,
    ),
    # A hev1 -> hvc1 tag repair keeps encoded streams and pixels identical.  It
    # specifically invalidates the AVFoundation video-understanding failure.
    "hevc_tag_repair_stream_equivalent": DerivedPolicy(
        name="hevc_tag_repair_stream_equivalent",
        reset_general_pipeline=False,
        reset_vision=False,
        reset_video_understanding=True,
        preserve_video_understanding=False,
        preserve_transcription=True,
        preserve_generated_caption=True,
        invalidate_thumbnails=False,
        invalidate_pipeline_store=False,
        requires_stream_equivalence=True,
    ),
    # The source is an animated GIF payload with a false .mp4 suffix.  There is
    # no audio to transcribe; only visual/container-derived state is invalid.
    "gif_visual_conversion": DerivedPolicy(
        name="gif_visual_conversion",
        reset_general_pipeline=True,
        reset_vision=True,
        reset_video_understanding=True,
        preserve_video_understanding=False,
        preserve_transcription=True,
        preserve_generated_caption=True,
        invalidate_thumbnails=True,
        invalidate_pipeline_store=True,
        requires_stream_equivalence=False,
    ),
}


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, enum.Enum):
        return _jsonable(value.value)
    if dataclasses.is_dataclass(value):
        return _jsonable(dataclasses.asdict(value))
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (set, frozenset)):
        return sorted((_jsonable(item) for item in value), key=repr)
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if hasattr(value, "provenance") and callable(value.provenance):
        return _jsonable(value.provenance())
    if hasattr(value, "__dict__"):
        return _jsonable(vars(value))
    return str(value)


def _matches_subset(actual: Any, expected: Any, path: str = "$") -> None:
    if isinstance(expected, Mapping):
        if not isinstance(actual, Mapping):
            raise BackfillError(f"proof mismatch at {path}: expected an object")
        for key, expected_value in expected.items():
            if key not in actual:
                raise BackfillError(f"proof mismatch at {path}: missing {key!r}")
            _matches_subset(actual[key], expected_value, f"{path}.{key}")
        return
    if isinstance(expected, list):
        if actual != expected:
            raise BackfillError(f"proof mismatch at {path}: {actual!r} != {expected!r}")
        return
    if actual != expected:
        raise BackfillError(f"proof mismatch at {path}: {actual!r} != {expected!r}")


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        _jsonable(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def _stream_signature(metadata: Mapping[str, Any]) -> list[tuple[Any, ...]]:
    streams = metadata.get("streams")
    if not isinstance(streams, list):
        raise BackfillError("equivalence provenance has no stream list")
    signatures: list[tuple[Any, ...]] = []
    for stream in streams:
        if not isinstance(stream, Mapping) or stream.get("type") not in {"video", "audio"}:
            continue
        signatures.append(
            (
                stream.get("type"),
                stream.get("codec"),
                stream.get("width"),
                stream.get("height"),
            )
        )
    return sorted(signatures, key=repr)


def _require_stream_equivalence(
    policy_name: str, plan: Mapping[str, Any], provenance: Mapping[str, Any]
) -> None:
    """Prove the stream-copy policies instead of trusting a reviewer label."""
    if not POLICIES[policy_name].requires_stream_equivalence:
        return
    expected_operation = {
        "vp9_webm_stream_equivalent": "remux_vp_video_to_webm",
        "hevc_tag_repair_stream_equivalent": "repair_hevc_hvc1_tag",
    }[policy_name]
    if (
        plan.get("operation") != expected_operation
        or plan.get("video_codec") != "copy"
        or plan.get("audio_codec") != "copy"
        or plan.get("lossy") is not False
        or provenance.get("operation") != expected_operation
        or provenance.get("lossy") is not False
    ):
        raise BackfillError(f"{policy_name} lacks a lossless stream-copy proof")
    before = provenance.get("source")
    after = provenance.get("output")
    if not isinstance(before, Mapping) or not isinstance(after, Mapping):
        raise BackfillError(f"{policy_name} lacks before/after probe provenance")
    if _stream_signature(before) != _stream_signature(after):
        raise BackfillError(f"{policy_name} changed audio/video stream identity")
    before_duration = before.get("duration_seconds")
    after_duration = after.get("duration_seconds")
    if not isinstance(before_duration, (int, float)) or not isinstance(
        after_duration, (int, float)
    ):
        raise BackfillError(f"{policy_name} lacks timeline duration proof")
    if abs(float(before_duration) - float(after_duration)) > 0.1:
        raise BackfillError(f"{policy_name} changed the media timeline")


def _row_value(value: Any) -> Any:
    if isinstance(value, bytes):
        return {"blob_hex": value.hex()}
    return value


def _table_snapshot(
    connection: sqlite3.Connection,
    table: str,
    item_column: str,
    item_id: str,
    *,
    excluded_columns: Iterable[str] = (),
) -> dict[str, Any]:
    columns = [
        row[1]
        for row in connection.execute(f'PRAGMA table_info("{table}")')
        if row[1] not in set(excluded_columns)
    ]
    if not columns:
        raise BackfillError(f"required table is absent or empty: {table}")
    quoted = ", ".join(f'"{column}"' for column in columns)
    rows = [
        [_row_value(value) for value in row]
        for row in connection.execute(
            f'SELECT {quoted} FROM "{table}" WHERE "{item_column}" = ?', (item_id,)
        )
    ]
    rows.sort(key=lambda row: _canonical_json(row))
    payload = {"columns": columns, "rows": rows}
    return {"count": len(rows), "sha256": _sha256_bytes(_canonical_json(payload))}


def _selected_fields(
    connection: sqlite3.Connection, item_id: str, fields: Sequence[str]
) -> dict[str, Any]:
    quoted = ", ".join(f'"{field}"' for field in fields)
    row = connection.execute(
        f'SELECT {quoted} FROM media_items WHERE id = ?', (item_id,)
    ).fetchone()
    if row is None:
        raise BackfillError(f"item disappeared while snapshotting: {item_id}")
    return {field: _row_value(value) for field, value in zip(fields, row, strict=True)}


def _policy_snapshot(
    connection: sqlite3.Connection, item_id: str, policy: DerivedPolicy
) -> dict[str, Any]:
    snapshot: dict[str, Any] = {}
    if policy.preserve_transcription:
        snapshot["transcription_fields"] = _selected_fields(
            connection,
            item_id,
            (
                "transcription_status",
                "transcription_version",
                "transcription_retry_count",
                "transcription_last_error",
                "transcription_failed_at",
            ),
        )
        snapshot["transcript_segments"] = _table_snapshot(
            connection, "transcript_segments", "item_id", item_id, excluded_columns=("source_path",)
        )
    if policy.preserve_generated_caption:
        snapshot["generated_caption"] = _selected_fields(
            connection, item_id, ("generatedCaption",)
        )
    if policy.preserve_video_understanding:
        snapshot["video_fields"] = _selected_fields(
            connection,
            item_id,
            (
                "video_understanding_status",
                "video_understanding_version",
                "video_understanding_retry_count",
                "video_understanding_last_error",
                "video_understanding_failed_at",
            ),
        )
        snapshot["video_segments"] = _table_snapshot(
            connection, "video_segments", "item_id", item_id, excluded_columns=("source_path",)
        )
    if not policy.reset_general_pipeline:
        snapshot["pipeline_fields"] = _selected_fields(
            connection,
            item_id,
            (
                "pipeline_status",
                "pipeline_version",
                "pipeline_retry_count",
                "pipeline_last_error",
                "pipeline_failed_at",
            ),
        )
        snapshot["media_attributes"] = _table_snapshot(
            connection, "media_attributes", "item_id", item_id
        )
        snapshot["clip_vectors"] = _table_snapshot(
            connection, "clip_vectors", "itemId", item_id
        )
    if not policy.reset_vision:
        snapshot["vision_fields"] = _selected_fields(
            connection,
            item_id,
            (
                "ocrText",
                "ocrBoundingBoxesJSON",
                "dominantColorsJSON",
                "perceptualHash",
                "saliencyRectJSON",
            ),
        )
        snapshot["media_file_ocr"] = _table_snapshot(
            connection, "media_file_ocr", "item_id", item_id
        )
        snapshot["media_colors"] = _table_snapshot(
            connection, "media_colors", "item_id", item_id
        )
    return snapshot


def _verify_policy_snapshot(
    connection: sqlite3.Connection,
    item_id: str,
    policy: DerivedPolicy,
    expected: Mapping[str, Any],
) -> None:
    actual = _policy_snapshot(connection, item_id, policy)
    if actual != expected:
        raise BackfillError(f"preserved derived state changed for {item_id}")


def _json_references(value: Any, source_path: str) -> bool:
    old_name = Path(source_path).name
    if isinstance(value, str):
        return value in {source_path, old_name, Path(source_path).resolve().as_uri()}
    if isinstance(value, list):
        return any(_json_references(item, source_path) for item in value)
    if isinstance(value, Mapping):
        return any(_json_references(item, source_path) for item in value.values())
    return False


def _retarget_json(value: Any, old_path: str, new_path: str) -> Any:
    old_name = Path(old_path).name
    new_name = Path(new_path).name
    old_uri = Path(old_path).resolve().as_uri()
    new_uri = Path(new_path).resolve().as_uri()
    if isinstance(value, str):
        return {old_path: new_path, old_name: new_name, old_uri: new_uri}.get(value, value)
    if isinstance(value, list):
        return [_retarget_json(item, old_path, new_path) for item in value]
    if isinstance(value, Mapping):
        return {key: _retarget_json(item, old_path, new_path) for key, item in value.items()}
    return value


def _normalization_metadata(
    metadata: Mapping[str, Any] | None,
    *,
    run_id: str,
    item_id: str,
    old_path: str,
    new_path: str,
    source_sha256: str,
    output_sha256: str,
    provenance: Mapping[str, Any],
) -> dict[str, Any]:
    updated = _retarget_json(dict(metadata or {}), old_path, new_path)
    records = updated.get("nodraw_media_normalizations") or []
    if not isinstance(records, list):
        raise BackfillError("server metadata normalization field is not a list")
    records = [
        record
        for record in records
        if not isinstance(record, Mapping)
        or (record.get("run_id"), record.get("item_id")) != (run_id, item_id)
    ]
    records.append(
        {
            "run_id": run_id,
            "item_id": item_id,
            "original_name": Path(old_path).name,
            "normalized_name": Path(new_path).name,
            "source_sha256": source_sha256,
            "output_sha256": output_sha256,
            "provenance": provenance,
        }
    )
    updated["nodraw_media_normalizations"] = records
    return updated


def _has_run_metadata(metadata: Mapping[str, Any], run_id: str, item_id: str) -> bool:
    records = metadata.get("nodraw_media_normalizations")
    return isinstance(records, list) and any(
        isinstance(record, Mapping)
        and record.get("run_id") == run_id
        and record.get("item_id") == item_id
        for record in records
    )


def _atomic_write(path: Path, data: bytes, *, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(temp, mode)
        os.replace(temp, path)
        _fsync_directory(path.parent)
    finally:
        temp.unlink(missing_ok=True)


def _copy_or_link(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if _sha256(destination) != _sha256(source):
            raise BackfillError(f"backup already exists with different bytes: {destination}")
        return
    # Recovery artifacts must not share an inode with mutable live files.
    shutil.copy2(source, destination)
    with destination.open("rb") as handle:
        os.fsync(handle.fileno())
    _fsync_directory(destination.parent)


def _fsync_directory(path: Path) -> None:
    directory_fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _atomic_install(
    source: Path,
    destination: Path,
    metadata_source: Path,
    *,
    hard_link: bool = False,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.parent / f".{destination.name}.{uuid.uuid4().hex}.nodraw-partial"
    try:
        if hard_link:
            os.link(source, temp)
        else:
            shutil.copy2(source, temp)
        shutil.copystat(metadata_source, temp, follow_symlinks=False)
        with temp.open("rb") as handle:
            os.fsync(handle.fileno())
        os.replace(temp, destination)
        _fsync_directory(destination.parent)
    finally:
        temp.unlink(missing_ok=True)


def _connect_ro(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.execute("PRAGMA query_only=ON")
    return connection


def _database_backup(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = destination.with_suffix(destination.suffix + ".tmp")
    temp.unlink(missing_ok=True)
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    target_db = sqlite3.connect(temp)
    try:
        source_db.backup(target_db)
        result = target_db.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            raise BackfillError("database backup failed integrity_check")
    finally:
        target_db.close()
        source_db.close()
    os.replace(temp, destination)
    with destination.open("rb") as handle:
        os.fsync(handle.fileno())
    _fsync_directory(destination.parent)


def _database_restore(backup: Path, destination: Path) -> None:
    source_db = sqlite3.connect(f"file:{backup}?mode=ro", uri=True)
    target_db = sqlite3.connect(destination)
    try:
        source_db.backup(target_db)
        result = target_db.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            raise BackfillError("restored database failed integrity_check")
    finally:
        target_db.close()
        source_db.close()
    with destination.open("rb") as handle:
        os.fsync(handle.fileno())
    _fsync_directory(destination.parent)


class ProcessGuard:
    """Fail closed unless all archive/database writers are offline."""

    def assert_offline(self, database_paths: Sequence[Path]) -> None:
        blockers: list[str] = []
        if self._app_may_be_running():
            blockers.append("NoDraw is running (ArchiveWatcher may be active)")
        for database_path in database_paths:
            if self._database_is_open(database_path):
                blockers.append(f"database has open file handles: {database_path}")
        if self._download_server_running():
            blockers.append("the NoDraw download server is running")
        if blockers:
            raise BackfillError("offline precondition failed: " + "; ".join(blockers))

    @staticmethod
    def _app_may_be_running() -> bool:
        try:
            result = subprocess.run(
                ["pgrep", "-x", "NoDraw"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return True
        if result.returncode == 0:
            return bool(result.stdout.strip())
        return result.returncode != 1

    @classmethod
    def _database_is_open(cls, path: Path) -> bool:
        for candidate in (path, Path(f"{path}-wal"), Path(f"{path}-shm")):
            try:
                result = subprocess.run(
                    ["lsof", "-t", str(candidate)],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired):
                # lsof is a required safety dependency for mutation.
                return True
            pids = {line.strip() for line in result.stdout.splitlines() if line.strip()}
            pids.discard(str(os.getpid()))
            if pids or result.returncode not in (0, 1):
                return True
        return False

    @staticmethod
    def _download_server_running() -> bool:
        labels = ("com.nodraw.download-server", "com.mediaviewer.download-server")
        domain = f"gui/{os.getuid()}"
        for label in labels:
            try:
                result = subprocess.run(
                    ["launchctl", "print", f"{domain}/{label}"],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
            except (FileNotFoundError, subprocess.TimeoutExpired):
                return True
            # A loaded KeepAlive agent can relaunch between the guard and the
            # transaction; require it to be booted out, not merely idle.
            if result.returncode == 0:
                return True
        return False


class SafeProcessGuard(ProcessGuard):
    """Test seam; production CLI never exposes a bypass flag."""

    def assert_offline(self, database_paths: Sequence[Path]) -> None:
        return


class RunJournal:
    VALID_PHASES = {
        "created",
        "backed_up",
        "normalized",
        "files_published",
        "sidecars_published",
        "database_committed",
        "caches_invalidated",
        "verified",
        "complete",
        "rolled_back",
    }

    def __init__(self, path: Path, manifest_sha256: str) -> None:
        self.path = path
        if path.exists():
            self.data = json.loads(path.read_text(encoding="utf-8"))
            if self.data.get("manifest_sha256") != manifest_sha256:
                raise BackfillError("journal belongs to a different manifest")
            if (
                self.data.get("schema_version") != JOURNAL_SCHEMA_VERSION
                or self.data.get("phase") not in self.VALID_PHASES
                or not isinstance(self.data.get("results"), dict)
            ):
                raise BackfillError("journal schema or phase is invalid")
        else:
            self.data = {
                "schema_version": JOURNAL_SCHEMA_VERSION,
                "manifest_sha256": manifest_sha256,
                "phase": "created",
                "results": {},
                "error": None,
                "updated_at": _utc_now(),
            }
            self.save()

    @property
    def phase(self) -> str:
        return str(self.data["phase"])

    def advance(self, phase: str) -> None:
        self.data["phase"] = phase
        self.data["error"] = None
        self.data["updated_at"] = _utc_now()
        self.save()

    def record_result(self, group_id: str, result: Mapping[str, Any]) -> None:
        self.data["results"][group_id] = dict(result)
        self.data["updated_at"] = _utc_now()
        self.save()

    def record_error(self, error: BaseException) -> None:
        self.data["error"] = f"{type(error).__name__}: {error}"
        self.data["updated_at"] = _utc_now()
        self.save()

    def save(self) -> None:
        _atomic_write(self.path, (json.dumps(self.data, indent=2, sort_keys=True) + "\n").encode())


def _load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise BackfillError(f"expected a JSON object: {path}")
    return value


def _validate_allowlist(
    value: Mapping[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], bool]:
    if value.get("schema_version") != ALLOWLIST_SCHEMA_VERSION:
        raise BackfillError("unsupported allowlist schema_version")
    candidates = value.get("candidates")
    cache_actions = value.get("cache_only_actions", [])
    if not isinstance(candidates, list) or not isinstance(cache_actions, list):
        raise BackfillError("allowlist candidates/cache_only_actions must be arrays")
    if not candidates and not cache_actions:
        raise BackfillError("allowlist must contain a media or cache-only action")
    archive_database_required = value.get("archive_database_required", False)
    if not isinstance(archive_database_required, bool):
        raise BackfillError("archive_database_required must be boolean")
    required = {
        "item_id",
        "file_index",
        "source_sha256",
        "target_suffix",
        "derived_policy",
        "required_plan",
        "required_provenance",
        "required_post_probe",
        "required_post_plan",
        "server_references",
    }
    seen: set[tuple[str, int]] = set()
    result: list[dict[str, Any]] = []
    for raw in candidates:
        if not isinstance(raw, dict) or not required.issubset(raw):
            missing = sorted(required - set(raw if isinstance(raw, dict) else {}))
            raise BackfillError(f"allowlist candidate is missing fields: {missing}")
        try:
            uuid.UUID(str(raw["item_id"]))
        except ValueError as exc:
            raise BackfillError(f"invalid item_id: {raw['item_id']}") from exc
        index = raw["file_index"]
        if not isinstance(index, int) or index < 0:
            raise BackfillError("file_index must be a non-negative integer")
        digest = str(raw["source_sha256"]).lower()
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise BackfillError("source_sha256 must be 64 lowercase hex characters")
        suffix = str(raw["target_suffix"])
        if not re.fullmatch(r"\.[A-Za-z0-9]{1,8}", suffix):
            raise BackfillError("target_suffix must be a simple extension such as .webm")
        policy_name = str(raw["derived_policy"])
        if policy_name not in POLICIES:
            raise BackfillError(f"unknown derived_policy: {policy_name}")
        if not isinstance(raw["required_provenance"], Mapping) or not isinstance(
            raw["required_post_probe"], Mapping
        ):
            raise BackfillError("provenance and post-probe proofs must be JSON objects")
        if not raw["required_provenance"] or not raw["required_post_probe"]:
            raise BackfillError("provenance and post-probe proofs must be non-empty")
        if POLICIES[policy_name].requires_stream_equivalence and not raw["required_provenance"]:
            raise BackfillError(f"{policy_name} requires non-empty provenance proof")
        plan_proof = raw["required_plan"]
        if not isinstance(plan_proof, Mapping) or not {
            "action",
            "operation",
            "output_suffix",
            "video_codec",
            "audio_codec",
            "lossy",
        }.issubset(plan_proof):
            raise BackfillError("required_plan must review the complete transform contract")
        post_plan_proof = raw["required_post_plan"]
        if (
            not isinstance(post_plan_proof, Mapping)
            or post_plan_proof.get("action") != "keep"
            or post_plan_proof.get("output_suffix") != suffix.lower()
        ):
            raise BackfillError("required_post_plan must prove keep plus the target suffix")
        server_references = raw["server_references"]
        if (
            not isinstance(server_references, Mapping)
            or set(server_references) != {"archive_jobs", "media_files"}
            or not isinstance(server_references["archive_jobs"], list)
            or not isinstance(server_references["media_files"], list)
            or not all(isinstance(value, str) for value in server_references["archive_jobs"])
            or not all(isinstance(value, int) for value in server_references["media_files"])
        ):
            raise BackfillError(
                "server_references must contain exact archive_jobs string IDs and media_files integer IDs"
            )
        key = (str(raw["item_id"]), index)
        if key in seen:
            raise BackfillError(f"duplicate allowlist candidate: {key}")
        seen.add(key)
        normalized = dict(raw)
        normalized["source_sha256"] = digest
        normalized["target_suffix"] = suffix.lower()
        normalized["server_references"] = {
            "archive_jobs": sorted(set(server_references["archive_jobs"])),
            "media_files": sorted(set(server_references["media_files"])),
        }
        result.append(normalized)

    validated_cache_actions: list[dict[str, Any]] = []
    seen_cache_ids: set[str] = set()
    for raw in cache_actions:
        if not isinstance(raw, Mapping) or set(raw) != {"item_id", "action", "expected_files"}:
            raise BackfillError(
                "cache-only action requires exactly item_id, action, and expected_files"
            )
        item_id = str(raw["item_id"])
        try:
            uuid.UUID(item_id)
        except ValueError as exc:
            raise BackfillError(f"invalid cache-only item_id: {item_id}") from exc
        if item_id in seen_cache_ids or raw["action"] != "invalidate_thumbnails":
            raise BackfillError(f"invalid or duplicate cache-only action for {item_id}")
        expected_files = raw["expected_files"]
        if not isinstance(expected_files, list) or not expected_files:
            raise BackfillError("cache-only expected_files must be non-empty")
        normalized_files: list[dict[str, str]] = []
        seen_names: set[str] = set()
        name_pattern = re.compile(
            rf"{re.escape(item_id)}-(?:sm|md|preview-[0-9]+)\.jpg"
        )
        for entry in expected_files:
            if not isinstance(entry, Mapping) or set(entry) != {"name", "sha256"}:
                raise BackfillError("cache-only file requires exactly name and sha256")
            name = str(entry["name"])
            digest = str(entry["sha256"]).lower()
            if (
                name in seen_names
                or not name_pattern.fullmatch(name)
                or not re.fullmatch(r"[0-9a-f]{64}", digest)
            ):
                raise BackfillError(f"invalid reviewed thumbnail cache entry: {name}")
            seen_names.add(name)
            normalized_files.append({"name": name, "sha256": digest})
        seen_cache_ids.add(item_id)
        validated_cache_actions.append(
            {
                "item_id": item_id,
                "action": "invalidate_thumbnails",
                "expected_files": sorted(normalized_files, key=lambda entry: entry["name"]),
            }
        )
    return result, validated_cache_actions, archive_database_required


def _row_dict(connection: sqlite3.Connection, item_id: str) -> dict[str, Any]:
    connection.row_factory = sqlite3.Row
    row = connection.execute("SELECT * FROM media_items WHERE id = ?", (item_id,)).fetchone()
    if row is None:
        raise BackfillError(f"allowlisted item is absent from media_items: {item_id}")
    return dict(row)


def _all_inode_references(connection: sqlite3.Connection) -> dict[tuple[int, int], list[dict[str, Any]]]:
    connection.row_factory = sqlite3.Row
    result: dict[tuple[int, int], list[dict[str, Any]]] = {}
    for row in connection.execute(
        "SELECT id, mediaFilesJSON, metadataFileString, deletedAt FROM media_items"
    ):
        paths = json.loads(row["mediaFilesJSON"] or "[]")
        for index, raw_path in enumerate(paths):
            path = Path(raw_path)
            try:
                info = path.stat()
            except OSError:
                continue
            key = (int(info.st_dev), int(info.st_ino))
            result.setdefault(key, []).append(
                {
                    "item_id": row["id"],
                    "file_index": index,
                    "path": str(path),
                    "metadata_path": row["metadataFileString"],
                    "deleted": row["deletedAt"] not in (None, ""),
                }
            )
    return result


def _decode_json_object(raw: str | None, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(raw) if raw else {}
    except json.JSONDecodeError as exc:
        raise BackfillError(f"invalid JSON in {label}") from exc
    if not isinstance(value, dict):
        raise BackfillError(f"expected JSON object in {label}")
    return value


def _server_reference_inventory(
    connection: sqlite3.Connection, source_path: str
) -> dict[str, list[dict[str, Any]]]:
    connection.row_factory = sqlite3.Row
    old_name = Path(source_path).name
    result: dict[str, list[dict[str, Any]]] = {"archive_jobs": [], "media_files": []}
    for row in connection.execute(
        "SELECT * FROM archive_jobs WHERE file_path = ? OR metadata LIKE ?",
        (source_path, f"%{old_name}%"),
    ):
        metadata = _decode_json_object(row["metadata"], label=f"archive_jobs[{row['id']}].metadata")
        if row["file_path"] == source_path or _json_references(metadata, source_path):
            record = {key: _row_value(row[key]) for key in row.keys()}
            result["archive_jobs"].append(record)
    for row in connection.execute(
        "SELECT * FROM media_files WHERE path = ? OR metadata LIKE ?",
        (source_path, f"%{old_name}%"),
    ):
        metadata = _decode_json_object(row["metadata"], label=f"media_files[{row['id']}].metadata")
        if row["path"] == source_path or _json_references(metadata, source_path):
            record = {key: _row_value(row[key]) for key in row.keys()}
            result["media_files"].append(record)
    result["archive_jobs"].sort(key=lambda row: str(row["id"]))
    result["media_files"].sort(key=lambda row: int(row["id"]))
    return result


def _validate_server_references(
    connection: sqlite3.Connection,
    source_path: str,
    expected: Mapping[str, Sequence[Any]],
) -> dict[str, list[dict[str, Any]]]:
    inventory = _server_reference_inventory(connection, source_path)
    actual_ids = {
        "archive_jobs": [str(row["id"]) for row in inventory["archive_jobs"]],
        "media_files": [int(row["id"]) for row in inventory["media_files"]],
    }
    reviewed_ids = {
        "archive_jobs": sorted(str(value) for value in expected["archive_jobs"]),
        "media_files": sorted(int(value) for value in expected["media_files"]),
    }
    if actual_ids != reviewed_ids:
        raise BackfillError(
            f"archive.db references differ from reviewed allowlist for {source_path}: "
            f"actual={actual_ids}, reviewed={reviewed_ids}"
        )
    return {
        "archive_jobs": [
            {
                "id": str(row["id"]),
                "row_sha256": _sha256_bytes(_canonical_json(row)),
                "file_path": row["file_path"],
                "metadata_sha256": _sha256_bytes(str(row.get("metadata") or "").encode()),
            }
            for row in inventory["archive_jobs"]
        ],
        "media_files": [
            {
                "id": int(row["id"]),
                "row_sha256": _sha256_bytes(_canonical_json(row)),
                "path": row["path"],
                "metadata_sha256": _sha256_bytes(str(row.get("metadata") or "").encode()),
            }
            for row in inventory["media_files"]
        ],
    }


def _scan_alias_paths(archive_root: Path, inode_keys: set[tuple[int, int]]) -> dict[tuple[int, int], list[str]]:
    found: dict[tuple[int, int], list[str]] = {key: [] for key in inode_keys}
    for directory, directory_names, file_names in os.walk(archive_root):
        directory_names[:] = [name for name in directory_names if not name.startswith(".")]
        for name in file_names:
            path = Path(directory) / name
            try:
                info = path.stat()
            except OSError:
                continue
            key = (int(info.st_dev), int(info.st_ino))
            if key in found:
                found[key].append(str(path))
    return found


def _manifest_bytes(manifest: Mapping[str, Any]) -> bytes:
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


class BackfillEngine:
    def __init__(
        self,
        *,
        normalizer: NormalizerProtocol | None = None,
        process_guard: ProcessGuard | None = None,
    ) -> None:
        self.normalizer = normalizer
        self.process_guard = process_guard or ProcessGuard()

    def _normalizer(self) -> NormalizerProtocol:
        if self.normalizer is None:
            self.normalizer = ServerNormalizer()
        return self.normalizer

    def plan(
        self,
        *,
        database_path: Path,
        archive_database_path: Path | None,
        archive_root: Path,
        allowlist_path: Path,
        manifest_path: Path,
        recovery_root: Path | None = None,
    ) -> dict[str, Any]:
        database_path = database_path.resolve()
        archive_database_path = archive_database_path.resolve() if archive_database_path else None
        archive_root = archive_root.resolve()
        allowlist_path = allowlist_path.resolve()
        manifest_path = manifest_path.resolve()
        if not database_path.is_file() or not archive_root.is_dir():
            raise BackfillError("database_path and archive_root must exist")
        candidates, cache_actions, archive_database_required = _validate_allowlist(
            _load_json(allowlist_path)
        )
        if archive_database_required and archive_database_path is None:
            raise BackfillError("reviewed allowlist requires --archive-db")
        if any(
            candidate["server_references"]["archive_jobs"]
            or candidate["server_references"]["media_files"]
            for candidate in candidates
        ) and archive_database_path is None:
            raise BackfillError("reviewed server references require --archive-db")
        if archive_database_path is not None and not archive_database_path.is_file():
            raise BackfillError("archive_database_path does not exist")
        normalizer = self._normalizer()
        connection = _connect_ro(database_path)
        archive_connection = (
            _connect_ro(archive_database_path) if archive_database_path is not None else None
        )
        try:
            integrity = connection.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise BackfillError("source database failed integrity_check")
            if archive_connection is not None:
                archive_integrity = archive_connection.execute("PRAGMA integrity_check").fetchone()
                if not archive_integrity or archive_integrity[0] != "ok":
                    raise BackfillError("archive database failed integrity_check")
            inode_refs = _all_inode_references(connection)
            selected: list[dict[str, Any]] = []
            selected_keys = {(c["item_id"], c["file_index"]) for c in candidates}
            for candidate in candidates:
                row = _row_dict(connection, candidate["item_id"])
                if row.get("deletedAt") not in (None, ""):
                    raise BackfillError(f"allowlisted item is deleted: {candidate['item_id']}")
                media_paths = json.loads(row.get("mediaFilesJSON") or "[]")
                index = candidate["file_index"]
                if index >= len(media_paths):
                    raise BackfillError(f"file_index is out of range for {candidate['item_id']}")
                source = Path(media_paths[index])
                if not source.is_file() or source.is_symlink():
                    raise BackfillError(f"source is not a regular non-symlink file: {source}")
                digest = _sha256(source)
                if digest != candidate["source_sha256"]:
                    raise BackfillError(f"source hash changed for {candidate['item_id']}[{index}]")
                info = source.stat()
                inode = (int(info.st_dev), int(info.st_ino))
                unreviewed = [
                    ref
                    for ref in inode_refs.get(inode, [])
                    if (ref["item_id"], ref["file_index"]) not in selected_keys
                ]
                if unreviewed:
                    raise BackfillError(
                        f"candidate inode has unreviewed DB references: {candidate['item_id']}[{index}]"
                    )
                metadata_path = Path(row["metadataFileString"])
                if not metadata_path.is_file():
                    raise BackfillError(f"sidecar is missing: {metadata_path}")
                concrete_probe = normalizer.probe(source)
                concrete_plan = normalizer.classify(concrete_probe)
                probe_json = _jsonable(concrete_probe)
                plan_json = _jsonable(concrete_plan)
                _matches_subset(plan_json, candidate["required_plan"])
                if plan_json.get("output_suffix") != candidate["target_suffix"]:
                    raise BackfillError(f"normalizer plan disagrees with target suffix: {source}")
                policy = POLICIES[candidate["derived_policy"]]
                if policy.requires_stream_equivalence and (
                    plan_json.get("video_codec") != "copy"
                    or plan_json.get("audio_codec") != "copy"
                    or plan_json.get("lossy") is not False
                ):
                    raise BackfillError(
                        f"reviewed equivalence policy is not a lossless stream copy: {source}"
                    )
                scan_row = connection.execute(
                    """
                    SELECT metadataFileString, itemId, metadataFileModifiedAt,
                           metadataFileSize, mediaFilesJSON, contextImageString
                    FROM archive_scan_cache
                    WHERE itemId = ? AND metadataFileString = ?
                    """,
                    (candidate["item_id"], str(metadata_path)),
                ).fetchone()
                if scan_row is None:
                    raise BackfillError(
                        f"archive_scan_cache row is missing for {candidate['item_id']}"
                    )
                server_rows = (
                    _validate_server_references(
                        archive_connection,
                        str(source),
                        candidate["server_references"],
                    )
                    if archive_connection is not None
                    else {"archive_jobs": [], "media_files": []}
                )
                selected.append(
                    {
                        **candidate,
                        "source_path": str(source),
                        "metadata_path": str(metadata_path),
                        "source_size": info.st_size,
                        "source_mtime_ns": info.st_mtime_ns,
                        "source_mode": stat.S_IMODE(info.st_mode),
                        "device": int(info.st_dev),
                        "inode": int(info.st_ino),
                        "link_count": int(info.st_nlink),
                        "sidecar_sha256": _sha256(metadata_path),
                        "media_files_before": media_paths,
                        "probe": probe_json,
                        "normalization_plan": plan_json,
                        "archive_scan_cache_before": {
                            "metadataFileString": scan_row[0],
                            "itemId": scan_row[1],
                            "metadataFileModifiedAt": scan_row[2],
                            "metadataFileSize": scan_row[3],
                            "mediaFilesJSON": scan_row[4],
                            "contextImageString": scan_row[5],
                        },
                        "preserved_state": _policy_snapshot(
                            connection, candidate["item_id"], policy
                        ),
                        "server_rows_before": server_rows,
                        "derived_policy_expanded": dataclasses.asdict(POLICIES[candidate["derived_policy"]]),
                    }
                )
        finally:
            connection.close()
            if archive_connection is not None:
                archive_connection.close()

        inode_keys = {(entry["device"], entry["inode"]) for entry in selected}
        filesystem_aliases = _scan_alias_paths(archive_root, inode_keys)
        groups_by_inode: dict[tuple[int, int], list[dict[str, Any]]] = {}
        for entry in selected:
            groups_by_inode.setdefault((entry["device"], entry["inode"]), []).append(entry)

        groups: list[dict[str, Any]] = []
        for inode, references in sorted(groups_by_inode.items()):
            aliases = sorted(filesystem_aliases.get(inode, []))
            expected_links = references[0]["link_count"]
            if len(aliases) != expected_links:
                raise BackfillError(
                    f"could not account for every hard link to inode {inode}: "
                    f"stat reports {expected_links}, archive scan found {len(aliases)}"
                )
            if {ref["source_path"] for ref in references} != set(aliases):
                raise BackfillError("every filesystem alias must have an exact reviewed DB reference")
            policies = {ref["derived_policy"] for ref in references}
            suffixes = {ref["target_suffix"] for ref in references}
            hashes = {ref["source_sha256"] for ref in references}
            if len(policies) != 1 or len(suffixes) != 1 or len(hashes) != 1:
                raise BackfillError("hard-link aliases disagree on reviewed normalization policy")
            group_id = hashlib.sha256(
                f"{inode[0]}:{inode[1]}:{next(iter(hashes))}".encode()
            ).hexdigest()[:20]
            groups.append(
                {
                    "group_id": group_id,
                    "device": inode[0],
                    "inode": inode[1],
                    "source_sha256": next(iter(hashes)),
                    "source_size": references[0]["source_size"],
                    "target_suffix": next(iter(suffixes)),
                    "derived_policy": next(iter(policies)),
                    "filesystem_aliases": aliases,
                    "references": sorted(references, key=lambda r: (r["item_id"], r["file_index"])),
                }
            )

        cache_only_manifest: list[dict[str, Any]] = []
        media_item_ids = {entry["item_id"] for entry in selected}
        cache_connection = _connect_ro(database_path)
        cache_connection.row_factory = sqlite3.Row
        try:
            thumbnail_root = database_path.parent / "thumbnails"
            for action in cache_actions:
                item_id = action["item_id"]
                if item_id in media_item_ids:
                    raise BackfillError(f"cache-only item is also a media candidate: {item_id}")
                row = cache_connection.execute(
                    "SELECT * FROM media_items WHERE id=? AND (deletedAt IS NULL OR deletedAt='')",
                    (item_id,),
                ).fetchone()
                if row is None:
                    raise BackfillError(f"cache-only item is absent or deleted: {item_id}")
                expected = {entry["name"]: entry["sha256"] for entry in action["expected_files"]}
                actual_paths = sorted(
                    path for path in thumbnail_root.glob(f"{item_id}-*") if path.is_file()
                )
                if {path.name for path in actual_paths} != set(expected):
                    raise BackfillError(f"thumbnail set differs from reviewed cache action: {item_id}")
                for path in actual_paths:
                    if _sha256(path) != expected[path.name]:
                        raise BackfillError(f"thumbnail bytes differ from reviewed cache action: {path}")
                metadata_path = Path(row["metadataFileString"])
                media_paths = [Path(value) for value in json.loads(row["mediaFilesJSON"] or "[]")]
                cache_only_manifest.append(
                    {
                        **action,
                        "files": [
                            {"path": str(path), "sha256": expected[path.name]}
                            for path in actual_paths
                        ],
                        "media_item_sha256": _sha256_bytes(
                            _canonical_json({key: _row_value(row[key]) for key in row.keys()})
                        ),
                        "metadata_path": str(metadata_path),
                        "sidecar_sha256": _sha256(metadata_path),
                        "media_files": [
                            {"path": str(path), "sha256": _sha256(path)} for path in media_paths
                        ],
                    }
                )
        finally:
            cache_connection.close()

        run_id = f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
        recovery = (recovery_root or archive_root / ".nodraw-recovery" / "media-compat").resolve()
        try:
            recovery_relative = recovery.relative_to(archive_root)
        except ValueError as exc:
            raise BackfillError("recovery_root must be inside archive_root for same-volume staging") from exc
        if not recovery_relative.parts or not recovery_relative.parts[0].startswith("."):
            raise BackfillError("recovery_root must be under a hidden archive directory")
        manifest = {
            "schema_version": MANIFEST_SCHEMA_VERSION,
            "run_id": run_id,
            "created_at": _utc_now(),
            "database_path": str(database_path),
            "database_user_version": connection_user_version(database_path),
            "archive_database_path": str(archive_database_path) if archive_database_path else None,
            "archive_database_user_version": (
                connection_user_version(archive_database_path) if archive_database_path else None
            ),
            "archive_root": str(archive_root),
            "recovery_root": str(recovery),
            "allowlist_path": str(allowlist_path),
            "allowlist_sha256": _sha256(allowlist_path),
            "normalizer_api": {
                "probe": "MediaNormalizer.probe",
                "classify": "classify_media",
                "normalize": "MediaNormalizer.normalize_staged",
            },
            "candidate_reference_count": len(selected),
            "candidate_inode_group_count": len(groups),
            "groups": groups,
            "cache_only_actions": cache_only_manifest,
        }
        data = _manifest_bytes(manifest)
        if manifest_path.exists() or manifest_path.with_suffix(manifest_path.suffix + ".sha256").exists():
            raise BackfillError(f"manifest already exists: {manifest_path}")
        _atomic_write(manifest_path, data, mode=0o444)
        digest_path = manifest_path.with_suffix(manifest_path.suffix + ".sha256")
        _atomic_write(digest_path, (_sha256_bytes(data) + "\n").encode(), mode=0o444)
        return manifest

    def apply(self, manifest_path: Path) -> dict[str, Any]:
        manifest, manifest_digest = self._load_manifest(manifest_path)
        database_path = Path(manifest["database_path"])
        databases = [database_path]
        if manifest.get("archive_database_path"):
            databases.append(Path(manifest["archive_database_path"]))
        self.process_guard.assert_offline(databases)
        run_dir = Path(manifest["recovery_root"]) / manifest["run_id"]
        run_dir.mkdir(parents=True, exist_ok=True)
        journal = RunJournal(run_dir / "journal.json", manifest_digest)
        if journal.phase == "complete":
            return journal.data
        if journal.phase == "rolled_back":
            raise BackfillError("this run was rolled back and cannot be re-applied")

        published = journal.phase in {
            "files_published",
            "sidecars_published",
            "database_committed",
            "caches_invalidated",
            "verified",
        }
        try:
            if journal.phase == "created":
                self._revalidate_sources(manifest)
                self._backup(manifest, run_dir)
                journal.advance("backed_up")
            if journal.phase == "backed_up":
                self._normalize(manifest, run_dir, journal)
                journal.advance("normalized")
            if journal.phase == "normalized":
                published = True
                self._publish_files(manifest, journal)
                journal.advance("files_published")
            if journal.phase == "files_published":
                self._publish_sidecars(manifest, run_dir, journal)
                journal.advance("sidecars_published")
            if journal.phase == "sidecars_published":
                self._commit_database(manifest, journal)
                journal.advance("database_committed")
            if journal.phase == "database_committed":
                self._invalidate_caches(manifest, run_dir)
                journal.advance("caches_invalidated")
            if journal.phase == "caches_invalidated":
                self._verify(manifest, journal)
                journal.advance("verified")
            if journal.phase == "verified":
                journal.advance("complete")
            return journal.data
        except BaseException as exc:
            journal.record_error(exc)
            if published:
                try:
                    self._rollback(manifest, run_dir, journal)
                    journal.advance("rolled_back")
                except BaseException as rollback_error:
                    journal.record_error(
                        BackfillError(f"apply failed ({exc}); automatic rollback also failed ({rollback_error})")
                    )
            raise

    def verify(self, manifest_path: Path) -> dict[str, Any]:
        manifest, digest = self._load_manifest(manifest_path)
        run_dir = Path(manifest["recovery_root"]) / manifest["run_id"]
        journal_path = run_dir / "journal.json"
        if not journal_path.is_file():
            raise BackfillError("run has not been applied; there is no journal to verify")
        journal = RunJournal(journal_path, digest)
        self._verify(manifest, journal)
        return {"ok": True, "phase": journal.phase, "run_id": manifest["run_id"]}

    def rollback(self, manifest_path: Path) -> dict[str, Any]:
        manifest, digest = self._load_manifest(manifest_path)
        databases = [Path(manifest["database_path"])]
        if manifest.get("archive_database_path"):
            databases.append(Path(manifest["archive_database_path"]))
        self.process_guard.assert_offline(databases)
        run_dir = Path(manifest["recovery_root"]) / manifest["run_id"]
        journal = RunJournal(run_dir / "journal.json", digest)
        if journal.phase == "rolled_back":
            return journal.data
        self._rollback(manifest, run_dir, journal)
        journal.advance("rolled_back")
        return journal.data

    def status(self, manifest_path: Path) -> dict[str, Any]:
        manifest, digest = self._load_manifest(manifest_path)
        journal_path = Path(manifest["recovery_root"]) / manifest["run_id"] / "journal.json"
        if not journal_path.exists():
            return {"run_id": manifest["run_id"], "phase": "planned", "manifest_sha256": digest}
        return RunJournal(journal_path, digest).data

    @staticmethod
    def _load_manifest(path: Path) -> tuple[dict[str, Any], str]:
        path = path.resolve()
        data = path.read_bytes()
        expected_path = path.with_suffix(path.suffix + ".sha256")
        expected = expected_path.read_text(encoding="utf-8").strip()
        actual = _sha256_bytes(data)
        if not re.fullmatch(r"[0-9a-f]{64}", expected) or expected != actual:
            raise BackfillError("manifest checksum mismatch")
        manifest = json.loads(data)
        if manifest.get("schema_version") != MANIFEST_SCHEMA_VERSION:
            raise BackfillError("unsupported manifest schema_version")
        return manifest, actual

    def _revalidate_sources(self, manifest: Mapping[str, Any]) -> None:
        allowlist_path = Path(manifest["allowlist_path"])
        if not allowlist_path.is_file() or _sha256(allowlist_path) != manifest["allowlist_sha256"]:
            raise BackfillError("reviewed allowlist changed or disappeared after planning")
        if connection_user_version(Path(manifest["database_path"])) != manifest[
            "database_user_version"
        ]:
            raise BackfillError("NoDraw database schema changed after planning")
        if manifest.get("archive_database_path") and connection_user_version(
            Path(manifest["archive_database_path"])
        ) != manifest.get("archive_database_user_version"):
            raise BackfillError("archive database schema changed after planning")
        connection = _connect_ro(Path(manifest["database_path"]))
        archive_connection = None
        if manifest.get("archive_database_path"):
            archive_connection = _connect_ro(Path(manifest["archive_database_path"]))
            archive_connection.row_factory = sqlite3.Row
        try:
            for group in manifest["groups"]:
                inode: tuple[int, int] | None = None
                for ref in group["references"]:
                    row = _row_dict(connection, ref["item_id"])
                    paths = json.loads(row["mediaFilesJSON"] or "[]")
                    index = ref["file_index"]
                    if index >= len(paths) or paths[index] != ref["source_path"]:
                        raise BackfillError(f"database source path drifted for {ref['item_id']}[{index}]")
                    path = Path(ref["source_path"])
                    if _sha256(path) != ref["source_sha256"]:
                        raise BackfillError(f"source bytes drifted for {ref['item_id']}[{index}]")
                    info = path.stat()
                    current = (int(info.st_dev), int(info.st_ino))
                    inode = inode or current
                    if current != inode:
                        raise BackfillError("reviewed hard-link group no longer shares one inode")
                    if _sha256(Path(ref["metadata_path"])) != ref["sidecar_sha256"]:
                        raise BackfillError(f"sidecar changed after review: {ref['metadata_path']}")
                    if archive_connection is not None:
                        for table, records in ref["server_rows_before"].items():
                            for record in records:
                                row = archive_connection.execute(
                                    f'SELECT * FROM "{table}" WHERE id=?', (record["id"],)
                                ).fetchone()
                                if row is None:
                                    raise BackfillError(
                                        f"reviewed archive.db row disappeared: {table}[{record['id']}]"
                                    )
                                current = {key: _row_value(row[key]) for key in row.keys()}
                                if _sha256_bytes(_canonical_json(current)) != record["row_sha256"]:
                                    raise BackfillError(
                                        f"reviewed archive.db row changed: {table}[{record['id']}]"
                                    )
            connection.row_factory = sqlite3.Row
            for action in manifest.get("cache_only_actions", []):
                row = connection.execute(
                    "SELECT * FROM media_items WHERE id=?", (action["item_id"],)
                ).fetchone()
                current_hash = (
                    _sha256_bytes(
                        _canonical_json({key: _row_value(row[key]) for key in row.keys()})
                    )
                    if row is not None
                    else None
                )
                if current_hash != action["media_item_sha256"]:
                    raise BackfillError(f"cache-only item changed after review: {action['item_id']}")
                if _sha256(Path(action["metadata_path"])) != action["sidecar_sha256"]:
                    raise BackfillError(f"cache-only sidecar changed: {action['metadata_path']}")
                for media in action["media_files"]:
                    if _sha256(Path(media["path"])) != media["sha256"]:
                        raise BackfillError(f"cache-only source changed: {media['path']}")
                for cache_file in action["files"]:
                    if _sha256(Path(cache_file["path"])) != cache_file["sha256"]:
                        raise BackfillError(f"reviewed cache file changed: {cache_file['path']}")
        finally:
            connection.close()
            if archive_connection is not None:
                archive_connection.close()

    def _backup(self, manifest: Mapping[str, Any], run_dir: Path) -> None:
        _database_backup(Path(manifest["database_path"]), run_dir / "backups" / "media.sqlite.source")
        if manifest.get("archive_database_path"):
            _database_backup(
                Path(manifest["archive_database_path"]),
                run_dir / "backups" / "archive.db.source",
            )
        copied_sidecars: set[str] = set()
        for group in manifest["groups"]:
            source = Path(group["references"][0]["source_path"])
            _copy_or_link(source, run_dir / "backups" / "media" / f"{group['group_id']}.source")
            for ref in group["references"]:
                metadata = Path(ref["metadata_path"])
                if str(metadata) not in copied_sidecars:
                    _copy_or_link(
                        metadata,
                        run_dir / "backups" / "sidecars" / f"{_sha256_bytes(str(metadata).encode())}.sidecar",
                    )
                    copied_sidecars.add(str(metadata))
        self._backup_cache_files(manifest, run_dir)

    def _backup_cache_files(self, manifest: Mapping[str, Any], run_dir: Path) -> None:
        app_support = Path(manifest["database_path"]).parent
        thumbnail_ids = {
            ref["item_id"]
            for group in manifest["groups"]
            for ref in group["references"]
            if POLICIES[ref["derived_policy"]].invalidate_thumbnails
        }
        thumbnail_ids.update(action["item_id"] for action in manifest.get("cache_only_actions", []))
        pipeline_ids = {
            ref["item_id"]
            for group in manifest["groups"]
            for ref in group["references"]
            if POLICIES[ref["derived_policy"]].invalidate_pipeline_store
        }
        for root, ids in (
            (app_support / "thumbnails", thumbnail_ids),
            (app_support / "pipeline-store", pipeline_ids),
        ):
            if not root.exists():
                continue
            for path in root.rglob("*"):
                if not path.is_file() or not any(path.name.startswith(item_id) for item_id in ids):
                    continue
                relative = path.relative_to(app_support)
                _copy_or_link(path, run_dir / "backups" / "app-support" / relative)

    def _normalize(self, manifest: Mapping[str, Any], run_dir: Path, journal: RunJournal) -> None:
        normalizer = self._normalizer()
        for group in manifest["groups"]:
            group_id = group["group_id"]
            if group_id in journal.data["results"]:
                continue
            stage_dir = run_dir / "staging" / group_id
            stage_dir.mkdir(parents=True, exist_ok=True)
            source = Path(group["references"][0]["source_path"])
            staged_source = stage_dir / f"input{source.suffix.lower()}"
            if not staged_source.exists():
                shutil.copy2(source, staged_source)
            result = normalizer.normalize_staged(staged_source)
            media_path = Path(getattr(result, "media_path"))
            preserved = getattr(result, "preserved_source", None)
            provenance_method = getattr(result, "provenance", None)
            if not callable(provenance_method):
                raise BackfillError("normalizer result has no provenance() method")
            provenance = _jsonable(provenance_method())
            result_plan = _jsonable(getattr(result, "plan", None))
            if not media_path.is_file() or media_path.stat().st_size <= 0:
                raise BackfillError("normalizer produced no non-empty media_path")
            try:
                media_path.resolve().relative_to(stage_dir.resolve())
            except ValueError as exc:
                raise BackfillError("normalizer output escaped hidden staging directory") from exc
            if media_path.suffix.lower() != group["target_suffix"]:
                raise BackfillError(
                    f"normalizer suffix {media_path.suffix} did not match reviewed {group['target_suffix']}"
                )
            for ref in group["references"]:
                _matches_subset(provenance, ref["required_provenance"])
                _matches_subset(result_plan, ref["required_plan"])
                _require_stream_equivalence(ref["derived_policy"], result_plan, provenance)
            preserved_record: dict[str, Any] | None = None
            if preserved is not None:
                preserved_path = Path(preserved)
                if not preserved_path.is_file():
                    raise BackfillError("normalizer reported a missing preserved_source")
                preserved_record = {
                    "path": str(preserved_path),
                    "sha256": _sha256(preserved_path),
                    "size": preserved_path.stat().st_size,
                }
                if preserved_record["sha256"] != group["source_sha256"]:
                    raise BackfillError("normalizer preserved_source is not the reviewed source bytes")
            if POLICIES[group["derived_policy"]].requires_stream_equivalence and preserved is not None:
                raise BackfillError("lossless stream-copy normalization unexpectedly preserved a lossy source")
            journal.record_result(
                group_id,
                {
                    "media_path": str(media_path),
                    "media_sha256": _sha256(media_path),
                    "media_size": media_path.stat().st_size,
                    "provenance": provenance,
                    "preserved_source": preserved_record,
                    "targets": [
                        str(Path(path).with_suffix(group["target_suffix"]))
                        for path in group["filesystem_aliases"]
                    ],
                },
            )

    def _publish_files(self, manifest: Mapping[str, Any], journal: RunJournal) -> None:
        for group in manifest["groups"]:
            result = journal.data["results"][group["group_id"]]
            media_path = Path(result["media_path"])
            output_hash = result["media_sha256"]
            targets = [Path(path) for path in result["targets"]]
            old_paths = [Path(path) for path in group["filesystem_aliases"]]
            for target, old in zip(targets, old_paths, strict=True):
                if target.exists() and target != old and _sha256(target) != output_hash:
                    raise BackfillError(f"normalization target already exists: {target}")
            anchor = targets[0]
            anchor_old = old_paths[0]
            if not anchor.exists() or _sha256(anchor) != output_hash:
                _atomic_install(media_path, anchor, anchor_old)
            anchor_inode = (anchor.stat().st_dev, anchor.stat().st_ino)
            for target, old in zip(targets[1:], old_paths[1:], strict=True):
                target_inode = (
                    (target.stat().st_dev, target.stat().st_ino) if target.exists() else None
                )
                if (
                    target_inode != anchor_inode
                    or _sha256(target) != output_hash
                ):
                    _atomic_install(anchor, target, old, hard_link=True)
            for target, old in zip(targets, old_paths, strict=True):
                if target != old:
                    old.unlink(missing_ok=True)
            target_inodes = {(path.stat().st_dev, path.stat().st_ino) for path in targets}
            if len(target_inodes) != 1:
                raise BackfillError("published hard-link aliases no longer share one inode")
            media_path.unlink(missing_ok=True)

    def _publish_sidecars(
        self, manifest: Mapping[str, Any], run_dir: Path, journal: RunJournal
    ) -> None:
        patches: dict[str, list[dict[str, Any]]] = {}
        for group in manifest["groups"]:
            result = journal.data["results"][group["group_id"]]
            recovery_backup = (
                run_dir / "backups" / "media" / f"{group['group_id']}.source"
            )
            recovery_record = str(
                recovery_backup.relative_to(Path(manifest["archive_root"]))
            )
            target_by_old = dict(zip(group["filesystem_aliases"], result["targets"], strict=True))
            for ref in group["references"]:
                old = ref["source_path"]
                patches.setdefault(ref["metadata_path"], []).append(
                    {
                        "run_id": manifest["run_id"],
                        "item_id": ref["item_id"],
                        "file_index": ref["file_index"],
                        "old_path": old,
                        "new_path": target_by_old[old],
                        "source_sha256": ref["source_sha256"],
                        "output_sha256": result["media_sha256"],
                        "output_size": result["media_size"],
                        "provenance": result["provenance"],
                        "recovery_record": recovery_record,
                    }
                )
        for metadata_path, sidecar_patches in patches.items():
            metadata = Path(metadata_path)
            backup = run_dir / "backups" / "sidecars" / f"{_sha256_bytes(metadata_path.encode())}.sidecar"
            original = backup.read_text(encoding="utf-8")
            updated = patch_sidecar(original, sidecar_patches)
            mode = stat.S_IMODE(metadata.stat().st_mode)
            _atomic_write(metadata, updated.encode("utf-8"), mode=mode)

    def _commit_database(self, manifest: Mapping[str, Any], journal: RunJournal) -> None:
        database = sqlite3.connect(manifest["database_path"])
        database.row_factory = sqlite3.Row
        try:
            database.execute("PRAGMA foreign_keys=ON")
            database.execute("BEGIN IMMEDIATE")
            for group in manifest["groups"]:
                result = journal.data["results"][group["group_id"]]
                target_by_old = dict(zip(group["filesystem_aliases"], result["targets"], strict=True))
                for ref in group["references"]:
                    row = database.execute(
                        """
                        SELECT mediaFilesJSON, sourceURL FROM media_items
                        WHERE id = ? AND (deletedAt IS NULL OR deletedAt = '')
                        """,
                        (ref["item_id"],),
                    ).fetchone()
                    if row is None:
                        raise BackfillError(f"active item disappeared before DB commit: {ref['item_id']}")
                    paths = json.loads(row["mediaFilesJSON"] or "[]")
                    index = ref["file_index"]
                    old_path = ref["source_path"]
                    new_path = target_by_old[old_path]
                    if index >= len(paths) or paths[index] not in (old_path, new_path):
                        raise BackfillError(f"media path drifted before DB commit: {ref['item_id']}[{index}]")
                    paths[index] = new_path
                    source_url = row["sourceURL"]
                    updated_source_url = _retarget_file_url(source_url, old_path, new_path)
                    database.execute(
                        "UPDATE media_items SET mediaFilesJSON = ?, sourceURL = ? WHERE id = ?",
                        (json.dumps(paths, separators=(",", ":")), updated_source_url, ref["item_id"]),
                    )
                    self._apply_policy(database, ref, old_path, new_path)
                    metadata = Path(ref["metadata_path"])
                    info = metadata.stat()
                    cursor = database.execute(
                        """
                        UPDATE archive_scan_cache
                        SET mediaFilesJSON = ?, metadataFileModifiedAt = ?, metadataFileSize = ?
                        WHERE itemId = ? AND metadataFileString = ?
                        """,
                        (
                            json.dumps(paths, separators=(",", ":")),
                            info.st_mtime,
                            info.st_size,
                            ref["item_id"],
                            ref["metadata_path"],
                        ),
                    )
                    if cursor.rowcount != 1:
                        raise BackfillError(
                            f"archive_scan_cache update did not match exactly one row: {ref['item_id']}"
                        )
            database.commit()
            integrity = database.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise BackfillError("database failed integrity_check after commit")
        except BaseException:
            database.rollback()
            raise
        finally:
            database.close()
        self._commit_archive_database(manifest, journal)

    def _commit_archive_database(
        self, manifest: Mapping[str, Any], journal: RunJournal
    ) -> None:
        archive_path = manifest.get("archive_database_path")
        if not archive_path:
            return
        database = sqlite3.connect(archive_path)
        database.row_factory = sqlite3.Row
        seen: set[tuple[str, Any]] = set()
        try:
            database.execute("BEGIN IMMEDIATE")
            for group in manifest["groups"]:
                result = journal.data["results"][group["group_id"]]
                target_by_old = dict(zip(group["filesystem_aliases"], result["targets"], strict=True))
                for ref in group["references"]:
                    old_path = ref["source_path"]
                    new_path = target_by_old[old_path]
                    mime_type = mimetypes.guess_type(new_path)[0] or "application/octet-stream"
                    for reviewed in ref["server_rows_before"]["archive_jobs"]:
                        key = ("archive_jobs", reviewed["id"])
                        if key in seen:
                            continue
                        seen.add(key)
                        row = database.execute(
                            "SELECT * FROM archive_jobs WHERE id=?", (reviewed["id"],)
                        ).fetchone()
                        if row is None or row["file_path"] not in (old_path, new_path):
                            raise BackfillError(f"archive_jobs row drifted: {reviewed['id']}")
                        metadata = _decode_json_object(
                            row["metadata"], label=f"archive_jobs[{reviewed['id']}].metadata"
                        )
                        updated_metadata = _normalization_metadata(
                            metadata,
                            run_id=manifest["run_id"],
                            item_id=ref["item_id"],
                            old_path=old_path,
                            new_path=new_path,
                            source_sha256=ref["source_sha256"],
                            output_sha256=result["media_sha256"],
                            provenance=result["provenance"],
                        )
                        cursor = database.execute(
                            """
                            UPDATE archive_jobs
                            SET file_path=?, file_size=?, file_hash=?, metadata=?
                            WHERE id=?
                            """,
                            (
                                new_path,
                                result["media_size"],
                                result["media_sha256"],
                                json.dumps(updated_metadata, ensure_ascii=False, separators=(",", ":")),
                                reviewed["id"],
                            ),
                        )
                        if cursor.rowcount != 1:
                            raise BackfillError(f"archive_jobs update failed: {reviewed['id']}")
                    for reviewed in ref["server_rows_before"]["media_files"]:
                        key = ("media_files", reviewed["id"])
                        if key in seen:
                            continue
                        seen.add(key)
                        row = database.execute(
                            "SELECT * FROM media_files WHERE id=?", (reviewed["id"],)
                        ).fetchone()
                        if row is None or row["path"] not in (old_path, new_path):
                            raise BackfillError(f"media_files row drifted: {reviewed['id']}")
                        metadata = _decode_json_object(
                            row["metadata"], label=f"media_files[{reviewed['id']}].metadata"
                        )
                        updated_metadata = _normalization_metadata(
                            metadata,
                            run_id=manifest["run_id"],
                            item_id=ref["item_id"],
                            old_path=old_path,
                            new_path=new_path,
                            source_sha256=ref["source_sha256"],
                            output_sha256=result["media_sha256"],
                            provenance=result["provenance"],
                        )
                        cursor = database.execute(
                            """
                            UPDATE media_files
                            SET path=?, media_type='video', mime_type=?, file_size=?, metadata=?
                            WHERE id=?
                            """,
                            (
                                new_path,
                                mime_type,
                                result["media_size"],
                                json.dumps(updated_metadata, ensure_ascii=False, separators=(",", ":")),
                                reviewed["id"],
                            ),
                        )
                        if cursor.rowcount != 1:
                            raise BackfillError(f"media_files update failed: {reviewed['id']}")
            database.commit()
            integrity = database.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise BackfillError("archive database failed integrity_check after commit")
        except BaseException:
            database.rollback()
            raise
        finally:
            database.close()

    @staticmethod
    def _apply_policy(
        database: sqlite3.Connection, ref: Mapping[str, Any], old_path: str, new_path: str
    ) -> None:
        item_id = ref["item_id"]
        policy = POLICIES[ref["derived_policy"]]
        if policy.preserve_transcription:
            database.execute(
                "UPDATE transcript_segments SET source_path = ? WHERE item_id = ? AND source_path = ?",
                (new_path, item_id, old_path),
            )
        else:
            database.execute("DELETE FROM transcript_segments WHERE item_id = ?", (item_id,))
            database.execute(
                """
                UPDATE media_items SET transcription_status='none', transcription_version=0,
                  transcription_retry_count=0, transcription_last_error=NULL,
                  transcription_failed_at=NULL WHERE id=?
                """,
                (item_id,),
            )
        if policy.preserve_video_understanding:
            database.execute(
                "UPDATE video_segments SET source_path = ? WHERE item_id = ? AND source_path = ?",
                (new_path, item_id, old_path),
            )
        elif policy.reset_video_understanding:
            database.execute("DELETE FROM video_segments WHERE item_id = ?", (item_id,))
            database.execute(
                """
                UPDATE media_items SET video_understanding_status='none', video_understanding_version=0,
                  video_understanding_retry_count=0, video_understanding_last_error=NULL,
                  video_understanding_failed_at=NULL WHERE id=?
                """,
                (item_id,),
            )
        if policy.reset_general_pipeline:
            database.execute("DELETE FROM media_attributes WHERE item_id = ?", (item_id,))
            database.execute("DELETE FROM clip_vectors WHERE itemId = ?", (item_id,))
            database.execute(
                """
                UPDATE media_items SET pipeline_status='none', pipeline_version=0,
                  pipeline_retry_count=0, pipeline_last_error=NULL, pipeline_failed_at=NULL
                WHERE id=?
                """,
                (item_id,),
            )
        if policy.reset_vision:
            database.execute("DELETE FROM media_file_ocr WHERE item_id = ?", (item_id,))
            database.execute("DELETE FROM media_colors WHERE item_id = ?", (item_id,))
            database.execute(
                """
                UPDATE media_items SET ocrText=NULL, ocrBoundingBoxesJSON=NULL,
                  dominantColorsJSON=NULL, perceptualHash=NULL, saliencyRectJSON=NULL
                WHERE id=?
                """,
                (item_id,),
            )

    def _invalidate_caches(self, manifest: Mapping[str, Any], run_dir: Path) -> None:
        app_support = Path(manifest["database_path"]).parent
        thumbnail_root = app_support / "thumbnails"
        pipeline_root = app_support / "pipeline-store"
        for group in manifest["groups"]:
            for ref in group["references"]:
                item_id = ref["item_id"]
                policy = POLICIES[ref["derived_policy"]]
                if policy.invalidate_thumbnails and thumbnail_root.exists():
                    for path in thumbnail_root.glob(f"{item_id}-*"):
                        if path.is_file():
                            path.unlink()
                if policy.invalidate_pipeline_store and pipeline_root.exists():
                    for path in pipeline_root.rglob(f"{item_id}*"):
                        if path.is_file():
                            path.unlink()
        for action in manifest.get("cache_only_actions", []):
            for cache_file in action["files"]:
                path = Path(cache_file["path"])
                if path.exists() and _sha256(path) != cache_file["sha256"]:
                    raise BackfillError(f"cache-only file changed before invalidation: {path}")
                path.unlink(missing_ok=True)

    def _verify(self, manifest: Mapping[str, Any], journal: RunJournal) -> None:
        normalizer = self._normalizer()
        database = _connect_ro(Path(manifest["database_path"]))
        database.row_factory = sqlite3.Row
        try:
            integrity = database.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise BackfillError("database integrity_check failed during verification")
            for group in manifest["groups"]:
                result = journal.data["results"].get(group["group_id"])
                if result is None:
                    raise BackfillError(f"missing normalized result for {group['group_id']}")
                targets = [Path(path) for path in result["targets"]]
                if any(not path.is_file() or _sha256(path) != result["media_sha256"] for path in targets):
                    raise BackfillError(f"published media verification failed: {group['group_id']}")
                if len({(p.stat().st_dev, p.stat().st_ino) for p in targets}) != 1:
                    raise BackfillError("published aliases do not share one inode")
                post_probe_concrete = normalizer.probe(targets[0])
                post_probe = _jsonable(post_probe_concrete)
                post_plan = _jsonable(normalizer.classify(post_probe_concrete))
                for ref in group["references"]:
                    _matches_subset(post_probe, ref["required_post_probe"])
                    _matches_subset(post_plan, ref["required_post_plan"])
                    row = database.execute(
                        "SELECT * FROM media_items WHERE id = ?", (ref["item_id"],)
                    ).fetchone()
                    if row is None:
                        raise BackfillError(f"item missing after backfill: {ref['item_id']}")
                    paths = json.loads(row["mediaFilesJSON"] or "[]")
                    old_path = ref["source_path"]
                    expected = result["targets"][group["filesystem_aliases"].index(old_path)]
                    if paths[ref["file_index"]] != expected:
                        raise BackfillError(f"DB path verification failed: {ref['item_id']}")
                    self._verify_policy(database, row, ref)
                    content = Path(ref["metadata_path"]).read_text(encoding="utf-8")
                    if Path(expected).name != Path(old_path).name:
                        old_name = Path(old_path).name
                        old_link = re.compile(
                            r"!?\[\[" + re.escape(old_name) + r"(?=(?:[|#][^\]]*)?\]\])"
                        )
                        if old_link.search(content) or Path(old_path).resolve().as_uri() in content:
                            raise BackfillError(
                                f"sidecar retains an old media reference: {ref['metadata_path']}"
                            )
                    if manifest["run_id"] not in content:
                        raise BackfillError(f"sidecar lacks normalization provenance: {ref['metadata_path']}")
                    policy = POLICIES[ref["derived_policy"]]
                    app_support = Path(manifest["database_path"]).parent
                    if policy.invalidate_thumbnails and any(
                        path.is_file()
                        for path in (app_support / "thumbnails").glob(f"{ref['item_id']}-*")
                    ):
                        raise BackfillError(f"thumbnail invalidation failed: {ref['item_id']}")
                    if policy.invalidate_pipeline_store and any(
                        path.is_file()
                        for path in (app_support / "pipeline-store").rglob(
                            f"{ref['item_id']}*"
                        )
                    ):
                        raise BackfillError(f"pipeline cache invalidation failed: {ref['item_id']}")
                    scan = database.execute(
                        """
                        SELECT metadataFileModifiedAt, metadataFileSize, mediaFilesJSON,
                               contextImageString
                        FROM archive_scan_cache
                        WHERE itemId=? AND metadataFileString=?
                        """,
                        (ref["item_id"], ref["metadata_path"]),
                    ).fetchall()
                    sidecar_info = Path(ref["metadata_path"]).stat()
                    expected_json = json.dumps(paths, separators=(",", ":"))
                    if (
                        len(scan) != 1
                        or scan[0][0] != sidecar_info.st_mtime
                        or scan[0][1] != sidecar_info.st_size
                        or scan[0][2] != expected_json
                        or scan[0][3]
                        != ref["archive_scan_cache_before"]["contextImageString"]
                    ):
                        raise BackfillError(
                            f"archive_scan_cache fingerprint/path verification failed: {ref['item_id']}"
                        )
            for action in manifest.get("cache_only_actions", []):
                if any(Path(entry["path"]).exists() for entry in action["files"]):
                    raise BackfillError(
                        f"cache-only thumbnail invalidation failed: {action['item_id']}"
                    )
                row = database.execute(
                    "SELECT * FROM media_items WHERE id=?", (action["item_id"],)
                ).fetchone()
                if row is None or _sha256_bytes(
                    _canonical_json({key: _row_value(row[key]) for key in row.keys()})
                ) != action["media_item_sha256"]:
                    raise BackfillError(f"cache-only DB row changed: {action['item_id']}")
                if _sha256(Path(action["metadata_path"])) != action["sidecar_sha256"]:
                    raise BackfillError(f"cache-only sidecar changed: {action['metadata_path']}")
                for media in action["media_files"]:
                    if _sha256(Path(media["path"])) != media["sha256"]:
                        raise BackfillError(f"cache-only media changed: {media['path']}")
        finally:
            database.close()
        self._verify_archive_database(manifest, journal)

    def _verify_archive_database(
        self, manifest: Mapping[str, Any], journal: RunJournal
    ) -> None:
        archive_path = manifest.get("archive_database_path")
        if not archive_path:
            return
        database = _connect_ro(Path(archive_path))
        database.row_factory = sqlite3.Row
        try:
            integrity = database.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                raise BackfillError("archive database integrity verification failed")
            for group in manifest["groups"]:
                result = journal.data["results"][group["group_id"]]
                target_by_old = dict(zip(group["filesystem_aliases"], result["targets"], strict=True))
                for ref in group["references"]:
                    old_path = ref["source_path"]
                    new_path = target_by_old[old_path]
                    mime_type = mimetypes.guess_type(new_path)[0] or "application/octet-stream"
                    for reviewed in ref["server_rows_before"]["archive_jobs"]:
                        row = database.execute(
                            "SELECT * FROM archive_jobs WHERE id=?", (reviewed["id"],)
                        ).fetchone()
                        if (
                            row is None
                            or row["file_path"] != new_path
                            or row["file_size"] != result["media_size"]
                            or row["file_hash"] != result["media_sha256"]
                        ):
                            raise BackfillError(
                                f"archive_jobs verification failed: {reviewed['id']}"
                            )
                        metadata = _decode_json_object(
                            row["metadata"], label=f"archive_jobs[{reviewed['id']}].metadata"
                        )
                        if not _json_references(metadata, new_path) or not _has_run_metadata(
                            metadata, manifest["run_id"], ref["item_id"]
                        ):
                            raise BackfillError(
                                f"archive_jobs metadata verification failed: {reviewed['id']}"
                            )
                    for reviewed in ref["server_rows_before"]["media_files"]:
                        row = database.execute(
                            "SELECT * FROM media_files WHERE id=?", (reviewed["id"],)
                        ).fetchone()
                        if (
                            row is None
                            or row["path"] != new_path
                            or row["file_size"] != result["media_size"]
                            or row["mime_type"] != mime_type
                        ):
                            raise BackfillError(
                                f"media_files verification failed: {reviewed['id']}"
                            )
                        metadata = _decode_json_object(
                            row["metadata"], label=f"media_files[{reviewed['id']}].metadata"
                        )
                        if not _json_references(metadata, new_path) or not _has_run_metadata(
                            metadata, manifest["run_id"], ref["item_id"]
                        ):
                            raise BackfillError(
                                f"media_files metadata verification failed: {reviewed['id']}"
                            )
        finally:
            database.close()

    @staticmethod
    def _verify_policy(
        database: sqlite3.Connection, row: sqlite3.Row, ref: Mapping[str, Any]
    ) -> None:
        policy = POLICIES[ref["derived_policy"]]
        item_id = ref["item_id"]
        _verify_policy_snapshot(
            database, item_id, policy, ref.get("preserved_state", {})
        )
        if policy.reset_general_pipeline:
            if row["pipeline_status"] != "none" or database.execute(
                "SELECT count(*) FROM media_attributes WHERE item_id=?", (item_id,)
            ).fetchone()[0] or database.execute(
                "SELECT count(*) FROM clip_vectors WHERE itemId=?", (item_id,)
            ).fetchone()[0]:
                raise BackfillError(f"general pipeline reset verification failed: {item_id}")
        if policy.reset_vision:
            if row["ocrText"] is not None or database.execute(
                "SELECT count(*) FROM media_file_ocr WHERE item_id=?", (item_id,)
            ).fetchone()[0] or database.execute(
                "SELECT count(*) FROM media_colors WHERE item_id=?", (item_id,)
            ).fetchone()[0]:
                raise BackfillError(f"Vision reset verification failed: {item_id}")
        if policy.reset_video_understanding and (
            row["video_understanding_status"] != "none"
            or database.execute(
                "SELECT count(*) FROM video_segments WHERE item_id=?", (item_id,)
            ).fetchone()[0]
        ):
            raise BackfillError(f"video-understanding reset verification failed: {item_id}")

    def _rollback(
        self, manifest: Mapping[str, Any], run_dir: Path, journal: RunJournal
    ) -> None:
        # Restore files and sidecars first while all writers are offline, then
        # restore the exact pre-run logical SQLite snapshot.
        for group in manifest["groups"]:
            backup = run_dir / "backups" / "media" / f"{group['group_id']}.source"
            result = journal.data.get("results", {}).get(group["group_id"], {})
            targets = [Path(path) for path in result.get("targets", [])]
            old_paths = [Path(path) for path in group["filesystem_aliases"]]
            for target in targets:
                if target not in old_paths:
                    target.unlink(missing_ok=True)
            if old_paths:
                _atomic_install(backup, old_paths[0], backup)
                for old in old_paths[1:]:
                    _atomic_install(old_paths[0], old, backup, hard_link=True)
        restored_sidecars: set[str] = set()
        for group in manifest["groups"]:
            for ref in group["references"]:
                metadata_path = ref["metadata_path"]
                if metadata_path in restored_sidecars:
                    continue
                destination = Path(metadata_path)
                backup = run_dir / "backups" / "sidecars" / f"{_sha256_bytes(metadata_path.encode())}.sidecar"
                _atomic_install(backup, destination, backup)
                restored_sidecars.add(metadata_path)
        self._restore_cache_files(manifest, run_dir)
        database_backup = run_dir / "backups" / "media.sqlite.source"
        if database_backup.exists():
            _database_restore(database_backup, Path(manifest["database_path"]))
        archive_backup = run_dir / "backups" / "archive.db.source"
        if archive_backup.exists() and manifest.get("archive_database_path"):
            _database_restore(archive_backup, Path(manifest["archive_database_path"]))
        self._verify_rollback(manifest)

    def _restore_cache_files(self, manifest: Mapping[str, Any], run_dir: Path) -> None:
        app_support = Path(manifest["database_path"]).parent
        thumbnail_ids = {
            ref["item_id"]
            for group in manifest["groups"]
            for ref in group["references"]
            if POLICIES[ref["derived_policy"]].invalidate_thumbnails
        }
        thumbnail_ids.update(action["item_id"] for action in manifest.get("cache_only_actions", []))
        pipeline_ids = {
            ref["item_id"]
            for group in manifest["groups"]
            for ref in group["references"]
            if POLICIES[ref["derived_policy"]].invalidate_pipeline_store
        }
        for root, ids in (
            (app_support / "thumbnails", thumbnail_ids),
            (app_support / "pipeline-store", pipeline_ids),
        ):
            if root.exists():
                for path in root.rglob("*"):
                    if path.is_file() and any(path.name.startswith(item_id) for item_id in ids):
                        path.unlink()
        backup_root = run_dir / "backups" / "app-support"
        if backup_root.exists():
            for source in backup_root.rglob("*"):
                if source.is_file():
                    destination = app_support / source.relative_to(backup_root)
                    _copy_or_link(source, destination)

    @staticmethod
    def _verify_rollback(manifest: Mapping[str, Any]) -> None:
        database = _connect_ro(Path(manifest["database_path"]))
        database.row_factory = sqlite3.Row
        try:
            for group in manifest["groups"]:
                paths = [Path(path) for path in group["filesystem_aliases"]]
                if any(_sha256(path) != group["source_sha256"] for path in paths):
                    raise BackfillError(f"rollback media hash mismatch: {group['group_id']}")
                if len({(p.stat().st_dev, p.stat().st_ino) for p in paths}) != 1:
                    raise BackfillError("rollback did not restore hard-link aliases")
                for ref in group["references"]:
                    row = database.execute(
                        "SELECT mediaFilesJSON FROM media_items WHERE id=?", (ref["item_id"],)
                    ).fetchone()
                    media = json.loads(row[0] or "[]") if row else []
                    if ref["file_index"] >= len(media) or media[ref["file_index"]] != ref["source_path"]:
                        raise BackfillError(f"rollback DB path mismatch: {ref['item_id']}")
                    if _sha256(Path(ref["metadata_path"])) != ref["sidecar_sha256"]:
                        raise BackfillError(f"rollback sidecar hash mismatch: {ref['metadata_path']}")
            for action in manifest.get("cache_only_actions", []):
                row = database.execute(
                    "SELECT * FROM media_items WHERE id=?", (action["item_id"],)
                ).fetchone()
                if row is None or _sha256_bytes(
                    _canonical_json({key: _row_value(row[key]) for key in row.keys()})
                ) != action["media_item_sha256"]:
                    raise BackfillError(f"rollback cache-only DB mismatch: {action['item_id']}")
                if _sha256(Path(action["metadata_path"])) != action["sidecar_sha256"]:
                    raise BackfillError(f"rollback cache-only sidecar mismatch: {action['item_id']}")
                for media in action["media_files"]:
                    if _sha256(Path(media["path"])) != media["sha256"]:
                        raise BackfillError(f"rollback cache-only media mismatch: {media['path']}")
                for cache_file in action["files"]:
                    if _sha256(Path(cache_file["path"])) != cache_file["sha256"]:
                        raise BackfillError(f"rollback cache file mismatch: {cache_file['path']}")
        finally:
            database.close()
        if manifest.get("archive_database_path"):
            archive = _connect_ro(Path(manifest["archive_database_path"]))
            archive.row_factory = sqlite3.Row
            try:
                for group in manifest["groups"]:
                    for ref in group["references"]:
                        for table, records in ref["server_rows_before"].items():
                            for record in records:
                                row = archive.execute(
                                    f'SELECT * FROM "{table}" WHERE id=?', (record["id"],)
                                ).fetchone()
                                current = (
                                    {key: _row_value(row[key]) for key in row.keys()}
                                    if row is not None
                                    else None
                                )
                                if current is None or _sha256_bytes(
                                    _canonical_json(current)
                                ) != record["row_sha256"]:
                                    raise BackfillError(
                                        f"rollback archive.db mismatch: {table}[{record['id']}]"
                                    )
            finally:
                archive.close()


def connection_user_version(path: Path) -> int:
    connection = _connect_ro(path)
    try:
        return int(connection.execute("PRAGMA user_version").fetchone()[0])
    finally:
        connection.close()


def _retarget_file_url(value: str | None, old_path: str, new_path: str) -> str | None:
    if not value:
        return value
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "file" or urllib.parse.unquote(parsed.path) != old_path:
        return value
    return Path(new_path).resolve().as_uri()


def patch_sidecar(content: str, patches: Sequence[Mapping[str, Any]]) -> str:
    """Surgically patch exact references while preserving user formatting bytes."""
    opening = re.match(r"\A---[ \t]*(\r?\n)", content)
    if opening is None:
        raise BackfillError("sidecar has no YAML frontmatter")
    newline = opening.group(1)
    closing = re.search(r"(?m)^---[ \t]*(?=\r?$)", content[opening.end() :])
    if closing is None:
        raise BackfillError("sidecar frontmatter is unterminated")
    closing_start = opening.end() + closing.start()
    frontmatter = content[:closing_start]
    tail = content[closing_start:]

    provenance_pattern = re.compile(
        r"(?m)^nodraw_media_compat_backfill:[ \t]*(?P<value>[^\r\n]*)(?:\r?\n)?"
    )
    existing: list[Any] = []
    existing_match = provenance_pattern.search(frontmatter)
    if existing_match is not None:
        scalar = existing_match.group("value").strip()
        if len(scalar) >= 2 and scalar[0] == scalar[-1] == "'":
            scalar = scalar[1:-1].replace("''", "'")
        try:
            decoded = json.loads(scalar)
        except json.JSONDecodeError as exc:
            raise BackfillError("existing media compatibility provenance is not valid JSON") from exc
        if not isinstance(decoded, list):
            raise BackfillError("existing media compatibility provenance is not a JSON array")
        existing = decoded
        frontmatter = provenance_pattern.sub("", frontmatter, count=1)

    keys = {(patch["run_id"], patch["item_id"], patch["file_index"]) for patch in patches}
    existing = [
        entry
        for entry in existing
        if not isinstance(entry, Mapping)
        or (entry.get("run_id"), entry.get("item_id"), entry.get("file_index")) not in keys
    ]
    for patch in patches:
        old_path = patch["old_path"]
        new_path = patch["new_path"]
        old_name = Path(old_path).name
        new_name = Path(new_path).name
        if old_name != new_name:
            pattern = re.compile(r"(!?\[\[)" + re.escape(old_name) + r"(?=(?:[|#][^\]]*)?\]\])")
            tail = pattern.sub(lambda match: match.group(1) + new_name, tail)
        old_uri = Path(old_path).resolve().as_uri()
        new_uri = Path(new_path).resolve().as_uri()
        frontmatter = frontmatter.replace(old_uri, new_uri)
        frontmatter = re.sub(
            r"(?m)^(?P<prefix>[ \t]*file_size[ \t]*:[ \t]*)[^#\r\n]*(?P<suffix>[ \t]*(?:#.*)?)$",
            lambda match: f"{match.group('prefix')}{patch['output_size']}{match.group('suffix')}",
            frontmatter,
            count=1,
        )
        existing.append(
            {
                "run_id": patch["run_id"],
                "item_id": patch["item_id"],
                "file_index": patch["file_index"],
                "original_name": old_name,
                "normalized_name": new_name,
                "source_sha256": patch["source_sha256"],
                "output_sha256": patch["output_sha256"],
                "recovery_record": patch["recovery_record"],
                "provenance": patch["provenance"],
            }
        )
    compact = json.dumps(existing, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    quoted = "'" + compact.replace("'", "''") + "'"
    if not frontmatter.endswith(("\n", "\r")):
        frontmatter += newline
    frontmatter += f"nodraw_media_compat_backfill: {quoted}{newline}"
    return frontmatter + tail


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    plan = subparsers.add_parser("plan", help="write an immutable dry-run manifest")
    plan.add_argument("--db", type=Path, required=True)
    plan.add_argument("--archive-db", type=Path)
    plan.add_argument("--archive", type=Path, required=True)
    plan.add_argument("--allowlist", type=Path, required=True)
    plan.add_argument("--manifest", type=Path, required=True)
    plan.add_argument("--recovery-root", type=Path)
    for name in ("apply", "verify", "rollback", "status"):
        command = subparsers.add_parser(name)
        command.add_argument("--manifest", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    engine = BackfillEngine()
    try:
        if args.command == "plan":
            result = engine.plan(
                database_path=args.db,
                archive_database_path=args.archive_db,
                archive_root=args.archive,
                allowlist_path=args.allowlist,
                manifest_path=args.manifest,
                recovery_root=args.recovery_root,
            )
        elif args.command == "apply":
            result = engine.apply(args.manifest)
        elif args.command == "verify":
            result = engine.verify(args.manifest)
        elif args.command == "rollback":
            result = engine.rollback(args.manifest)
        else:
            result = engine.status(args.manifest)
    except (BackfillError, OSError, sqlite3.Error, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(_jsonable(result), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
