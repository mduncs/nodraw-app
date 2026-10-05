"""Versioned capture contract and the server's single capture boundary."""

from __future__ import annotations

from datetime import datetime
import asyncio
import hashlib
import json
import logging
import os
import re
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from typing import Awaitable, Callable, Dict, List, Literal, Optional
from uuid import uuid4

from fastapi import BackgroundTasks
from pydantic import BaseModel, Field
import yaml
from sidecar_projection import ProjectionError, project, read_base


CaptureKind = Literal["page", "media", "link", "selection"]
CaptureDisposition = Literal["accepted", "duplicate", "queued"]

logger = logging.getLogger(__name__)


class CaptureTargetRejectedError(ValueError):
    """Raised before persistence when a page capture targets a collection URL."""


def collection_capture_block_reason(raw_url: str) -> Optional[str]:
    """Block known feeds/profiles/search pages that expand into bulk downloads."""
    try:
        parsed = urlparse(raw_url)
    except ValueError:
        return "Open a valid page before archiving."

    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return "Open a valid page before archiving."

    host = parsed.hostname.lower().rstrip(".")
    for prefix in ("www.", "old.", "new.", "m.", "mobile."):
        if host.startswith(prefix):
            host = host[len(prefix):]
            break
    path = parsed.path or "/"

    if host in {"x.com", "twitter.com"}:
        if re.match(r"^/(?:[^/]+/status|i/(?:web/)?status)/\d+(?:/|$)", path):
            return None
        return "Open a specific post before archiving from X."

    if host == "youtube.com":
        is_watch = path == "/watch" and bool(parse_qs(parsed.query).get("v"))
        if is_watch or re.match(r"^/(?:shorts|live)/[^/]+(?:/|$)", path):
            return None
        return "Open a specific video before archiving from YouTube."

    if host == "youtu.be":
        return None if re.match(r"^/[^/]+(?:/|$)", path) else "Open a specific video before archiving from YouTube."

    if host == "bsky.app":
        if re.match(r"^/profile/[^/]+/post/[^/]+(?:/|$)", path):
            return None
        return "Open a specific post before archiving from Bluesky."

    if host == "reddit.com":
        if re.search(r"(?:^|/)comments/[^/]+(?:/|$)", path) or re.match(r"^/gallery/[^/]+(?:/|$)", path):
            return None
        return "Open a specific post before archiving from Reddit."

    return None


def validate_capture_target(intent: "CaptureIntent") -> None:
    if intent.kind not in {"page", "link"}:
        return
    reason = collection_capture_block_reason(intent.targetUrl or intent.sourcePageUrl)
    if reason:
        raise CaptureTargetRejectedError(reason)


class CookieData(BaseModel):
    name: str
    value: str
    domain: str = ""
    path: str = "/"


class PageContext(BaseModel):
    title: str = ""
    canonicalUrl: str = ""
    author: str = ""
    description: str = ""
    publishedAt: str = ""
    siteName: str = ""
    language: str = ""
    image: str = ""
    schemaTypes: List[str] = Field(default_factory=list)


class MediaContext(BaseModel):
    url: str
    type: str = ""
    alt: str = ""


class SelectionContext(BaseModel):
    text: str = ""
    html: str = ""


class UserContext(BaseModel):
    tags: List[str] = Field(default_factory=list)
    note: str = ""


# The option keys a client may set: what the extension's content scripts put in
# siteData, and content-gallery.js's resolution preset. The server's own keys
# (filenameStem, headers, tile_cache, user_tags, capture_intent...) share the same
# options dict, so anything else a client sends is dropped.
CLIENT_SITE_DATA_KEYS = frozenset({
    "pageContext", "mediaType", "platform", "title", "author", "description", "tags",
    "pageUrl", "dateTaken", "assetId", "tweetContent", "quotes", "emotionTag",
    "twitterQuoted", "redditContent", "postContent", "videoContent",
})
CLIENT_DOWNLOAD_KEYS = frozenset({"max_width"})


def client_options(values: Dict, allowed: frozenset, field: str) -> Dict:
    dropped = sorted(str(key) for key in values if key not in allowed)
    if dropped:
        logger.warning("Ignoring capture %s keys the server sets itself or doesn't know: %s", field, dropped)
    return {key: value for key, value in values.items() if key in allowed}


class CaptureOptions(BaseModel):
    saveMode: Literal["full", "quick", "text"] = "full"
    screenshot: str = ""
    platform: str = "web"
    siteData: Dict = Field(default_factory=dict)
    download: Dict = Field(default_factory=dict)
    captureAgain: bool = False


class CaptureIntent(BaseModel):
    schemaVersion: Literal[1] = 1
    captureId: str
    fingerprint: str
    kind: CaptureKind
    targetUrl: str
    sourcePageUrl: str
    createdAt: datetime
    page: PageContext = Field(default_factory=PageContext)
    media: Optional[MediaContext] = None
    selection: Optional[SelectionContext] = None
    user: UserContext = Field(default_factory=UserContext)
    options: CaptureOptions = Field(default_factory=CaptureOptions)


class CaptureSubmission(BaseModel):
    intent: CaptureIntent
    cookies: List[CookieData] = Field(default_factory=list)


def capture_identity(intent: CaptureIntent) -> str:
    """Server-verified identity, never the client's short advisory hash.

    Preserve all requested content/context; only transport identity/time are
    ignored. An explicit rearchive is distinct, but its retries keep the same ID.
    """
    content = intent.model_dump(mode="json", exclude={"captureId", "createdAt", "fingerprint"})
    if intent.options.captureAgain:
        content["rearchiveOperation"] = intent.captureId
    encoded = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False)
    return "server-v2-" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()


class CapturePatch(BaseModel):
    tags: Optional[List[str]] = None
    note: Optional[str] = None
    mutationId: Optional[str] = Field(default=None, min_length=1, max_length=128)


class CaptureRetry(BaseModel):
    """Fresh request context for replaying a stored failed intent.

    Cookies deliberately remain outside CaptureIntent so credentials are never
    written to the durable archive database.
    """

    cookies: List[CookieData] = Field(default_factory=list)


class CaptureReceipt(BaseModel):
    schemaVersion: Literal[1] = 1
    captureId: str
    jobId: str
    disposition: CaptureDisposition
    status: str
    message: str = ""
    error: Optional[str] = None
    metadataProjection: Optional[Literal["pending", "applied", "failed"]] = None
    metadataRevision: int = 0
    metadataError: Optional[str] = None
    metadataMutationId: Optional[str] = None
    metadataMutationRevision: Optional[int] = None
    # Date (YYYY-MM-DD) the existing copy was kept; only set on duplicate receipts.
    savedAt: Optional[str] = None


ArchiveProcessor = Callable[..., Awaitable[None]]
ImageProcessor = Callable[..., Awaitable[None]]


class CaptureRetryError(RuntimeError):
    """A failed capture exists but cannot be safely replayed."""


def _sidecar_candidates(job: Dict) -> List[Path]:
    """Return conservative Markdown sidecar candidates for a completed job."""
    candidates: List[Path] = []
    metadata = job.get("metadata") or {}

    sidecar_path = metadata.get("sidecar_path")
    if sidecar_path:
        candidates.append(Path(sidecar_path))

    file_path = job.get("file_path")
    if file_path:
        archived_path = Path(file_path)
        if archived_path.suffix.lower() == ".md":
            candidates.append(archived_path)
        else:
            candidates.append(archived_path.with_suffix(".md"))
            # Multi-image Twitter captures store the first media path as
            # ``...-tweetid-1.jpg`` but use one tweet-level ``...-tweetid.md``.
            if re.search(r"-\d+$", archived_path.stem):
                candidates.append(
                    archived_path.with_name(
                        f"{re.sub(r'-\d+$', '', archived_path.stem)}.md"
                    )
                )

    for media_path in metadata.get("files") or []:
        candidates.append(Path(media_path).with_suffix(".md"))

    unique: List[Path] = []
    seen = set()
    for candidate in candidates:
        normalized = str(candidate)
        if normalized not in seen:
            seen.add(normalized)
            unique.append(candidate)
    return unique


_FRONT_MATTER_LIMIT = 64 * 1024
_SAFE_LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
_MISSING_SIDECAR = "Saved media is intact, but its Markdown sidecar is missing. Restore the sidecar and retry metadata."


def _sidecar_header(path: Path) -> Dict:
    """Read a bounded YAML header, never the Markdown body."""
    try:
        with path.open("rb") as stream:
            first = stream.readline(_FRONT_MATTER_LIMIT + 1)
            if first.removeprefix(b"\xef\xbb\xbf").strip() != b"---":
                return {}
            remaining = _FRONT_MATTER_LIMIT - len(first)
            lines = []
            while remaining > 0:
                line = stream.readline(remaining + 1)
                remaining -= len(line)
                if not line or remaining < 0:
                    return {}
                if line.rstrip(b" \t\r\n") == b"---":
                    header = yaml.load(b"".join(lines).decode("utf-8"), Loader=_SAFE_LOADER)
                    return header if isinstance(header, dict) else {}
                lines.append(line)
    except (OSError, UnicodeError, yaml.YAMLError, ValueError):
        pass
    return {}


def _find_archive_sidecar(root: Optional[Path], job: Dict) -> Path:
    """Prefer a unique capture ID, then a unique legacy source URL."""
    capture_id = job.get("capture_id")
    source = job.get("url")
    id_matches, source_matches = [], []
    if root is not None:
        for directory, subdirs, files in os.walk(root, followlinks=False):
            subdirs[:] = [name for name in subdirs if not name.startswith(".")]
            for name in files:
                if name.startswith(".") or Path(name).suffix.lower() != ".md":
                    continue
                path = Path(directory) / name
                if path.is_symlink() or not path.is_file():
                    continue
                header = _sidecar_header(path)
                header_id = header.get("capture_id")
                if capture_id and header_id == capture_id:
                    id_matches.append(path)
                    if len(id_matches) > 1:
                        raise ProjectionError("Saved media is intact, but several Markdown sidecars match this capture. Resolve the sidecars and retry metadata.")
                elif source and header.get("source") == source and header_id is None:
                    # Keep scanning: a capture ID match outranks source matches.
                    if len(source_matches) < 2:
                        source_matches.append(path)
    matches = id_matches or source_matches
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise ProjectionError("Saved media is intact, but several Markdown sidecars match this capture. Resolve the sidecars and retry metadata.")
    raise ProjectionError(_MISSING_SIDECAR)


class CaptureService:
    """Owns idempotency, durable receipts, and capture dispatch."""

    def __init__(
        self,
        database,
        archive_processor: ArchiveProcessor,
        image_processor: ImageProcessor,
        archive_root: Optional[Path] = None,
    ):
        self.database = database
        self.archive_processor = archive_processor
        self.image_processor = image_processor
        db_path = getattr(database, "db_path", None)
        self.archive_root = Path(archive_root) if archive_root is not None else (
            Path(db_path).parent if isinstance(db_path, (str, Path)) else None
        )
        self._projection_locks = {}

    async def _resolve_sidecar(self, job: Dict) -> Path:
        for candidate in _sidecar_candidates(job):
            if candidate.is_file():
                return candidate
        if job.get("status") != "completed":
            # A capture still in flight has no sidecar of its own yet, and a search
            # could find an older capture of the same URL.
            raise ProjectionError(_MISSING_SIDECAR)
        candidate = await asyncio.to_thread(_find_archive_sidecar, self.archive_root, job)
        await self.database.record_capture_sidecar(job["id"], str(candidate))
        job.setdefault("metadata", {})["sidecar_path"] = str(candidate)
        return candidate

    @staticmethod
    def _receipt(job: Dict, disposition: CaptureDisposition) -> CaptureReceipt:
        status = {
            "pending": "accepted",
            "downloading": "processing",
            "completed": "saved",
            "failed": "failed",
        }.get(job.get("status"), job.get("status") or "accepted")
        projection = job.get("metadata_projection")
        error = job.get("projection_error")
        return CaptureReceipt(
            captureId=job.get("capture_id") or "",
            jobId=job["id"],
            disposition=disposition,
            status=status,
            message=(job.get("error") or "Capture failed") if status == "failed" else (
                "Already captured" if disposition == "duplicate" else "Capture accepted"
            ),
            error=(job.get("error") or "Capture failed") if status == "failed" else None,
            metadataProjection=("failed" if error else "pending") if projection else ("applied" if job.get("projected_revision") else None),
            metadataRevision=job.get("metadata_revision") or 0,
            metadataError=error,
            savedAt=(str(job.get("completed_at") or job.get("created_at") or "")[:10] or None)
            if disposition == "duplicate" else None,
        )

    def _dispatch(
        self,
        job_id: str,
        intent: CaptureIntent,
        cookies: List[CookieData],
        background_tasks: BackgroundTasks,
    ) -> None:
        intent_dict = intent.model_dump(mode="json")
        target_url = intent.targetUrl or intent.sourcePageUrl
        if intent.kind == "media" and intent.media and intent.media.type == "image":
            background_tasks.add_task(
                self.image_processor,
                job_id=job_id,
                intent=intent,
                cookies=cookies,
            )
            return

        options = {
            **client_options(intent.options.siteData, CLIENT_SITE_DATA_KEYS, "siteData"),
            **client_options(intent.options.download, CLIENT_DOWNLOAD_KEYS, "download"),
            "capture_intent": intent_dict,
            "selection": intent.selection.model_dump() if intent.selection else None,
            "user_tags": intent.user.tags,
            "user_note": intent.user.note,
        }
        background_tasks.add_task(
            self.archive_processor,
            job_id=job_id,
            url=target_url,
            cookies=cookies,
            options=options,
            screenshot=intent.options.screenshot or None,
            save_mode="text" if intent.kind == "selection" else intent.options.saveMode,
            page_title=intent.page.title or None,
            timestamp=intent.createdAt,
        )

    async def submit(
        self,
        submission: CaptureSubmission,
        background_tasks: BackgroundTasks,
    ) -> CaptureReceipt:
        intent = submission.intent
        validate_capture_target(intent)
        existing = await self.database.get_job_by_capture_id(intent.captureId)
        if existing:
            return self._receipt(existing, "duplicate")

        fingerprint = capture_identity(intent)
        equivalent = await self.database.get_job_by_fingerprint(fingerprint)
        if equivalent:
            return self._receipt(equivalent, "duplicate")

        # Older jobs used a client-supplied 32-bit fingerprint. Reuse a legacy
        # receipt only after comparing its actual requested content. A collision
        # must never silently discard a different capture.
        legacy = await self.database.get_job_by_fingerprint(intent.fingerprint)
        if legacy and legacy.get("intent"):
            try:
                previous = CaptureIntent.model_validate(legacy["intent"])
                if capture_identity(previous) == fingerprint:
                    return self._receipt(legacy, "duplicate")
            except (ValueError, TypeError):
                pass

        job_id = str(uuid4())
        intent_dict = intent.model_dump(mode="json")
        target_url = intent.targetUrl or intent.sourcePageUrl
        created = await self.database.create_job(
            job_id=job_id,
            url=target_url,
            page_title=intent.page.title,
            page_url=intent.sourcePageUrl,
            timestamp=intent.createdAt,
            capture_id=intent.captureId,
            fingerprint=fingerprint,
            capture_kind=intent.kind,
            intent=intent_dict,
        )
        if created is False:
            # A concurrent equivalent submission won the unique capture or
            # fingerprint constraint after our optimistic lookups.
            winner = await self.database.get_job_by_capture_id(intent.captureId)
            if winner is None:
                winner = await self.database.get_job_by_fingerprint(fingerprint)
            if winner is not None:
                return self._receipt(winner, "duplicate")
            raise RuntimeError("Capture insert conflicted without a durable receipt")

        self._dispatch(job_id, intent, submission.cookies, background_tasks)

        return CaptureReceipt(
            captureId=intent.captureId,
            jobId=job_id,
            disposition="accepted",
            status="accepted",
            message="Capture accepted",
        )

    async def get(self, capture_id: str) -> Optional[CaptureReceipt]:
        job = await self.database.get_job_by_capture_id(capture_id)
        return self._receipt(job, "accepted") if job else None

    async def patch(self, capture_id: str, patch: CapturePatch) -> Optional[CaptureReceipt]:
        # Serializing this service's acceptance/flush avoids own-write conflicts;
        # durable revisions still protect against restart or another service.
        async with self._projection_locks.setdefault(capture_id, asyncio.Lock()):
            return await self._patch(capture_id, patch)

    async def _patch(self, capture_id: str, patch: CapturePatch) -> Optional[CaptureReceipt]:
        job = await self.database.get_job_by_capture_id(capture_id)
        if not job:
            return None
        fields = {}
        if patch.tags is not None:
            fields["tags"] = list(dict.fromkeys(tag.strip() for tag in patch.tags if tag.strip()))
        if patch.note is not None:
            fields["notes"] = patch.note.strip()
        if fields:
            user = (job.get("intent") or {}).get("user") or {}
            bases = {"tags": user.get("tags") or [], "notes": user.get("note") or ""}
            try:
                candidate = await self._resolve_sidecar(job)
                bases = await asyncio.to_thread(read_base, candidate)
            except Exception:
                # The edit is still durable when IO/parsing fails; flush
                # reports the actionable error after the DB acceptance.
                pass
            job = await self.database.enqueue_capture_patch(capture_id, fields, bases, patch.mutationId)
        accepted_revision = job.get("accepted_mutation_revision")
        receipt = await self.flush_projection(job)
        if fields and patch.mutationId:
            receipt.metadataMutationId = patch.mutationId
            receipt.metadataMutationRevision = accepted_revision
        return receipt

    async def flush_projection(self, job: Dict) -> CaptureReceipt:
        pending = job.get("metadata_projection")
        if not pending:
            return self._receipt(job, "accepted")
        error = None
        if job.get("status") == "completed":
            try:
                candidate = await self._resolve_sidecar(job)
                await asyncio.to_thread(project, candidate, pending["fields"], pending["bases"])
            except Exception as exc:
                error = str(exc)
            await self.database.finish_capture_projection(job["capture_id"], job["metadata_revision"], error)
            job = await self.database.get_job_by_capture_id(job["capture_id"])
        receipt = self._receipt(job, "accepted")
        if receipt.metadataProjection in {"pending", "failed"}:
            receipt.message = "Metadata saved for retry" if error else "Metadata update pending"
        return receipt

    async def reconcile_projections(self):
        for job in await self.database.pending_capture_projections():
            await self.flush_projection(job)

    async def retry(
        self,
        capture_id: str,
        retry: CaptureRetry,
        background_tasks: BackgroundTasks,
    ) -> Optional[CaptureReceipt]:
        """Atomically replay a failed job from its stored intent.

        The original job and capture IDs remain stable. Only a failed job can
        be claimed, which prevents double dispatch if two retry requests race.
        """
        job = await self.database.get_job_by_capture_id(capture_id)
        if not job:
            return None
        if job.get("status") == "completed" and job.get("metadata_projection"):
            return await self.flush_projection(job)
        if job.get("status") != "failed":
            return self._receipt(job, "duplicate")

        from database import Database
        if isinstance(self.database, Database):
            from capture_recovery import reconcile_job
            try:
                job = await reconcile_job(self.database, job)
            except Exception as exc:
                raise CaptureRetryError(str(exc)) from exc
            if job["status"] == "completed":
                return await self.flush_projection(job)

        intent_data = job.get("intent")
        if not intent_data:
            raise CaptureRetryError("Capture predates durable intents and cannot be retried")
        try:
            intent = CaptureIntent.model_validate(intent_data)
        except Exception as exc:
            raise CaptureRetryError("Stored capture intent is invalid") from exc
        try:
            validate_capture_target(intent)
        except CaptureTargetRejectedError as exc:
            raise CaptureRetryError(str(exc)) from exc

        claimed = await self.database.claim_capture_retry(capture_id)
        if not claimed:
            current = await self.database.get_job_by_capture_id(capture_id)
            return self._receipt(current or job, "duplicate")

        self._dispatch(job["id"], intent, retry.cookies, background_tasks)
        return CaptureReceipt(
            captureId=capture_id,
            jobId=job["id"],
            disposition="accepted",
            status="accepted",
            message="Retry accepted",
        )
