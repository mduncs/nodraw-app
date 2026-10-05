"""The one writer for the YAML header of every sidecar the server publishes.

Values are escaped here, never at call sites. Headers built by hand broke on a `"` or a
trailing `\\` in an author or title, and the app can't read such a sidecar (5 of the
8,314 in one real archive on 2026-10-03).
"""
from __future__ import annotations

from datetime import datetime
import json
import re
from typing import Iterable, Mapping

import yaml

_RESOLVER = yaml.resolver.Resolver()
_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
# Fields holding an identifier the server chooses (`twitter`, `no_media_found`) stay
# unquoted, as they always were. Everything else from a page or a person is quoted.
_BARE_FIELDS = {"platform", "save_mode", "fallback_reason"}
_WORD = re.compile(r"[a-z][a-z0-9_-]*\Z")
# A double-quoted YAML scalar can't hold these raw: C1 controls, the separators YAML
# folds into spaces, and a byte-order mark.
_UNSAFE = re.compile("[\x7f-\x9f\u2028\u2029\ufeff]")
# Lone surrogates (half an emoji from a JavaScript string) can't be encoded as UTF-8.
_SURROGATE = re.compile("[\ud800-\udfff]")


class DateText(str):
    """A date the client sent as text: a YAML timestamp when it reads as one, else text."""


def _resolves_as(text: str, tag: str) -> bool:
    return _RESOLVER.resolve(yaml.ScalarNode, text, (True, False)) == f"tag:yaml.org,2002:{tag}"


def _clean(text: str) -> str:
    return _SURROGATE.sub("\ufffd", text)


def quoted(text: str) -> str:
    """`text` as a double-quoted YAML scalar; emoji and other Unicode stay readable."""
    return _UNSAFE.sub(lambda match: f"\\u{ord(match.group()):04x}", json.dumps(_clean(text), ensure_ascii=False))


def yaml_value(value, bare: bool = False) -> str:
    """One header value: lists in flow style with quoted items, dates as timestamps.

    With `bare`, a lowercase identifier is written unquoted when YAML reads it back as text.
    """
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(quoted(str(item)) for item in value) + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, datetime):
        # The app reads a timestamp without a zone as UTC; datetime.now() is local time.
        return (value if value.tzinfo else value.astimezone()).isoformat()
    text = str(value)
    if isinstance(value, DateText) and _resolves_as(text, "timestamp"):
        return text
    if bare and _WORD.match(text) and _resolves_as(text, "str"):
        return text
    return quoted(text)


def render_sidecar(fields: Mapping[str, object], body: Iterable[str] = ()) -> bytes:
    """A complete sidecar: header fields in order, then the body lines.

    Fields that are None, empty text or an empty list are left out, as the writers
    always did; 0 and False are kept.
    """
    lines = ["---"]
    for key, value in fields.items():
        if not _KEY.match(key):
            raise ValueError(f"Not a sidecar field name: {key!r}")
        if isinstance(value, (list, tuple)):
            value = [item for item in value if item is not None and item != ""]
        if value is None or value == "" or value == []:
            continue
        lines.append(f"{key}: {yaml_value(value, bare=key in _BARE_FIELDS)}")
    lines.append("---")
    return _clean("\n".join([*lines, *body])).encode("utf-8")
