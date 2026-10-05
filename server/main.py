#!/usr/bin/env python3
"""
nodraw Server
Local server for handling media downloads from browser extension
"""

try:
    import setproctitle
except ImportError:
    setproctitle = None

from fastapi import FastAPI, HTTPException, BackgroundTasks, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel
from datetime import datetime
from typing import List, Dict, Optional, Literal
import asyncio
from pathlib import Path
import logging
import base64
import re
import time
import os
import shutil
import threading
from uuid import uuid4
from collections import defaultdict
from urllib.parse import urlparse, urlsplit, parse_qs

from downloaders import DownloadManager, DownloadFailureKind, DownloadResult
from downloaders.runtime_safety import (
    _move_file_no_clobber as move_file_no_clobber,
    publish_bytes_no_clobber,
    publish_staged_files,
    preserve_public_artifacts,
    relocate_public_file,
)
from media_normalization import start_media_runtime, shutdown_media_runtime
from storage import StorageManager, detect_platform
from platforms import YOUTUBE_DOMAINS, matches_domains, url_hostname, url_path
from database import Database, CaptureMutationConflict
from capture_recovery import track_capture, reconcile_startup, register_staging
from sidecar_writer import DateText, render_sidecar
from capture_service import (
    CLIENT_DOWNLOAD_KEYS,
    CaptureIntent,
    CapturePatch,
    CaptureRetry,
    CaptureRetryError,
    CaptureService,
    CaptureTargetRejectedError,
    CaptureSubmission,
    CookieData as CaptureCookieData,
    client_options,
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def _set_process_title(title: str) -> bool:
    """Set the process title when the optional native helper is available."""
    if setproctitle is None:
        logger.debug("setproctitle is not installed; process title left unchanged")
        return False

    try:
        setproctitle.setproctitle(title)
        return True
    except Exception as exc:
        logger.warning("Failed to set process title: %s", exc)
        return False


_set_process_title("nodraw-server")

# Dynamic port discovery
from portdiscovery import find_free_port, write_port_file, remove_port_file, register_cleanup

SERVICE_NAME = "org.nodraw.download-server"

# Environment-based configuration (set by NoDraw app or standalone defaults)
# PORT=0 means dynamic allocation (default). Set a specific port to override.
_port_env = int(os.environ.get("MEDIA_ARCHIVER_PORT", "0"))
PORT = find_free_port() if _port_env == 0 else _port_env
ARCHIVE_DIR = os.environ.get("MEDIA_ARCHIVER_DIR", os.path.expanduser("~/MediaArchive"))
BIN_DIR = os.environ.get("MEDIA_ARCHIVER_BIN", "")

# Brief delay between images in multi-image tweets
TWITTER_IMAGE_DELAY = float(os.environ.get("TWITTER_IMAGE_DELAY", "0.3"))
EXTENSION_ACTIVE_WINDOW_SECONDS = int(os.environ.get("EXTENSION_ACTIVE_WINDOW_SECONDS", "180"))

# Prepend tool bin directory to PATH so shutil.which() finds bundled tools
if BIN_DIR:
    os.environ["PATH"] = BIN_DIR + ":" + os.environ.get("PATH", "")
    logger.info(f"Prepended {BIN_DIR} to PATH")

# Global metrics store with thread-safe access
_metrics_lock = threading.Lock()
_index_locks_guard = threading.Lock()
_index_locks: Dict[str, threading.Lock] = {}
server_metrics = {
    'requests': defaultdict(lambda: {'count': 0, 'total_ms': 0.0, 'errors': 0}),
    'downloads': {
        'total': 0,
        'success': 0,
        'failed': 0,
        'total_bytes': 0,
        'by_platform': defaultdict(lambda: {'count': 0, 'success': 0, 'failed': 0}),
        'error_types': defaultdict(int)
    },
    'extension': {
        'seen_ever': False,
        'last_seen': None,
        'extension_id': None,
        'extension_version': None,
        'browser': None,
        'last_trigger': None,
        'last_user_agent': None
    },
    'start_time': time.time()
}

app = FastAPI(
    title="nodraw",
    description="Local media archival server with yt-dlp and gallery-dl support",
    version="1.0.0"
)

_EXTENSION_ORIGIN = r"(?:chrome|moz)-extension://[A-Za-z0-9-]+"

# CORS for browser extension. allow_origins takes literal strings, so a "*" in an
# entry never matched a real extension origin; the pattern does.
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=_EXTENSION_ORIGIN,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"]
)

_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}
_READ_METHODS = {"GET", "HEAD", "OPTIONS"}


def _local_request_refusal(method: str, host: str, origin: Optional[str]) -> Optional[str]:
    """Why a request can't come from one of NoDraw's own clients, or None.

    Any web page can send requests to this port. The Host must be a loopback name,
    so a rebound DNS name can't reach the server. A write that carries an Origin
    must come from the extension or a page this server served; the app, curl and
    other local tools send none.
    """
    try:
        hostname = urlsplit(f"//{host}").hostname
    except ValueError:
        hostname = None
    if hostname not in _LOOPBACK_HOSTS:
        return f"Requests must be addressed to localhost, not {host!r}."
    if method in _READ_METHODS or origin is None:
        return None
    if re.fullmatch(_EXTENSION_ORIGIN, origin) or origin == f"http://{host}":
        return None
    return f"Writes from {origin!r} are not accepted."


@app.middleware("http")
async def local_clients_only(request: Request, call_next):
    refusal = _local_request_refusal(
        request.method, request.headers.get("host", ""), request.headers.get("origin"),
    )
    if refusal:
        logger.warning(f"Refused {request.method} {request.url.path}: {refusal}")
        return JSONResponse(status_code=403, content={"detail": refusal})
    return await call_next(request)


@app.middleware("http")
async def timing_middleware(request: Request, call_next):
    """Track request timing and error rates"""
    start = time.time()
    response = await call_next(request)
    duration_ms = (time.time() - start) * 1000

    endpoint = request.url.path
    with _metrics_lock:
        server_metrics['requests'][endpoint]['count'] += 1
        server_metrics['requests'][endpoint]['total_ms'] += duration_ms
        if response.status_code >= 400:
            server_metrics['requests'][endpoint]['errors'] += 1

    return response

# Request/Response models
class JobStatus(BaseModel):
    id: str
    status: str
    url: str
    created_at: datetime
    completed_at: Optional[datetime] = None
    file_path: Optional[str] = None
    error: Optional[str] = None
    error_category: Optional[str] = None
    metadata: Optional[Dict] = {}

class ImageMetadata(BaseModel):
    platform: str = "web"
    title: str = ""
    author: str = ""
    description: str = ""
    page_url: Optional[str] = None
    tags: List[str] = []
    note: str = ""
    dateTaken: str = ""
    assetId: str = ""  # For Google Arts & Culture uniqueness

class ImageArchiveRequest(BaseModel):
    image_url: str
    page_url: Optional[str] = None
    save_mode: Literal["full", "quick"] = "full"
    cookies: List[CaptureCookieData] = []
    metadata: ImageMetadata = ImageMetadata()
    options: Optional[Dict] = {}

class CheckArchivedRequest(BaseModel):
    url: str
    check_file_exists: bool = True

class CheckArchivedResponse(BaseModel):
    archived: bool
    job_id: Optional[str] = None
    file_path: Optional[str] = None
    file_exists: Optional[bool] = None
    archived_date: Optional[datetime] = None
    age_days: Optional[int] = None

class ExtensionHeartbeatRequest(BaseModel):
    extension_id: Optional[str] = None
    extension_version: Optional[str] = None
    browser: Optional[str] = None
    trigger: Optional[str] = None

# Initialize components (use env-configured archive directory)
_archive_path = Path(ARCHIVE_DIR)
db = Database(_archive_path / "archive.db")
storage = StorageManager(_archive_path)
downloader = DownloadManager()
_capture_service: Optional[CaptureService] = None


def get_capture_service() -> CaptureService:
    """Resolve the service lazily after background processors are defined."""
    global _capture_service
    if _capture_service is None or _capture_service.database is not db:
        _capture_service = CaptureService(db, process_download, process_image_capture, archive_root=storage.base)
    return _capture_service


def extract_content_id(url: str) -> Optional[str]:
    """Extract content ID from URL (tweet ID, video ID, etc.)"""
    import re
    path = url_path(url)
    if matches_domains(url, YOUTUBE_DOMAINS):
        if path == '/watch':
            return (parse_qs(urlparse(url).query).get('v') or [None])[0]
        pattern = (
            r'^/([a-zA-Z0-9_-]+)' if matches_domains(url, ('youtu.be',))
            else r'^/shorts/([a-zA-Z0-9_-]+)'
        )
        match = re.search(pattern, path)
        return match.group(1) if match else None
    for pattern in (r'/status/(\d+)', r'/comments/([a-zA-Z0-9]+)'):
        match = re.search(pattern, path)
        if match:
            return match.group(1)
    return None


# Platform detection now uses storage.detect_platform (single source of truth)


async def decode_and_save_screenshot(base64_data: str, output_path: Path) -> bool:
    """Decode base64 screenshot and save to file. Returns True on success."""
    stage_dir = output_path.parent / f".nodraw-screenshot-{uuid4().hex}"
    register_staging(stage_dir)
    try:
        # Handle data URL prefix if present
        if base64_data.startswith("data:"):
            base64_data = base64_data.split(",", 1)[1]

        image_data = base64.b64decode(base64_data)
        if not image_data:
            raise ValueError("Screenshot payload decoded to zero bytes")
        stage_dir.mkdir(mode=0o700)
        staged_path = stage_dir / f".{output_path.name}"
        await asyncio.to_thread(staged_path.write_bytes, image_data)
        move_file_no_clobber(staged_path, output_path)
        logger.info(f"Screenshot saved: {output_path}")
        return True
    except Exception as e:
        logger.error(f"Failed to decode/save screenshot: {e}")
        return False
    finally:
        await asyncio.to_thread(shutil.rmtree, stage_dir, True)


async def _save_screenshot_required(base64_data: str, output_path: Path) -> Path:
    """Save a screenshot and require a new regular, nonempty output artifact."""
    saved = await decode_and_save_screenshot(base64_data, output_path)
    if (
        saved is not True
        or output_path.is_symlink()
        or not output_path.is_file()
        or output_path.stat().st_size <= 0
    ):
        raise OSError(f"Screenshot was not durably saved at {output_path}")
    return output_path


def _require_attempt_file(path: Optional[Path], description: str) -> Path:
    if path is None:
        raise OSError(f"{description} did not return an output path")
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        raise OSError(f"{description} was not durably saved at {path}")
    return path


async def _retract_attempt_artifacts(
    paths: set[Path],
    output_dir: Optional[Path],
) -> tuple[Path, ...]:
    """Move only this attempt's explicit public paths out of watcher visibility."""
    if not paths or output_dir is None:
        return ()
    return await asyncio.to_thread(
        preserve_public_artifacts,
        tuple(paths),
        output_dir,
    )


async def _publish_downloaded_bytes(
    payload: bytes,
    desired_path: Path,
    *,
    output_dir: Path,
) -> Path:
    """Publish buffered response bytes without clobbering an archive artifact."""
    return await publish_bytes_no_clobber(
        payload,
        desired_path,
        output_dir=output_dir,
    )


async def _publish_staged_family(
    staged_paths: List[Path],
    output_dir: Path,
    *,
    family_stem: Optional[str] = None,
) -> List[Path]:
    """Publish a complete staged family and retract it if cancellation races."""
    worker = asyncio.create_task(asyncio.to_thread(
        publish_staged_files,
        staged_paths,
        output_dir,
        family_stem=family_stem,
    ))
    destinations = None
    try:
        destinations = await asyncio.shield(worker)
        return [destinations[path] for path in staged_paths]
    except asyncio.CancelledError:
        try:
            destinations = await asyncio.shield(worker)
        except BaseException:
            pass
        if destinations:
            rollback = asyncio.create_task(
                _retract_attempt_artifacts(set(destinations.values()), output_dir)
            )
            await asyncio.shield(rollback)
        raise


async def _run_thread_to_completion(function, *args, **kwargs):
    """Let a short filesystem/validation worker settle before propagating cancel."""
    worker = asyncio.create_task(asyncio.to_thread(function, *args, **kwargs))
    try:
        return await asyncio.shield(worker)
    except asyncio.CancelledError:
        try:
            await asyncio.shield(worker)
        except BaseException:
            pass
        raise


def _validated_image_dimensions(path: Path) -> tuple[int, int]:
    """Verify an image and return its dimensions without blocking the event loop."""
    from PIL import Image

    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        width, height = image.size
    if width <= 0 or height <= 0:
        raise OSError(f"Image has invalid dimensions at {path}")
    return width, height


def _validated_image_payload(payload: bytes) -> tuple[int, int]:
    """Validate buffered image bytes before any watcher-visible publication."""
    from io import BytesIO
    from PIL import Image

    if not payload:
        raise OSError("Downloaded image response was empty")
    with Image.open(BytesIO(payload)) as image:
        image.verify()
    with Image.open(BytesIO(payload)) as image:
        width, height = image.size
    if width <= 0 or height <= 0:
        raise OSError("Downloaded image has invalid dimensions")
    return width, height


def append_to_index(folder_path: Path, entry_data: Dict) -> None:
    """Append entry to index.md in the folder"""
    index_path = folder_path / "index.md"
    index_key = str(index_path.resolve())

    with _index_locks_guard:
        index_lock = _index_locks.get(index_key)
        if index_lock is None:
            index_lock = threading.Lock()
            _index_locks[index_key] = index_lock

    date_str = entry_data.get("date", datetime.now().strftime("%Y-%m-%d"))
    time_str = entry_data.get("time", datetime.now().strftime("%H:%M"))
    platform = entry_data.get("platform", "Web")
    url = entry_data.get("url", "")
    title = entry_data.get("title", "Untitled")
    filename = entry_data.get("filename", "")

    # Build entry line
    entry_line = f"- **{time_str}** [{platform}]({url}) - {title}\n"
    if filename:
        entry_line += f"  - `{filename}`\n"

    with index_lock:
        # Read existing content or start fresh
        existing_content = ""
        if index_path.exists():
            existing_content = index_path.read_text(encoding="utf-8")

        date_header = f"## {date_str}\n\n"

        # Check if date header exists
        if date_header.strip() in existing_content:
            # Find position after the date header and insert entry
            header_pos = existing_content.find(date_header.strip())
            insert_pos = header_pos + len(date_header)
            new_content = (
                existing_content[:insert_pos] +
                entry_line +
                existing_content[insert_pos:]
            )
        else:
            # Add new date header at the top (after any existing content)
            if existing_content:
                new_content = date_header + entry_line + "\n" + existing_content
            else:
                new_content = date_header + entry_line

        # Write in-place to preserve macOS "Date Added" metadata.
        # Atomic rename (tmp → target) creates a new inode, resetting kMDItemDateAdded.
        index_path.write_text(new_content, encoding="utf-8")
        logger.info(f"Updated index: {index_path}")


async def download_twitter_images(
    image_urls: List[str],
    output_dir: Path,
    basename: str,
    cookies: Dict[str, str]
) -> List[Path]:
    """
    Download Twitter images directly via HTTP.
    Returns list of downloaded file paths.
    """
    import httpx

    stage_dir = output_dir / f".nodraw-twitter-images-{uuid4().hex}"
    register_staging(stage_dir)
    stage_dir.mkdir(mode=0o700)
    staged: List[Path] = []
    try:
        async with httpx.AsyncClient(
            follow_redirects=True,
            timeout=30.0,
            cookies=cookies,
        ) as client:
            for i, img_url in enumerate(image_urls, 1):
                if i > 1:
                    await asyncio.sleep(TWITTER_IMAGE_DELAY)
                response = await client.get(img_url, headers={
                    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                    'Referer': 'https://x.com/'
                })
                response.raise_for_status()

                content_type = response.headers.get('content-type', '')
                if 'jpeg' in content_type or 'jpg' in content_type:
                    ext = '.jpg'
                elif 'png' in content_type:
                    ext = '.png'
                elif 'gif' in content_type:
                    ext = '.gif'
                elif 'webp' in content_type:
                    ext = '.webp'
                else:
                    ext = '.jpg'

                filename = (
                    f"{basename}-{i}{ext}"
                    if len(image_urls) > 1
                    else f"{basename}{ext}"
                )
                payload = response.content
                if not payload:
                    raise OSError(f"Twitter image {i} returned an empty response")
                staged_path = stage_dir / f".{filename}"
                await _run_thread_to_completion(staged_path.write_bytes, payload)
                await _run_thread_to_completion(
                    _validated_image_dimensions,
                    staged_path,
                )
                staged.append(staged_path)

        if len(staged) != len(image_urls):
            raise OSError(
                f"Twitter image family incomplete: {len(staged)}/{len(image_urls)}"
            )
        published = await _publish_staged_family(
            staged,
            output_dir,
            family_stem=basename,
        )
        logger.info("Downloaded complete Twitter image family: %d files", len(published))
        return published
    finally:
        await asyncio.to_thread(shutil.rmtree, stage_dir, True)


def _alt_text_lines(image_alts: List[str]) -> List[str]:
    """The sidecar body's alt-text section."""
    if not image_alts:
        return []
    return ["## Alt Text", "", *(f"**Image {i}:** {alt}" for i, alt in enumerate(image_alts, 1) if alt), ""]


def _user_fields(options: Optional[Dict], *, extra_tags=(), extra_notes: str = "") -> Dict:
    """The capture identity, tags and note shared by every download sidecar."""
    options = options or {}
    tags = list(dict.fromkeys(tag for tag in [*extra_tags, *(options.get('user_tags') or [])] if tag))
    notes = '\n\n'.join(filter(None, [options.get('user_note') or '', extra_notes]))
    capture_id = (options.get("capture_intent") or {}).get("captureId")
    return {"capture_id": capture_id, "tags": tags, "notes": notes}


def _twitter_author(tweet_content: Dict, url: str, options: Optional[Dict] = None) -> str:
    """Keep the captured author, falling back to the status URL's handle."""
    options = options or {}
    page = (options.get("capture_intent") or {}).get("page") or {}
    for value in (tweet_content.get("userName"), options.get("author"), page.get("author")):
        if isinstance(value, str) and value.strip():
            return value.strip().split('\n')[0].strip()
    if url_hostname(url) in {"x.com", "twitter.com"}:
        match = re.match(r"^/([A-Za-z0-9_]{1,15})/status/\d+(?:/|$)", url_path(url))
        if match and match.group(1).lower() != "i":
            return match.group(1)
    return ""


async def create_twitter_sidecar_from_content(
    output_dir: Path,
    files: List[Path],
    tweet_content: Dict,
    url: str,
    basename: str,
    options: Optional[Dict] = None,
) -> Path:
    """
    Create .md sidecar for Twitter from extension-provided content.
    """
    if not files:
        return None

    # Extract tweet info from tweetContent
    username = _twitter_author(tweet_content, url, options)
    tweet_text = tweet_content.get('text', '')
    timestamp = tweet_content.get('timestamp', '')
    emotion = tweet_content.get('emotion')  # Emotion tag from wheel
    image_alts = tweet_content.get('imageAlts', [])  # Alt text from images

    md_path = output_dir / f"{basename}.md"
    now = datetime.now()
    fields = {
        "source": url,
        "platform": "twitter",
        # Clean username (may have newlines from X's layout)
        "author": username.split('\n')[0].strip(),
        "tweet_date": DateText(timestamp) if timestamp else None,
        "archived": now,
        "download_date": now,
        "media_count": len(files),
        **_user_fields(options, extra_tags=[emotion], extra_notes=twitter_quote_chain(tweet_content.get('quotes') or [])),
    }
    lines = [""]
    if tweet_text:
        lines.extend([tweet_text, ""])
    lines.extend(_alt_text_lines(image_alts))
    lines.extend(f"![[{f.name}]]" for f in files)
    lines.append("")
    lines.extend(twitter_quote_lines(tweet_content, lines))

    published_path = await _publish_downloaded_bytes(
        render_sidecar(fields, lines),
        md_path,
        output_dir=output_dir,
    )
    logger.info(
        "Created Twitter sidecar: %s (%d media files)",
        published_path.name,
        len(files),
    )
    return published_path


async def create_bluesky_sidecar(
    output_dir: Path,
    files: List[Path],
    post_content: Dict,
    url: str,
    basename: str,
    options: Optional[Dict] = None,
) -> Path:
    """
    Create .md sidecar for Bluesky from extension-provided content.
    """
    if not files:
        return None

    # Extract post info from postContent
    handle = post_content.get('handle', '')
    post_text = post_content.get('text', '')
    timestamp = post_content.get('timestamp', '')
    image_alts = post_content.get('imageAlts', [])  # Alt text from images

    md_path = output_dir / f"{basename}.md"
    now = datetime.now()
    fields = {
        "source": url,
        "platform": "bluesky",
        "author": handle,
        "post_date": DateText(timestamp) if timestamp else None,
        "archived": now,
        "download_date": now,
        "media_count": len(files),
        **_user_fields(options),
    }
    lines = [""]
    if post_text:
        lines.extend([post_text, ""])
    lines.extend(_alt_text_lines(image_alts))
    lines.extend(f"![[{f.name}]]" for f in files)
    lines.append("")

    published_path = await _publish_downloaded_bytes(
        render_sidecar(fields, lines),
        md_path,
        output_dir=output_dir,
    )
    logger.info(
        "Created Bluesky sidecar: %s (%d media files)",
        published_path.name,
        len(files),
    )
    return published_path


async def create_twitter_sidecar(
    output_dir: Path,
    files: List[str],
    tweet_content: Dict,
    url: str,
    emotion_tag: Optional[str] = None,
    options: Optional[Dict] = None,
):
    """
    Create a single .md sidecar for a Twitter download (gallery-dl path).
    One .md per tweet, referencing all media files.
    Uses tweet_content from extension instead of gallery-dl metadata.
    """
    if not files:
        return

    # Extract tweet info from extension-provided content
    username = _twitter_author(tweet_content, url, options)
    tweet_text = tweet_content.get('text', '')
    tweet_date = tweet_content.get('timestamp', '')
    image_alts = tweet_content.get('imageAlts', [])  # Alt text from images

    # Extract tweet_id from URL
    tweet_id = ''
    import re
    match = re.search(r'/status/(\d+)', url_path(url))
    if match:
        tweet_id = match.group(1)

    # Format tweet date if it's a timestamp
    if isinstance(tweet_date, (int, float)):
        from datetime import datetime as dt
        tweet_date = dt.fromtimestamp(tweet_date).astimezone().isoformat()

    # Generate sidecar filename.
    # Gallery-dl files are like: 2025-11-26-twitter-user-tweetid-1.jpg
    # yt-dlp Twitter files are like: 2025-11-26-twitter-user-tweetid.mp4
    first_file = Path(files[0])
    stem = first_file.stem
    md_stem = stem
    if tweet_id:
        image_suffix_pattern = rf'-{re.escape(tweet_id)}-\d+$'
        if re.search(image_suffix_pattern, stem):
            md_stem = re.sub(r'-\d+$', '', stem)
    md_path = output_dir / f"{md_stem}.md"
    now = datetime.now()
    fields = {
        "source": url,
        "platform": "twitter",
        "author": username,
        "tweet_id": int(tweet_id) if tweet_id else None,
        "tweet_date": DateText(tweet_date) if tweet_date else None,
        "archived": now,
        "download_date": now,
        **_user_fields(options, extra_tags=[emotion_tag], extra_notes=twitter_quote_chain(tweet_content.get('quotes') or [])),
    }
    lines = [""]
    if tweet_text:
        lines.extend([tweet_text, ""])
    lines.extend(_alt_text_lines(image_alts))
    lines.extend(f"![[{Path(f).name}]]" for f in files)
    lines.append("")
    lines.extend(twitter_quote_lines(tweet_content, lines))

    published_path = await _publish_downloaded_bytes(
        render_sidecar(fields, lines),
        md_path,
        output_dir=output_dir,
    )
    logger.info(
        "Created Twitter sidecar: %s (%d media files)",
        published_path.name,
        len(files),
    )
    return published_path


async def create_twitter_metadata_fallback_sidecar(
    output_dir: Path,
    basename: str,
    tweet_content: Dict,
    url: str,
    save_mode: str,
    title: Optional[str] = None,
    fallback_reason: str = "no_media_found",
    options: Optional[Dict] = None,
) -> Path:
    """Create a sidecar for a post whose saved media belongs to quoted posts."""
    username = _twitter_author(tweet_content, url, options)
    tweet_text = tweet_content.get('text', '')
    tweet_date = tweet_content.get('timestamp', '')
    image_alts = tweet_content.get('imageAlts', [])
    media_count = tweet_content.get('mediaCount')
    quoted_files = tweet_content.get('quotedFiles') or []
    if not quoted_files:
        raise ValueError("No media or screenshot was saved. Keep the post visible and retry with Full or Text mode.")
    for path in quoted_files:
        _require_attempt_file(Path(path), "Quoted media")
    if quoted_files:
        # The post has no media of its own, but the media it quotes was saved and is embedded below.
        fallback_reason = "quoted_media_only"
        media_count = len(quoted_files)

    tweet_id = ''
    import re
    match = re.search(r'/status/(\d+)', url_path(url))
    if match:
        tweet_id = match.group(1)

    md_path = output_dir / f"{basename}.md"
    now = datetime.now()
    fields = {
        "source": url,
        "platform": "twitter",
        "author": username,
        "title": None if username else title,
        "tweet_id": int(tweet_id) if tweet_id else None,
        "tweet_date": DateText(tweet_date) if tweet_date else None,
        "archived": now,
        "download_date": now,
        "save_mode": save_mode,
        "fallback": True,
        "fallback_reason": fallback_reason,
        "media_count": media_count,
        **_user_fields(options, extra_notes=twitter_quote_chain(tweet_content.get('quotes') or [])),
    }
    lines = [""]
    if tweet_text:
        lines.extend([tweet_text, ""])
    lines.extend(_alt_text_lines(image_alts))
    lines.extend(twitter_quote_lines(tweet_content, lines))

    published_path = await _publish_downloaded_bytes(
        render_sidecar(fields, lines),
        md_path,
        output_dir=output_dir,
    )
    logger.info(
        "Created Twitter metadata fallback sidecar: %s",
        published_path.name,
    )
    return published_path


async def cleanup_conflicting_media_sidecars(media_files: List[Path], canonical_md_path: Path) -> None:
    """Remove per-file orphan sidecars when a canonical tweet sidecar exists.

    The library should index a single tweet-level `.md`, not an additional
    per-file `-1.md`/`-2.md` sidecar pointing at the same media.
    """
    canonical_md_path = canonical_md_path.resolve()

    for media_file in media_files:
        candidate_md = media_file.with_suffix('.md')
        if candidate_md.resolve() == canonical_md_path:
            continue
        if not candidate_md.exists():
            continue

        try:
            content = await asyncio.to_thread(candidate_md.read_text, encoding='utf-8')
        except Exception as e:
            logger.warning(f"Failed reading potential orphan sidecar {candidate_md.name}: {e}")
            continue

        if not _is_conflicting_media_sidecar(content, media_file):
            continue

        try:
            await asyncio.to_thread(candidate_md.unlink)
            logger.info(f"Removed conflicting sidecar: {candidate_md.name}")
        except Exception as e:
            logger.warning(f"Failed removing conflicting sidecar {candidate_md.name}: {e}")


def _is_conflicting_media_sidecar(content: str, media_file: Path) -> bool:
    """Identify generic per-file sidecars that should not coexist with tweet-level metadata."""
    stem = media_file.stem.replace('"', '\\"')

    markers = [
        'source: "about:newtab"',
        'platform: unknown',
        f'title: "{stem}"',
        f'![[{media_file.name}]]',
    ]
    return all(marker in content for marker in markers)


@app.on_event("startup")
async def startup():
    """Initialize server components"""
    start_media_runtime()
    await db.initialize()
    storage.ensure_directories()
    await reconcile_startup(db)
    await get_capture_service().reconcile_projections()
    write_port_file(SERVICE_NAME, PORT, version="1.0.0")
    register_cleanup(SERVICE_NAME)
    logger.info(f"nodraw server started on port {PORT} (service: {SERVICE_NAME})")

@app.on_event("shutdown")
async def shutdown():
    """Cleanup on server shutdown"""
    await asyncio.to_thread(shutdown_media_runtime)
    remove_port_file(SERVICE_NAME)
    await db.close()
    logger.info("nodraw server stopped")

def _extension_status_payload(now: Optional[float] = None) -> Dict:
    now_ts = now if now is not None else time.time()
    with _metrics_lock:
        ext = dict(server_metrics['extension'])

    last_seen = ext.get('last_seen')
    seen_ever = bool(ext.get('seen_ever'))
    if last_seen is not None:
        seconds_ago = max(0.0, now_ts - float(last_seen))
        last_seen_at = datetime.utcfromtimestamp(float(last_seen)).isoformat() + "Z"
    else:
        seconds_ago = None
        last_seen_at = None

    active = bool(seconds_ago is not None and seconds_ago <= EXTENSION_ACTIVE_WINDOW_SECONDS)
    return {
        "seen_ever": seen_ever,
        "active": active,
        "last_seen_at": last_seen_at,
        "last_seen_seconds_ago": round(seconds_ago, 2) if seconds_ago is not None else None,
        "extension_id": ext.get('extension_id'),
        "extension_version": ext.get('extension_version'),
        "browser": ext.get('browser'),
        "last_trigger": ext.get('last_trigger'),
        "last_user_agent": ext.get('last_user_agent'),
        "active_window_seconds": EXTENSION_ACTIVE_WINDOW_SECONDS
    }

@app.post("/extension/heartbeat")
async def extension_heartbeat(payload: ExtensionHeartbeatRequest, request: Request):
    now_ts = time.time()
    with _metrics_lock:
        ext = server_metrics['extension']
        ext['seen_ever'] = True
        ext['last_seen'] = now_ts
        ext['extension_id'] = payload.extension_id
        ext['extension_version'] = payload.extension_version
        ext['browser'] = payload.browser
        ext['last_trigger'] = payload.trigger
        ext['last_user_agent'] = request.headers.get("user-agent")

    return {
        "success": True,
        "received_at": datetime.utcfromtimestamp(now_ts).isoformat() + "Z"
    }

@app.get("/health")
async def health_check():
    """Health check endpoint for extension with resource usage"""
    import os

    response = {
        "status": "healthy",
        "service": SERVICE_NAME,
        "server": "nodraw v1.0",
        "port": PORT,
        "downloaders": downloader.list_handlers(),
        "uptime_seconds": time.time() - server_metrics['start_time'],
        "extension": _extension_status_payload()
    }

    # Try to get memory usage (psutil optional)
    try:
        import psutil
        process = psutil.Process(os.getpid())
        response["memory_mb"] = round(process.memory_info().rss / 1024 / 1024, 2)
        response["cpu_percent"] = process.cpu_percent()
    except ImportError:
        # psutil not installed, skip memory metrics
        pass

    return response


@app.get("/metrics")
async def get_metrics():
    """Get server performance metrics"""
    with _metrics_lock:
        uptime = time.time() - server_metrics['start_time']

        # Calculate average response times per endpoint
        avg_response_times = {}
        for endpoint, data in server_metrics['requests'].items():
            if data['count'] > 0:
                avg_response_times[endpoint] = round(data['total_ms'] / data['count'], 2)

        # Convert defaultdicts to regular dicts for JSON serialization
        requests_data = {k: dict(v) for k, v in server_metrics['requests'].items()}
        downloads_data = {
            'total': server_metrics['downloads']['total'],
            'success': server_metrics['downloads']['success'],
            'failed': server_metrics['downloads']['failed'],
            'total_bytes': server_metrics['downloads']['total_bytes'],
            'by_platform': {k: dict(v) for k, v in server_metrics['downloads']['by_platform'].items()},
            'error_types': dict(server_metrics['downloads']['error_types'])
        }

        return {
            'uptime_seconds': round(uptime, 2),
            'requests': requests_data,
            'downloads': downloads_data,
            'avg_response_times_ms': avg_response_times,
            'success_rate': round(
                (downloads_data['success'] / downloads_data['total'] * 100) if downloads_data['total'] > 0 else 100, 2
            )
        }

def twitter_quote_chain(quotes: List[Dict]) -> str:
    """Render recorded quotes in depth order, whether or not media was saved."""
    if not quotes:
        return ""
    labels = [quote.get('handle') or quote.get('author') or 'Quoted post' for quote in quotes]
    lines = [f"Quotes {' → '.join(labels)}", ""]
    for quote, label in zip(quotes, labels):
        quote_url = quote.get('url', '')
        handle = str(quote.get('handle') or '').lstrip('@')
        # X opens video quotes from a click handler, so the page has no status link;
        # the author's profile is the most precise link the capture can keep.
        if not quote_url and handle.isascii() and handle.replace('_', '').isalnum() and len(handle) <= 15:
            quote_url = f"https://x.com/{handle}"
        line = f"[{label}]({quote_url})" if quote_url else label
        posted = str(quote.get('postedAt') or '')[:10]
        lines.extend([f"{line} · {posted}" if posted else line, ""])
        if quote.get('text'):
            lines.extend([quote['text'], ""])
    return '\n'.join(lines).rstrip()


def twitter_quote_lines(tweet_content: Dict, existing: List[str]) -> List[str]:
    """Add the chain and quoted media before a sidecar is atomically published."""
    chain = twitter_quote_chain(tweet_content.get('quotes') or [])
    lines = [chain, ''] if chain else []
    lines.extend(
        f'![[{Path(path).name}]]' for path in tweet_content.get('quotedFiles') or []
        if f'![[{Path(path).name}]]' not in existing
    )
    return lines


def twitter_gif_urls(tweet_content: Dict, options: Dict) -> List[str]:
    """Use the MP4s behind X's looping videos, never their page-local blob URLs."""
    media = ((options.get('capture_intent') or {}).get('media') or {})
    candidates = [tweet_content.get('gifUrl', '')]
    if media.get('type') == 'gif':
        candidates.append(media.get('url', ''))
    candidates.extend(
        entry.get('url', '') for entry in tweet_content.get('media', [])
        if isinstance(entry, dict) and entry.get('kind') == 'gif'
    )
    return list(dict.fromkeys(
        candidate for candidate in candidates
        if (parsed := urlparse(candidate or '')).scheme == 'https' and parsed.hostname == 'video.twimg.com'
        and parsed.path.startswith('/tweet_video/') and parsed.path.endswith('.mp4')
    ))


def twitter_post_stem(url: str) -> str:
    """`user-id` of an X post URL: the name the post's media files carry."""
    match = re.match(r'^/([A-Za-z0-9_]{1,15})/status/(\d+)', urlparse(url).path)
    return f"{match.group(1)}-{match.group(2)}" if match else ''


async def download_twitter_gifs(
    handler, gif_urls: List[str], post_url: str, cookies: Dict, output_dir: Path, options: Dict,
) -> DownloadResult:
    """X serves each GIF of a post as its own MP4; keep them all under the post's name."""
    post = twitter_post_stem(post_url)
    stem = f"twitter-{post}" if post else ''
    first, files, published = None, [], []
    for index, gif_url in enumerate(gif_urls, 1):
        name = f"{stem}-{index}" if stem and len(gif_urls) > 1 else stem
        result = await handler.download(
            url=gif_url, cookies=cookies, output_dir=output_dir,
            options={**options, **({'filenameStem': name} if name else {})},
        )
        published.extend(result.published_paths)
        if not result.success or not result.file_path:
            return DownloadResult(None, {}, success=False, error=result.error,
                                  failure_kind=result.failure_kind, published_paths=tuple(published))
        first = first or result
        files.extend(result.metadata.get('files') or [str(result.file_path)])
    # A bare MP4's extracted title is its media id; the post keeps its own title.
    metadata = {key: value for key, value in first.metadata.items() if key != 'title'}
    return DownloadResult(first.file_path, {**metadata, 'files': files}, published_paths=tuple(published))


async def download_twitter_quoted_media(
    quotes: List[Dict], output_dir: Path, basename: str, cookies: Dict,
    options: Dict, attempt_artifacts: set[Path], post_url: str = '',
) -> List[Path]:
    """Fetch each recorded level explicitly; extractors need not recurse quotes."""
    files: List[Path] = []

    async def extract(target: str, extra: Dict) -> None:
        handler = next((h for h in downloader.handlers if h.name == 'yt-dlp'), None) or downloader.get_handler(target)
        if not handler:
            raise ValueError(f'No handler available for quoted media: {target}')
        result = await handler.download(
            url=target, cookies=cookies, output_dir=output_dir,
            options={
                'save_mode': options.get('save_mode', 'full'),
                '_cookie_records': options.get('_cookie_records', []),
                'twitterQuoted': False,
                **extra,
            },
        )
        attempt_artifacts.update(Path(path) for path in result.published_paths)
        if not result.success or not result.file_path:
            raise RuntimeError(result.error or 'Quoted media download returned no file')
        paths = [Path(path) for path in (result.metadata.get('files') or [result.file_path])]
        paths = [path if path.is_absolute() else output_dir / path for path in paths]
        attempt_artifacts.update(paths)
        files.extend(paths)

    unresolved = 0
    for index, quote in enumerate(quotes, 1):
        media = [entry for entry in quote.get('media', []) if isinstance(entry, dict)]
        images = list(dict.fromkeys(entry['url'] for entry in media if entry.get('kind') == 'image' and entry.get('url')))
        if images:
            paths = await download_twitter_images(
                image_urls=images, output_dir=output_dir,
                basename=f"{basename}-quote-{index}", cookies=cookies,
            )
            attempt_artifacts.update(paths)
            files.extend(paths)
        videos = [entry for entry in media if entry.get('kind') in ('video', 'gif')]
        # A blob video needs its own quoted status URL for extraction. GIFs have
        # a durable direct MP4, so do not require X's status extractor for them.
        targets = []
        for entry in videos:
            direct = entry.get('url') if urlparse(entry.get('url') or '').scheme in ('https', 'http') else ''
            if direct or quote.get('url'):
                targets.append(direct or quote.get('url'))
            else:
                unresolved += 1
        for target in dict.fromkeys(targets):
            await extract(target, {'tweetContent': {'media': videos}})
    if unresolved:
        # X plays a quoted video from a blob: URL and links the quote only through a
        # click handler. The outer post's extractor lists quoted videos after its own.
        if not post_url:
            raise ValueError('Quoted video has no downloadable URL')
        own = sum(1 for entry in (options.get('tweetContent') or {}).get('media') or []
                  if isinstance(entry, dict) and entry.get('kind') in ('video', 'gif'))
        await extract(post_url, {'twitterPlaylistItems': f'{own + 1}:{own + unresolved}'})
    return list(dict.fromkeys(files))


@track_capture(lambda: db, get_capture_service)
async def process_download(
    job_id: str,
    url: str,
    cookies: List[CaptureCookieData],
    options: Dict,
    screenshot: Optional[str] = None,
    save_mode: str = "full",
    page_title: Optional[str] = None,
    timestamp: Optional[datetime] = None
):
    """Background task to process media download"""
    download_start = time.time()
    platform = detect_platform(url)
    output_dir: Optional[Path] = None
    attempt_artifacts: set[Path] = set()
    job_committed = False
    options = dict(options or {})
    raw_quotes = options.get('quotes') or []
    quotes = sorted(
        (quote for quote in raw_quotes if isinstance(quote, dict) and quote.get('level') in (1, 2)),
        key=lambda quote: quote['level'],
    ) if isinstance(raw_quotes, list) else []
    quoted_files: List[Path] = []
    if platform == 'twitter':
        options['tweetContent'] = {**(options.get('tweetContent') or {}), 'quotes': quotes}
        options['tweetContent']['userName'] = _twitter_author(options['tweetContent'], url, options)

    async def complete_job(file_path: Path, metadata: Dict) -> None:
        """Settle the durable commit even if caller cancellation races it."""
        nonlocal job_committed
        _require_attempt_file(Path(file_path), "Saved media or screenshot")
        if Path(file_path).suffix.lower() == '.md':
            raise ValueError("No media or screenshot was saved. Keep the post visible and retry with Full or Text mode.")
        if platform == 'twitter':
            metadata['original_url'] = url
            if not metadata.get('author'):
                metadata['author'] = options['tweetContent']['userName']
        if platform == 'twitter' and (quotes or quoted_files):
            chain = twitter_quote_chain(quotes)
            metadata['quotes'] = quotes
            metadata['notes'] = '\n\n'.join(filter(None, [metadata.get('notes') or options.get('user_note'), chain]))
            existing_files = metadata.get('files') or ([str(file_path)] if file_path.suffix != '.md' and not file_path.name.endswith('.context.png') else [])
            metadata['files'] = list(dict.fromkeys([*map(str, existing_files), *map(str, quoted_files)]))
            metadata['media_count'] = len(metadata['files'])
        completion = asyncio.create_task(
            db.update_job_complete(
                job_id=job_id,
                file_path=str(file_path),
                metadata=metadata,
            )
        )
        try:
            await asyncio.shield(completion)
        except asyncio.CancelledError:
            # SQLite may already have committed. Resolve the task before deciding
            # whether public artifacts should be retracted or the job stays complete.
            await asyncio.shield(completion)
            job_committed = True
            raise
        job_committed = True

    # Track download start
    with _metrics_lock:
        server_metrics['downloads']['total'] += 1
        server_metrics['downloads']['by_platform'][platform]['count'] += 1

    try:
        logger.info(f"Processing download {job_id}: {url} (mode: {save_mode})")

        # Update job status
        await db.update_job_status(job_id, "downloading")

        # Create output directory
        output_dir = storage.get_dated_path()
        output_dir.mkdir(parents=True, exist_ok=True)

        # Generate base filename: YYYY-MM-DD-platform-slug
        # Note: platform already detected at start of function for metrics
        title = page_title or "Untitled"
        now = timestamp or datetime.now()
        if now.tzinfo:
            # The extension stamps intents in UTC; the archive files and indexes by local day.
            now = now.astimezone().replace(tzinfo=None)
        # An X post captured from a feed would otherwise be named after the feed's tab.
        basename = storage.generate_base_name(
            platform, title, stem=twitter_post_stem(url) if platform == 'twitter' else None,
        )

        final_path = None
        media_filename = None

        # Check if this is YouTube (should use handler for text mode to get video+subtitles)
        is_youtube = matches_domains(url, YOUTUBE_DOMAINS)

        # Handle based on save_mode
        if save_mode == "text" and not is_youtube:
            # Text mode: screenshot + metadata only, no media download (EXCEPT YouTube which downloads video+subtitles)
            if not screenshot:
                raise ValueError("No screenshot was captured. Keep the post visible and retry with Full or Text mode.")
            if screenshot:
                screenshot_path = output_dir / f"{basename}.context.png"
                await _save_screenshot_required(screenshot, screenshot_path)
                attempt_artifacts.add(screenshot_path)

            # Save metadata as .md sidecar
            capture_intent = (options or {}).get("capture_intent") or {}
            selection = (options or {}).get("selection") or {}
            user_tags = (options or {}).get("user_tags") or []
            user_note = (options or {}).get("user_note") or ""
            author = options['tweetContent']['userName'] if platform == 'twitter' else (capture_intent.get('page') or {}).get('author', '')
            metadata = {
                "original_url": url,
                "download_date": now.isoformat(),
                "save_mode": save_mode,
                "title": title,
                "author": author,
                "platform": platform,
                "capture_id": capture_intent.get("captureId"),
                "capture_kind": capture_intent.get("kind"),
                "selection": selection,
                "tags": user_tags,
                "notes": user_note,
            }
            if platform == 'twitter' and quotes:
                user_note = '\n\n'.join(filter(None, [user_note, twitter_quote_chain(quotes)]))
            fields = {
                "source": url,
                "platform": platform,
                "title": title,
                "author": author,
                "archived": now,
                "download_date": now,
                "save_mode": save_mode,
                "capture_id": capture_intent.get("captureId"),
                "tags": user_tags,
                "notes": user_note,
            }
            md_lines = [""]
            if platform == 'twitter' and (options.get('tweetContent') or {}).get('text'):
                md_lines.extend([options['tweetContent']['text'], ""])
            if platform == 'reddit' and (options.get('redditContent') or {}).get('text'):
                md_lines.extend([options['redditContent']['text'], ""])
            if selection.get("text"):
                md_lines.extend(["## Selection", "", selection["text"], ""])
            if selection.get("html"):
                md_lines.extend(["```html", selection["html"], "```", ""])
            if screenshot:
                md_lines.append(f"![[{screenshot_path.name}]]")
            if platform == 'twitter':
                md_lines.extend(twitter_quote_lines(options['tweetContent'], md_lines))
            md_lines.append("")

            metadata_path = await _publish_downloaded_bytes(
                render_sidecar(fields, md_lines),
                output_dir / f"{basename}.md",
                output_dir=output_dir,
            )
            _require_attempt_file(metadata_path, "Text sidecar")
            attempt_artifacts.add(metadata_path)
            metadata["sidecar_path"] = str(metadata_path)

            final_path = screenshot_path if screenshot else metadata_path

            await complete_job(final_path, metadata)
            logger.info(f"Text-only save complete {job_id}: {final_path}")

        else:
            # Full or quick mode: download media
            # Convert cookies to dict format
            cookie_dict = {}
            for cookie in cookies:
                cookie_dict[cookie.name] = cookie.value
            cookie_records = [
                {
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain,
                    "path": cookie.path,
                }
                for cookie in cookies
            ]

            if platform == 'twitter' and options.get('twitterQuoted') and quotes:
                quoted_files = await download_twitter_quoted_media(
                    quotes, output_dir, basename, cookie_dict,
                    {**options, 'save_mode': save_mode, '_cookie_records': cookie_records},
                    attempt_artifacts, post_url=url,
                )
                options['tweetContent']['quotedFiles'] = [str(path) for path in quoted_files]

            # Check for Twitter with image URLs - use direct HTTP download
            tweet_content = options.get('tweetContent', {}) if options else {}
            image_urls = tweet_content.get('imageUrls', [])
            has_video = tweet_content.get('hasVideo', False) or tweet_content.get('hasGif', False)
            gif_urls = twitter_gif_urls(tweet_content, options) if platform == 'twitter' else []
            # A post that mixes GIFs with real videos goes through the post's extractor instead.
            own_videos = any(isinstance(entry, dict) and entry.get('kind') == 'video'
                             for entry in tweet_content.get('media') or [])
            if own_videos:
                gif_urls = []
            has_video = has_video or bool(gif_urls)

            if platform == 'twitter' and image_urls and not has_video:
                # Twitter image-only tweet: download images directly via HTTP
                logger.info(f"Twitter image tweet detected: {len(image_urls)} images")
                downloaded_files = await download_twitter_images(
                    image_urls=image_urls,
                    output_dir=output_dir,
                    basename=basename,
                    cookies=cookie_dict
                )

                if downloaded_files:
                    attempt_artifacts.update(Path(path) for path in downloaded_files)
                    final_path = downloaded_files[0]
                    media_filename = final_path.name

                    # Save screenshot for "full" mode
                    if save_mode == "full" and screenshot:
                        screenshot_path = output_dir / f"{basename}.context.png"
                        await _save_screenshot_required(screenshot, screenshot_path)
                        attempt_artifacts.add(screenshot_path)

                    # Create .md sidecar (always - metadata valuable)
                    twitter_sidecar = await create_twitter_sidecar_from_content(
                        output_dir=output_dir,
                        files=downloaded_files,
                        tweet_content=tweet_content,
                        url=url,
                        basename=basename,
                        options=options,
                    )
                    _require_attempt_file(twitter_sidecar, "Twitter sidecar")
                    attempt_artifacts.add(Path(twitter_sidecar))

                    # Build metadata
                    metadata = {
                        "original_url": url,
                        "download_date": now.isoformat(),
                        "downloader": "direct-http",
                        "save_mode": save_mode,
                        "title": title,
                        "platform": platform,
                        "media_count": len(downloaded_files),
                        "files": [str(f) for f in downloaded_files],
                        "sidecar_path": str(twitter_sidecar),
                    }

                    await complete_job(final_path, metadata)
                    logger.info(f"Twitter image download complete {job_id}: {len(downloaded_files)} files")
                else:
                    raise ValueError("Failed to download Twitter images")

            else:
                # Use yt-dlp/gallery-dl for video tweets or other platforms.
                # Twitter/X video and GIF downloads are more reliable through yt-dlp.
                preferred_handler = None
                if platform == 'twitter' and has_video:
                    preferred_handler = next(
                        (h for h in downloader.handlers if h.name == 'yt-dlp'),
                        None
                    )
                    if preferred_handler:
                        logger.info(f"Twitter video/GIF detected, preferring yt-dlp for {url}")

                handler = preferred_handler or downloader.get_handler(url)
                if not handler:
                    raise ValueError(f"No handler available for URL: {url}")

                # Execute download - include save_mode in options for handler
                handler_options = options.copy() if options else {}
                handler_options['save_mode'] = save_mode
                handler_options['_cookie_records'] = cookie_records
                if quotes:
                    handler_options['twitterQuoted'] = False
                own_media_absent = (
                    platform == 'twitter' and tweet_content.get('media') == []
                    and not has_video and not tweet_content.get('hasImage')
                )
                if own_media_absent:
                    result = DownloadResult(None, {}, success=False, failure_kind=DownloadFailureKind.NO_MEDIA)
                elif gif_urls:
                    result = await download_twitter_gifs(
                        handler, gif_urls, url, cookie_dict, output_dir, handler_options,
                    )
                else:
                    result = await handler.download(
                        url=url,
                        cookies=cookie_dict,
                        output_dir=output_dir,
                        options=handler_options
                    )
                attempt_artifacts.update(Path(path) for path in result.published_paths)

                fallback = (
                    downloader.get_fallback_handler(handler, url, result)
                    if result.failure_kind == DownloadFailureKind.UNSUPPORTED
                    else None
                )
                if fallback:
                    logger.info(f"gallery-dl rejected URL, trying yt-dlp for {url}")
                    handler = fallback
                    result = await handler.download(
                        url=url,
                        cookies=cookie_dict,
                        output_dir=output_dir,
                        options=handler_options,
                    )
                    attempt_artifacts.update(Path(path) for path in result.published_paths)

                # Only a downloader's explicit NO_MEDIA disposition may use the
                # screenshot/metadata fallback. Untyped legacy failures remain
                # terminal so validation/publication errors cannot become success.
                if result.is_terminal_failure:
                    raise RuntimeError(
                        result.error or f"{handler.name} reported an unsuccessful download"
                    )

                if result.success and result.file_path:
                    media_filename = Path(result.file_path).name

                    # Update title from metadata if available
                    if result.metadata.get('title'):
                        title = result.metadata['title']

                    # YouTube text mode keeps video, transcripts and context.
                    if screenshot and (save_mode == "full" or (is_youtube and save_mode == "text")):
                        # Use same basename as media file
                        media_stem = Path(result.file_path).stem
                        screenshot_path = output_dir / f"{media_stem}.context.png"
                        await _save_screenshot_required(screenshot, screenshot_path)
                        attempt_artifacts.add(screenshot_path)

                    # Build metadata
                    metadata = {
                        "original_url": url,
                        "download_date": now.isoformat(),
                        "downloader": handler.name,
                        "save_mode": save_mode,
                        "title": title,
                        "platform": platform,
                        **result.metadata
                    }
                    metadata_sidecar_path: Optional[Path] = None

                    # Save metadata (always - sidecar metadata is valuable)
                    # For Twitter, always use a single tweet-level .md sidecar.
                    if platform == 'twitter':
                        emotion_tag = options.get('emotionTag') if options else None
                        tweet_content = options.get('tweetContent', {}) if options else {}
                        twitter_files = result.metadata.get('files') or [str(result.file_path)]
                        twitter_sidecar = await create_twitter_sidecar(
                            output_dir=output_dir,
                            files=twitter_files,
                            tweet_content=tweet_content,
                            url=url,
                            emotion_tag=emotion_tag,
                            options=options,
                        )
                        _require_attempt_file(twitter_sidecar, "Twitter sidecar")
                        attempt_artifacts.add(Path(twitter_sidecar))
                        metadata_sidecar_path = Path(twitter_sidecar)
                    elif platform == 'bluesky':
                        # Bluesky: use .md sidecar with post content
                        post_content = options.get('postContent', {}) if options else {}
                        files_list = result.metadata.get('files', [])
                        if files_list:
                            bluesky_sidecar = await create_bluesky_sidecar(
                                output_dir=output_dir,
                                files=[Path(f) for f in files_list],
                                post_content=post_content,
                                url=url,
                                basename=Path(result.file_path).stem,
                                options=options,
                            )
                            _require_attempt_file(bluesky_sidecar, "Bluesky sidecar")
                            attempt_artifacts.add(Path(bluesky_sidecar))
                            metadata_sidecar_path = Path(bluesky_sidecar)
                    else:
                        # Other platforms: save JSON metadata
                        metadata_sidecar = await storage.save_metadata(result.file_path, metadata, user=_user_fields(options))
                        _require_attempt_file(metadata_sidecar, "Metadata sidecar")
                        attempt_artifacts.add(Path(metadata_sidecar))
                        metadata_sidecar_path = Path(metadata_sidecar)

                    if metadata_sidecar_path is not None:
                        metadata["sidecar_path"] = str(metadata_sidecar_path)

                    # File is already in the right place (yt-dlp writes to dated folder)
                    final_path = result.file_path

                    # Update job with success
                    await complete_job(final_path, metadata)

                    logger.info(f"Download complete {job_id}: {final_path}")
                else:
                    if not result.is_no_media:
                        raise RuntimeError(
                            result.error
                            or f"{handler.name} reported success without a media path"
                        )

                    # No media downloaded - try yt-dlp fallback for gallery-dl failures.
                    ytdlp_fallback_success = False
                    if handler.name == "gallery-dl" and platform in ('twitter', 'reddit', 'unknown') and not own_media_absent:
                        logger.info(f"gallery-dl returned no files, trying yt-dlp fallback for {platform}")
                        ytdlp_handler = next((h for h in downloader.handlers if h.name == 'yt-dlp'), None)
                        if not ytdlp_handler:
                            raise ValueError("yt-dlp handler not found for fallback")
                        ytdlp_result = await ytdlp_handler.download(
                            url, cookie_dict, output_dir,
                            options={
                                **handler_options,
                                'save_mode': save_mode,
                                '_cookie_records': cookie_records,
                            }
                        )
                        if ytdlp_result is not None:
                            attempt_artifacts.update(
                                Path(path) for path in ytdlp_result.published_paths
                            )
                        if ytdlp_result and ytdlp_result.success and ytdlp_result.file_path:
                            result = ytdlp_result
                            final_path = result.file_path
                            fallback_sidecar_path: Optional[Path] = None
                            if screenshot:
                                screenshot_path = output_dir / f"{Path(result.file_path).stem}.context.png"
                                await _save_screenshot_required(screenshot, screenshot_path)
                                attempt_artifacts.add(screenshot_path)

                            if platform == 'twitter':
                                emotion_tag = options.get('emotionTag') if options else None
                                tweet_content = options.get('tweetContent', {}) if options else {}
                                twitter_sidecar = await create_twitter_sidecar(
                                    output_dir=output_dir,
                                    files=[str(result.file_path)],
                                    tweet_content=tweet_content,
                                    url=url,
                                    emotion_tag=emotion_tag,
                                    options=options,
                                )
                                _require_attempt_file(twitter_sidecar, "Twitter sidecar")
                                attempt_artifacts.add(Path(twitter_sidecar))
                                fallback_sidecar_path = Path(twitter_sidecar)
                            else:
                                # Build rich .md sidecar with postContent if available
                                post_content = options.get('postContent', {}) if options else {}
                                post_text = post_content.get('text', '')
                                post_handle = post_content.get('handle', '')
                                image_alts = post_content.get('imageAlts', [])

                                md_path = output_dir / f"{Path(result.file_path).stem}.md"
                                fields = {
                                    "source": url,
                                    "platform": platform,
                                    "author": post_handle,
                                    "title": None if post_handle else title,
                                    "archived": now,
                                    "download_date": now,
                                    "save_mode": save_mode,
                                    "handler": "yt-dlp (fallback)",
                                    **_user_fields(options),
                                }
                                md_lines = [""]
                                if post_text:
                                    md_lines.extend([post_text, ""])
                                md_lines.extend(_alt_text_lines(image_alts))
                                md_lines.append(f"![[{Path(result.file_path).name}]]")
                                if screenshot:
                                    md_lines.append(f"![[{screenshot_path.name}]]")
                                md_lines.append("")

                                md_path = await _publish_downloaded_bytes(
                                    render_sidecar(fields, md_lines),
                                    md_path,
                                    output_dir=output_dir,
                                )
                                _require_attempt_file(md_path, "Fallback sidecar")
                                attempt_artifacts.add(md_path)
                                fallback_sidecar_path = md_path
                                logger.info(f"Created yt-dlp fallback sidecar: {md_path.name}")

                            fallback_metadata = {
                                "original_url": url,
                                "download_date": now.isoformat(),
                                "save_mode": save_mode,
                                "title": title,
                                "platform": platform,
                                "handler": "yt-dlp (fallback)",
                                **result.metadata
                            }
                            if fallback_sidecar_path is not None:
                                fallback_metadata["sidecar_path"] = str(
                                    fallback_sidecar_path
                                )
                            await complete_job(final_path, fallback_metadata)
                            logger.info(f"yt-dlp fallback success {job_id}: {final_path}")
                            ytdlp_fallback_success = True
                        else:
                            # A concrete handler failure is not equivalent to a
                            # successful extraction that simply found no media. Keep
                            # its exact message so /jobs and the extension can present
                            # the real terminal state.
                            if ytdlp_result is None:
                                raise RuntimeError("yt-dlp fallback returned no result")
                            if ytdlp_result and ytdlp_result.is_terminal_failure:
                                logger.warning("yt-dlp fallback reported failure")
                                raise RuntimeError(
                                    ytdlp_result.error
                                    or "yt-dlp fallback reported an unsuccessful download"
                                )
                            if ytdlp_result and not ytdlp_result.is_no_media:
                                raise RuntimeError(
                                    ytdlp_result.error
                                    or "yt-dlp fallback returned an invalid result"
                                )
                            logger.warning(
                                "yt-dlp fallback found no media; considering screenshot fallback"
                            )

                    if not ytdlp_fallback_success:
                        # Final fallback to screenshot+metadata
                        logger.warning(f"No media file from {handler.name}, falling back to screenshot")

                        if screenshot:
                            screenshot_path = output_dir / f"{basename}.context.png"
                            await _save_screenshot_required(screenshot, screenshot_path)
                            attempt_artifacts.add(screenshot_path)
                            final_path = screenshot_path

                            # Save metadata as .md sidecar
                            metadata = {
                                "original_url": url,
                                "download_date": now.isoformat(),
                                "save_mode": save_mode,
                                "title": title,
                                "platform": platform,
                                "fallback": True,
                                "reason": "no_media_found"
                            }

                            # For Bluesky fallback, include postContent if available
                            post_content = options.get('postContent', {}) if options else {}
                            post_text = post_content.get('text', '')
                            post_handle = post_content.get('handle', '')
                            if platform == 'twitter':
                                post_handle = options['tweetContent']['userName']
                            image_alts = post_content.get('imageAlts', [])

                            fields = {
                                "source": url,
                                "platform": platform,
                                "author": post_handle,
                                "title": None if post_handle else title,
                                "archived": now,
                                "download_date": now,
                                "save_mode": save_mode,
                                "fallback": True,
                                "fallback_reason": "no_media_found",
                                **_user_fields(options, extra_notes=twitter_quote_chain(quotes) if platform == 'twitter' else ''),
                            }
                            md_lines = [""]
                            if post_text:
                                md_lines.extend([post_text, ""])
                            md_lines.extend(_alt_text_lines(image_alts))
                            md_lines.append(f"![[{screenshot_path.name}]]")
                            md_lines.append("")

                            if platform == 'twitter':
                                tweet_content = options['tweetContent']
                                if tweet_content.get('text'):
                                    md_lines.extend([tweet_content['text'], ''])
                                md_lines.extend(twitter_quote_lines(tweet_content, md_lines))

                            metadata_path = await _publish_downloaded_bytes(
                                render_sidecar(fields, md_lines),
                                output_dir / f"{basename}.md",
                                output_dir=output_dir,
                            )
                            _require_attempt_file(metadata_path, "Fallback sidecar")
                            attempt_artifacts.add(metadata_path)
                            metadata["sidecar_path"] = str(metadata_path)

                            await complete_job(final_path, metadata)
                            logger.info(f"Fallback save complete {job_id}: {final_path}")
                        else:
                            metadata_only_path = None
                            if platform == 'twitter' and quoted_files:
                                tweet_content = options.get('tweetContent', {}) if options else {}
                                metadata_only_path = await create_twitter_metadata_fallback_sidecar(
                                    output_dir=output_dir,
                                    basename=basename,
                                    tweet_content=tweet_content,
                                    url=url,
                                    save_mode=save_mode,
                                    title=title,
                                    fallback_reason="no_media_found_no_screenshot",
                                    options=options,
                                )

                            if metadata_only_path:
                                _require_attempt_file(
                                    metadata_only_path,
                                    "Twitter metadata-only fallback",
                                )
                                attempt_artifacts.add(Path(metadata_only_path))
                                final_path = quoted_files[0] if quoted_files else metadata_only_path
                                metadata = {
                                    "original_url": url,
                                    "download_date": now.isoformat(),
                                    "save_mode": save_mode,
                                    "title": title,
                                    "platform": platform,
                                    "fallback": True,
                                    "reason": "quoted_media_only" if quoted_files else "no_media_found_no_screenshot",
                                    "fallback_type": "metadata_only",
                                    "sidecar_path": str(metadata_only_path),
                                }
                                await complete_job(final_path, metadata)
                                logger.info(f"Metadata-only fallback save complete {job_id}: {final_path}")
                            else:
                                raise ValueError("No media or screenshot was saved. Keep the post visible and retry with Full or Text mode.")

        # The database is the durable source of truth. index.md is a derived
        # convenience surface, so its I/O cannot turn a committed capture into
        # a failed job. Keep its read/write work off the event loop as well.
        try:
            await asyncio.to_thread(append_to_index, output_dir, {
                "date": now.strftime("%Y-%m-%d"),
                "time": now.strftime("%H:%M"),
                "platform": platform,
                "url": url,
                "title": title,
                "filename": media_filename or ""
            })
        except Exception as index_error:
            logger.error(
                "Capture %s is complete, but index.md update failed: %s",
                job_id,
                index_error,
            )

        # Track successful download
        download_duration_ms = (time.time() - download_start) * 1000
        with _metrics_lock:
            server_metrics['downloads']['success'] += 1
            server_metrics['downloads']['by_platform'][platform]['success'] += 1
            # Track file size if available
            if final_path:
                try:
                    file_size = Path(final_path).stat().st_size
                    server_metrics['downloads']['total_bytes'] += file_size
                except (OSError, TypeError):
                    pass
        logger.info(f"Download metrics: {platform} completed in {download_duration_ms:.1f}ms")

    except asyncio.CancelledError:
        error_msg = "Download cancelled"
        if job_committed:
            with _metrics_lock:
                server_metrics['downloads']['success'] += 1
                server_metrics['downloads']['by_platform'][platform]['success'] += 1
            logger.info(
                "Download %s was cancelled after its durable completion committed; "
                "leaving the completed job and exact artifacts intact",
                job_id,
            )
        else:
            try:
                rollback = asyncio.create_task(
                    _retract_attempt_artifacts(attempt_artifacts, output_dir)
                )
                await asyncio.shield(rollback)
            except BaseException as rollback_error:
                logger.critical(
                    "Download %s cancellation rollback failed for exact paths %s: %s",
                    job_id,
                    sorted(str(path) for path in attempt_artifacts),
                    rollback_error,
                )
            try:
                failure_update = asyncio.create_task(
                    db.update_job_failed(job_id, error_msg, "cancelled")
                )
                await asyncio.shield(failure_update)
            except BaseException as update_error:
                logger.error(
                    "Download %s was cancelled and its durable failure update did not "
                    "complete: %s",
                    job_id,
                    update_error,
                )
            with _metrics_lock:
                server_metrics['downloads']['failed'] += 1
                server_metrics['downloads']['by_platform'][platform]['failed'] += 1
                server_metrics['downloads']['error_types']['CancelledError'] += 1
            logger.warning("Download cancelled %s", job_id)
        raise
    except Exception as e:
        error_msg = str(e)
        error_category = _categorize_error(e, error_msg)
        if job_committed:
            logger.critical(
                "Post-commit download bookkeeping failed for %s; keeping durable "
                "completed state and artifacts: %s",
                job_id,
                error_msg,
            )
            return
        try:
            await _retract_attempt_artifacts(attempt_artifacts, output_dir)
        except Exception as rollback_error:
            logger.critical(
                "Download %s failed and exact-path rollback also failed: %s",
                job_id,
                rollback_error,
            )
            error_msg = f"{error_msg}; artifact rollback failed: {rollback_error}"
        logger.error(f"Download failed {job_id} [{error_category}]: {error_msg}")
        await db.update_job_failed(job_id, error_msg, error_category)

        # Track failed download
        error_type = type(e).__name__
        with _metrics_lock:
            server_metrics['downloads']['failed'] += 1
            server_metrics['downloads']['by_platform'][platform]['failed'] += 1
            server_metrics['downloads']['error_types'][error_type] += 1


def _categorize_error(exc: Exception, msg: str) -> str:
    """Categorize download errors for extension-side display"""
    lower = msg.lower()
    if '429' in lower or 'rate limit' in lower or 'too many' in lower:
        return 'rate_limited'
    if '404' in lower or 'not found' in lower:
        return 'not_found'
    private_access_markers = (
        'private video',
        'private content',
        'content is private',
        'account is private',
        'post is private',
        'media is private',
    )
    if (
        '403' in lower
        or 'forbidden' in lower
        or any(marker in lower for marker in private_access_markers)
    ):
        return 'access_denied'
    if 'timeout' in lower or 'timed out' in lower:
        return 'timeout'
    if 'no handler' in lower or 'unsupported' in lower:
        return 'unsupported'
    if 'no video' in lower or 'no media' in lower or 'no audio' in lower:
        return 'no_media'
    if 'disk' in lower or 'space' in lower or 'quota' in lower:
        return 'storage'
    return 'server_error'


async def _archive_image_impl(request: ImageArchiveRequest, *, capture_id: Optional[str] = None):
    """
    Archive a single image with .md sidecar (Obsidian-native)

    Always creates .md sidecar with YAML frontmatter (metadata/alt text valuable).
    For tiled/zoomable images (Google Arts & Culture, IIIF, etc.), uses dezoomify-rs.
    """
    import httpx

    output_dir: Optional[Path] = None
    attempt_artifacts: set[Path] = set()

    try:
        logger.info(f"Archiving image: {request.image_url} (mode: {request.save_mode})")

        # Create output directory
        output_dir = storage.get_dated_path()

        # Generate filename from metadata
        platform = request.metadata.platform or "web"
        title = request.metadata.title or "untitled"
        author = request.metadata.author or ""
        asset_id = request.metadata.assetId or ""

        # Build title string for filename
        title_str = title
        if author:
            title_str = f"{author}-{title}"

        # For Google Arts: append asset ID for uniqueness
        if platform == "googlearts" and asset_id:
            title_str = f"{title_str}-{asset_id}"

        basename = storage.generate_base_name(platform, title_str)

        # Check if a specialized handler should handle this URL
        handler = downloader.get_handler(request.image_url)
        options = dict(request.options or {})
        options['_cookie_records'] = [
            {
                'name': cookie.name,
                'value': cookie.value,
                'domain': cookie.domain,
                'path': cookie.path,
            }
            for cookie in request.cookies
        ]

        # Use dezoomify-rs for tiled/zoomable images (Google Arts & Culture, etc.)
        if handler and handler.name == "dezoomify-rs":
            max_width = options.get('max_width')
            logger.info(f"Using dezoomify-rs for tiled image: {request.image_url} (max_width={max_width})")
            result = await handler.download(
                url=request.image_url,
                cookies={},
                output_dir=output_dir,
                options=options
            )
            attempt_artifacts.update(Path(path) for path in result.published_paths)

            if result.success and result.file_path:
                image_path = Path(result.file_path)
                # Check if image was marked as small
                if result.metadata.get('is_small'):
                    basename = basename + "-small"
                    logger.info(f"Marking as small: {result.metadata.get('resolution', 'unknown')}")
                # Rename to match our naming convention
                ext = image_path.suffix or '.jpg'
                new_path = output_dir / f"{basename}{ext}"
                if image_path != new_path:
                    relocated = relocate_public_file(
                        image_path,
                        new_path,
                        root=output_dir,
                    )
                    attempt_artifacts.discard(image_path)
                    attempt_artifacts.add(relocated)
                    image_path = relocated
                logger.info(f"dezoomify-rs saved: {image_path.name}")
            else:
                raise ValueError(f"dezoomify-rs failed: {result.error}")

        # Use gallery-dl for Flickr photo pages (to get original/full resolution)
        # Falls back to direct CDN download if gallery-dl fails (e.g. API key expired)
        elif (
            handler and handler.name == "gallery-dl"
            and matches_domains(request.page_url or request.image_url, ('flickr.com',))
            and url_path(request.page_url or request.image_url).startswith('/photos/')
        ):
            # Build cookies dict
            cookies_dict = {c.name: c.value for c in request.cookies}
            max_width = options.get('max_width')
            logger.info(f"Using gallery-dl for Flickr: {request.image_url} (max_width={max_width})")

            # Use page_url if available (better for gallery-dl to parse)
            download_url = request.page_url or request.image_url

            result = await handler.download(
                url=download_url,
                cookies=cookies_dict,
                output_dir=output_dir,
                options=options
            )
            attempt_artifacts.update(Path(path) for path in result.published_paths)

            if result.success and result.file_path:
                image_path = Path(result.file_path)
                # Rename to match our naming convention
                ext = image_path.suffix or '.jpg'
                new_path = output_dir / f"{basename}{ext}"
                if image_path != new_path and image_path.exists():
                    relocated = relocate_public_file(
                        image_path,
                        new_path,
                        root=output_dir,
                    )
                    attempt_artifacts.discard(image_path)
                    attempt_artifacts.add(relocated)
                    image_path = relocated
                logger.info(f"gallery-dl saved: {image_path.name}")
            else:
                # Fallback: try higher resolution variants via URL manipulation
                logger.warning(f"gallery-dl failed, trying URL size variants: {result.error}")

                # Flickr URL pattern: {id}_{secret}_{size}.{ext} OR {id}_{secret}.{ext} (no size suffix in some galleries)
                # Sizes: s=75, q=150, t=100, m=240, n=320, w=400, z=640, c=800, b=1024, h=1600, k=2048, o=original
                import re
                base_url = request.image_url
                size_pattern = r'_([a-z])(\.[a-zA-Z]+)$'

                # Build list of URLs to try
                # _o=original (requires owner permission, often 404s), _k=2048, _h=1600, _b=1024
                urls_to_try = []
                match = re.search(size_pattern, base_url)
                if match:
                    # Has size suffix - try different sizes
                    ext_part = match.group(2)
                    base_without_size = re.sub(size_pattern, '', base_url)
                    if max_width is None:
                        # Alt+Click: user wants original, try _o first
                        sizes = ['_o', '_k', '_h', '_b']
                        logger.info("Flickr fallback: trying original (_o, _k, _h, _b)")
                    else:
                        # Default click: skip _o (usually 404s), start with _k
                        sizes = ['_k', '_h', '_b']
                        logger.info("Flickr fallback: trying public sizes (_k, _h, _b)")
                    for size in sizes:
                        urls_to_try.append(f"{base_without_size}{size}{ext_part}")
                else:
                    # No size suffix - add size before extension
                    # Example: 54769514860_65965c98e7.jpg -> 54769514860_65965c98e7_k.jpg
                    base_match = re.search(r'^(.+)(\.[a-zA-Z]+)$', base_url)
                    if base_match:
                        base_without_ext = base_match.group(1)
                        ext_part = base_match.group(2)
                        if max_width is None:
                            sizes = ['_o', '_k', '_h', '_b']
                            logger.info("Flickr fallback (no size suffix): trying original (_o, _k, _h, _b)")
                        else:
                            sizes = ['_k', '_h', '_b']
                            logger.info("Flickr fallback (no size suffix): trying public sizes (_k, _h, _b)")
                        for size in sizes:
                            urls_to_try.append(f"{base_without_ext}{size}{ext_part}")
                urls_to_try.append(base_url)  # Original as last resort

                image_path = None
                downloaded_size = None
                async with httpx.AsyncClient(follow_redirects=True, timeout=30.0, cookies=cookies_dict) as client:
                    # First try URL size swapping (works if extension already sent correct URL)
                    for try_url in urls_to_try:
                        try:
                            response = await client.get(try_url, headers={
                                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                                'Referer': request.page_url or request.image_url
                            })
                            if response.status_code == 200:
                                await _run_thread_to_completion(
                                    _validated_image_payload,
                                    response.content,
                                )
                                content_type = response.headers.get('content-type', '')
                                if 'jpeg' in content_type or 'jpg' in content_type:
                                    ext = '.jpg'
                                elif 'png' in content_type:
                                    ext = '.png'
                                elif 'webp' in content_type:
                                    ext = '.webp'
                                else:
                                    ext = Path(try_url.split('?')[0]).suffix or '.jpg'
                                image_path = await _publish_downloaded_bytes(
                                    response.content,
                                    output_dir / f"{basename}{ext}",
                                    output_dir=output_dir,
                                )
                                downloaded_size = try_url.split('_')[-1].split('.')[0]
                                attempt_artifacts.add(image_path)
                                logger.info(f"Fallback saved: {image_path.name} (from {downloaded_size} variant)")
                                break
                        except Exception as e:
                            logger.debug(f"Size variant {try_url} failed: {e}")
                            continue

                    # If only got _b (1024px) or smaller, try fetching page HTML for high-res URLs
                    # High-res sizes (k,h,3k,4k,5k,o) have different secrets than thumbnail
                    # Also trigger if downloaded_size doesn't look like a valid size code (e.g., it's the secret from a no-suffix URL)
                    small_sizes = ['b', 'c', 'z', 'w', 'n', 'm', 't', 'q', 's']
                    should_try_page_html = (
                        image_path and request.page_url and
                        (downloaded_size in small_sizes or len(downloaded_size) > 1)  # 'b' or likely a secret (multi-char)
                    )
                    if should_try_page_html:
                        logger.info(f"Got small/thumbnail size ({downloaded_size}), trying page HTML extraction for high-res")
                        try:
                            page_response = await client.get(request.page_url, headers={
                                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
                            })
                            if page_response.status_code == 200:
                                html = page_response.text
                                # Extract photo ID from image URL (handle both with and without size suffix)
                                photo_id_match = re.search(r'/(\d+)_[a-f0-9]+(?:_[a-z0-9]+)?\.jpg', request.image_url, re.I)
                                if photo_id_match:
                                    photo_id = photo_id_match.group(1)
                                    # Try sizes in order: 5k, 4k, 3k, k, h (skip o unless alt-click)
                                    size_order = ['o', '5k', '4k', '3k', 'k', 'h'] if max_width is None else ['5k', '4k', '3k', 'k', 'h']
                                    for size in size_order:
                                        # Match escaped URL pattern for this photo
                                        pattern = rf'\\/\\/live\.staticflickr\.com\\/\d+\\/{photo_id}_[a-f0-9]+_{size}\.jpg'
                                        url_match = re.search(pattern, html, re.I)
                                        if url_match:
                                            high_res_url = 'https:' + url_match.group(0).replace('\\/', '/')
                                            logger.info(f"Found {size} URL in page HTML: {high_res_url}")
                                            hr_response = await client.get(high_res_url, headers={
                                                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                                                'Referer': request.page_url
                                            })
                                            if hr_response.status_code == 200:
                                                await _run_thread_to_completion(
                                                    _validated_image_payload,
                                                    hr_response.content,
                                                )
                                                # Publish high resolution without replacing any
                                                # cross-process destination, then retire only the
                                                # lower-resolution artifact created by this attempt.
                                                previous_path = image_path
                                                upgraded_path = await _publish_downloaded_bytes(
                                                    hr_response.content,
                                                    previous_path,
                                                    output_dir=output_dir,
                                                )
                                                attempt_artifacts.add(upgraded_path)
                                                await asyncio.to_thread(
                                                    previous_path.unlink,
                                                    missing_ok=True,
                                                )
                                                attempt_artifacts.discard(previous_path)
                                                image_path = upgraded_path
                                                downloaded_size = size
                                                logger.info(f"Upgraded to {size} size from page HTML")
                                                break
                        except Exception as e:
                            logger.warning(f"Page HTML extraction failed: {e}")

                if not image_path:
                    raise ValueError("All Flickr size variants failed")

                # Check pixel dimensions and mark small images
                try:
                    width, height = await asyncio.to_thread(
                        _validated_image_dimensions,
                        image_path,
                    )
                    # Check minimum (2000px default) - mark small but don't delete
                    min_pixels = options.get('min_pixels', 2000)
                    shortest_side = min(width, height)
                    if shortest_side < min_pixels:
                        logger.warning(f"Flickr fallback small: {width}x{height} (min: {min_pixels}px)")
                        # Rename with -small suffix instead of deleting
                        small_path = image_path.with_stem(image_path.stem + "-small")
                        relocated = relocate_public_file(
                            image_path,
                            small_path,
                            root=output_dir,
                        )
                        attempt_artifacts.discard(image_path)
                        attempt_artifacts.add(relocated)
                        image_path = relocated
                        basename = basename + "-small"
                        logger.info(f"Marked as small: {image_path.name}")

                    # Check maximum if set (8K default click)
                    elif max_width and max(width, height) > max_width:
                        logger.warning(f"Flickr image exceeds max_width: {width}x{height} > {max_width}")
                        # Don't delete - user might still want it, just warn
                        logger.info("Keeping image despite exceeding max_width (use Alt+Click for unlimited)")

                    logger.info(f"Flickr fallback dimensions: {width}x{height}")
                except ImportError:
                    pass
        else:
            # Direct HTTP download for regular images
            # Build cookies dict from request
            cookies_dict = {c.name: c.value for c in request.cookies}
            logger.info(f"Downloading with {len(cookies_dict)} cookies")

            async with httpx.AsyncClient(follow_redirects=True, timeout=30.0, cookies=cookies_dict) as client:
                response = await client.get(request.image_url, headers={
                    'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                    'Referer': request.page_url or request.image_url
                })
                response.raise_for_status()

                await _run_thread_to_completion(
                    _validated_image_payload,
                    response.content,
                )

                # Determine extension from content-type or URL
                content_type = response.headers.get('content-type', '')
                if 'jpeg' in content_type or 'jpg' in content_type:
                    ext = '.jpg'
                elif 'png' in content_type:
                    ext = '.png'
                elif 'gif' in content_type:
                    ext = '.gif'
                elif 'webp' in content_type:
                    ext = '.webp'
                else:
                    # Try from URL
                    image_url_path = request.image_url.split('?')[0]
                    ext = Path(image_url_path).suffix or '.jpg'

                image_path = await _publish_downloaded_bytes(
                    response.content,
                    output_dir / f"{basename}{ext}",
                    output_dir=output_dir,
                )
                logger.info(f"Saved image: {image_path.name}")
                attempt_artifacts.add(image_path)

        # Create .md sidecar (always - metadata like alt text is valuable)
        md_path = output_dir / f"{basename}.md"
        now = datetime.now()
        fields = {
            "source": request.image_url,
            "capture_id": capture_id,
            "platform": platform,
            "author": author,
            "title": title,
            "archived": now,
            "download_date": now,
            "page_url": request.metadata.page_url,
            "description": request.metadata.description,
            "date_taken": DateText(request.metadata.dateTaken) if request.metadata.dateTaken else None,
            "tags": list(dict.fromkeys(request.metadata.tags or [])),
            "notes": request.metadata.note,
        }
        md_path = await _publish_downloaded_bytes(
            render_sidecar(fields, ["", f"![[{image_path.name}]]", ""]),
            md_path,
            output_dir=output_dir,
        )
        _require_attempt_file(md_path, "Image sidecar")
        attempt_artifacts.add(md_path)
        logger.info(f"Saved sidecar: {md_path.name}")

        return {
            "success": True,
            "message": f"Archived: {image_path.name}",
            "file_path": str(image_path),
            "sidecar_path": str(md_path),
            "published_paths": [str(path) for path in attempt_artifacts],
            "output_dir": str(output_dir),
        }

    except asyncio.CancelledError:
        try:
            rollback = asyncio.create_task(
                _retract_attempt_artifacts(attempt_artifacts, output_dir)
            )
            await asyncio.shield(rollback)
        except BaseException as rollback_error:
            logger.critical(
                "Image capture cancellation rollback failed for exact paths %s: %s",
                sorted(str(path) for path in attempt_artifacts),
                rollback_error,
            )
        raise
    except Exception as e:
        try:
            await _retract_attempt_artifacts(attempt_artifacts, output_dir)
        except Exception as rollback_error:
            logger.critical("Image archive rollback failed: %s", rollback_error)
            e = RuntimeError(f"{e}; artifact rollback failed: {rollback_error}")
        logger.error(f"Image archive failed: {e}")
        return {
            "success": False,
            "message": str(e)
        }


@track_capture(lambda: db, get_capture_service)
async def process_image_capture(
    job_id: str,
    intent: CaptureIntent,
    cookies: List[CaptureCookieData],
):
    """Run an image CaptureIntent through the existing image implementation."""
    attempt_artifacts: set[Path] = set()
    output_dir: Optional[Path] = None
    job_committed = False
    request = None
    try:
        await db.update_job_status(job_id, "downloading")
        media = intent.media
        request = ImageArchiveRequest(
            image_url=media.url if media else intent.targetUrl,
            page_url=intent.sourcePageUrl,
            save_mode=intent.options.saveMode,
            cookies=cookies,
            options=client_options(intent.options.download, CLIENT_DOWNLOAD_KEYS, "download"),
            metadata=ImageMetadata(
                platform=intent.options.platform,
                title=intent.page.title,
                author=intent.page.author,
                description=intent.page.description or (media.alt if media else ""),
                page_url=intent.sourcePageUrl,
                tags=intent.user.tags,
                note=intent.user.note,
                dateTaken=intent.options.siteData.get("dateTaken", ""),
                assetId=intent.options.siteData.get("assetId", ""),
            ),
        )
        result = await _archive_image_impl(request, capture_id=intent.captureId)
        attempt_artifacts.update(
            Path(path) for path in result.get("published_paths", [])
        )
        if result.get("output_dir"):
            output_dir = Path(result["output_dir"])

        if result.get("success"):
            file_path = _require_attempt_file(
                Path(result.get("file_path", "")),
                "Image capture",
            )
            completion_metadata = {
                "original_url": request.image_url,
                "title": request.metadata.title,
                "author": request.metadata.author,
                "description": request.metadata.description,
                "tags": request.metadata.tags,
                "notes": request.metadata.note,
                "capture_id": intent.captureId,
                "capture_kind": intent.kind,
            }
            if result.get("sidecar_path"):
                completion_metadata["sidecar_path"] = result["sidecar_path"]

            completion = asyncio.create_task(db.update_job_complete(
                job_id,
                str(file_path),
                completion_metadata,
            ))
            try:
                await asyncio.shield(completion)
            except asyncio.CancelledError:
                await asyncio.shield(completion)
                job_committed = True
                raise
            job_committed = True
        else:
            await db.update_job_failed(
                job_id,
                result.get("message", "Image capture failed"),
                "image_capture_failed",
            )
    except asyncio.CancelledError:
        if not job_committed:
            try:
                rollback = asyncio.create_task(
                    _retract_attempt_artifacts(attempt_artifacts, output_dir)
                )
                await asyncio.shield(rollback)
            except BaseException as rollback_error:
                logger.critical(
                    "Image job %s cancellation rollback failed: %s",
                    job_id,
                    rollback_error,
                )
            try:
                failure_update = asyncio.create_task(
                    db.update_job_failed(job_id, "Image capture cancelled", "cancelled")
                )
                await asyncio.shield(failure_update)
            except BaseException as update_error:
                logger.error(
                    "Image job %s cancellation state update failed: %s",
                    job_id,
                    update_error,
                )
        raise
    except Exception as error:
        if not job_committed:
            try:
                await _retract_attempt_artifacts(attempt_artifacts, output_dir)
            except Exception as rollback_error:
                logger.critical(
                    "Image job %s rollback failed: %s",
                    job_id,
                    rollback_error,
                )
            await db.update_job_failed(
                job_id,
                str(error),
                "image_capture_failed",
            )
        else:
            logger.critical(
                "Image job %s failed after durable completion: %s",
                job_id,
                error,
            )


@app.post("/captures")
async def submit_capture(
    submission: CaptureSubmission,
    background_tasks: BackgroundTasks,
):
    """Submit a versioned, idempotent capture intent."""
    try:
        return await get_capture_service().submit(submission, background_tasks)
    except CaptureTargetRejectedError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/captures/{capture_id}")
async def get_capture(capture_id: str):
    receipt = await get_capture_service().get(capture_id)
    if receipt is None:
        raise HTTPException(status_code=404, detail="Capture not found")
    return receipt


@app.patch("/captures/{capture_id}")
async def patch_capture(capture_id: str, patch: CapturePatch):
    try:
        receipt = await get_capture_service().patch(capture_id, patch)
    except CaptureMutationConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if receipt is None:
        raise HTTPException(status_code=404, detail="Capture not found")
    return receipt


@app.post("/captures/{capture_id}/retry")
async def retry_capture(
    capture_id: str,
    retry: CaptureRetry,
    background_tasks: BackgroundTasks,
):
    """Replay a failed capture with fresh, non-persisted credentials."""
    try:
        receipt = await get_capture_service().retry(capture_id, retry, background_tasks)
    except CaptureRetryError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if receipt is None:
        raise HTTPException(status_code=404, detail="Capture not found")
    return receipt


def _public_job(job: Dict) -> Dict:
    """A job as clients see it. The stored capture request carries the base64 page
    screenshot (often near 1 MB); no client reads it back, and the extension polls."""
    return {key: value for key, value in job.items() if key != 'intent'}

@app.get("/jobs")
async def list_jobs(limit: int = 50, status: Optional[str] = None):
    """Get list of archive jobs"""
    jobs = await db.get_jobs(limit=limit, status=status)
    return {"jobs": [_public_job(job) for job in jobs]}

@app.get("/jobs/{job_id}")
async def get_job(job_id: str):
    """Get specific job details"""
    job = await db.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return _public_job(job)

@app.get("/search")
async def search_archives(q: str, limit: int = 50):
    """Search archived media"""
    results = await db.search(query=q, limit=limit)
    return {"results": results}

@app.post("/check-archived", response_model=CheckArchivedResponse)
async def check_archived(request: CheckArchivedRequest):
    """
    Check if a URL has been archived in the last 3 months.
    Optionally verifies the file still exists on disk.
    """
    result = await db.check_url_archived(request.url)

    if not result:
        return CheckArchivedResponse(archived=False)

    return CheckArchivedResponse(
        archived=True,
        job_id=result.get('id'),
        file_path=result.get('file_path') if request.check_file_exists else None,
        file_exists=result.get('file_exists') if request.check_file_exists else None,
        archived_date=result.get('created_at'),
        age_days=result.get('age_days')
    )

@app.get("/stats")
async def get_stats():
    """Get archival statistics"""
    stats = await db.get_stats()
    return stats

@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard():
    """Simple web dashboard"""
    return """
    <!DOCTYPE html>
    <html>
    <head>
        <title>nodraw Dashboard</title>
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                max-width: 1200px;
                margin: 0 auto;
                padding: 20px;
                background: #f5f5f5;
            }
            h1 {
                color: #667eea;
            }
            .stats {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                gap: 20px;
                margin: 20px 0;
            }
            .stat-card {
                background: white;
                padding: 20px;
                border-radius: 8px;
                box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            }
            .stat-value {
                font-size: 32px;
                font-weight: bold;
                color: #667eea;
            }
            .stat-label {
                color: #6b7280;
                margin-top: 5px;
            }
            .jobs {
                background: white;
                border-radius: 8px;
                padding: 20px;
                margin-top: 20px;
            }
            table {
                width: 100%;
                border-collapse: collapse;
            }
            th {
                text-align: left;
                padding: 10px;
                border-bottom: 2px solid #e5e7eb;
                color: #374151;
            }
            td {
                padding: 10px;
                border-bottom: 1px solid #f3f4f6;
            }
            .status {
                padding: 4px 8px;
                border-radius: 4px;
                font-size: 12px;
                font-weight: 500;
            }
            .status.completed { background: #d1fae5; color: #065f46; }
            .status.downloading { background: #fed7aa; color: #92400e; }
            .status.failed { background: #fee2e2; color: #991b1b; }
            .status.pending { background: #e0e7ff; color: #3730a3; }
        </style>
    </head>
    <body>
        <h1>nodraw Dashboard</h1>

        <div class="stats" id="stats">
            <div class="stat-card">
                <div class="stat-value">-</div>
                <div class="stat-label">Total Archives</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">-</div>
                <div class="stat-label">Today</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">-</div>
                <div class="stat-label">This Week</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">-</div>
                <div class="stat-label">Storage Used</div>
            </div>
        </div>

        <div class="jobs">
            <h2>Recent Archives</h2>
            <table id="jobsTable">
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>URL</th>
                        <th>Status</th>
                        <th>File</th>
                    </tr>
                </thead>
                <tbody id="jobsBody">
                    <tr><td colspan="4">Loading...</td></tr>
                </tbody>
            </table>
        </div>

        <script>
            async function loadDashboard() {
                // Load stats
                const statsRes = await fetch('/stats');
                const stats = await statsRes.json();

                const statCards = document.querySelectorAll('.stat-card');
                statCards[0].querySelector('.stat-value').textContent = stats.total_archives || '0';
                statCards[1].querySelector('.stat-value').textContent = stats.today_count || '0';
                statCards[2].querySelector('.stat-value').textContent = stats.week_count || '0';
                statCards[3].querySelector('.stat-value').textContent = formatBytes(stats.total_size || 0);

                // Load jobs
                const jobsRes = await fetch('/jobs?limit=20');
                const jobsData = await jobsRes.json();

                const tbody = document.getElementById('jobsBody');
                if (jobsData.jobs && jobsData.jobs.length > 0) {
                    tbody.innerHTML = jobsData.jobs.map(job => `
                        <tr>
                            <td>${new Date(job.created_at).toLocaleString()}</td>
                            <td>${new URL(job.url).hostname}</td>
                            <td><span class="status ${job.status}">${job.status}</span></td>
                            <td>${job.file_path ? '✓' : '-'}</td>
                        </tr>
                    `).join('');
                } else {
                    tbody.innerHTML = '<tr><td colspan="4">No archives yet</td></tr>';
                }
            }

            function formatBytes(bytes) {
                if (bytes === 0) return '0 B';
                const k = 1024;
                const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
                const i = Math.floor(Math.log(bytes) / Math.log(k));
                return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
            }

            // Load on page load
            loadDashboard();

            // Refresh every 5 seconds
            setInterval(loadDashboard, 5000);
        </script>
    </body>
    </html>
    """

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=PORT)
