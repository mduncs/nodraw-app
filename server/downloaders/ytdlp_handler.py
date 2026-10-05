"""
yt-dlp handler for video/audio downloads

User's preferred settings (from ~/.zshrc):
- format: bestvideo+bestaudio/best
- merge_output_format: mp4
- concurrent_fragments: 4
- add_metadata, embed_thumbnail, embed_subs
"""

import yt_dlp
import asyncio
from concurrent.futures import Executor, ThreadPoolExecutor
from contextvars import copy_context
from capture_recovery import register_staging
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
from urllib.parse import urlparse
from platforms import FLICKR_DOMAINS, YOUTUBE_DOMAINS, matches_domains, url_hostname, url_path
from typing import Dict, Optional
from uuid import uuid4
import logging
from .base import BaseDownloader, DownloadFailureKind, DownloadResult
from .runtime_safety import (
    _move_file_no_clobber as move_file_no_clobber,
    ensure_contained_directory,
    write_private_text,
)
from media_normalization import (
    MediaNormalizationCancelledError,
    MediaNormalizationError,
    MediaNormalizationResult,
    MediaNormalizer,
)
from storage import detect_platform

logger = logging.getLogger(__name__)

MEDIA_EXTENSIONS = {
    '.mp4', '.webm', '.mkv', '.mov',
    '.mp3', '.m4a', '.opus', '.wav', '.ogg', '.flac', '.aac'
}
VIDEO_EXTENSIONS = {'.mp4', '.webm', '.mkv', '.mov'}


def _configured_normalization_workers() -> int:
    """Return a conservative process-wide cap for CPU/I/O-heavy normalization."""
    raw_value = os.environ.get('MEDIA_NORMALIZATION_CONCURRENCY', '2')
    try:
        requested = int(raw_value)
    except (TypeError, ValueError):
        logger.warning(
            "Invalid MEDIA_NORMALIZATION_CONCURRENCY=%r; using 2",
            raw_value,
        )
        return 2
    return max(1, min(requested, 8))


NORMALIZATION_WORKER_LIMIT = _configured_normalization_workers()
_NORMALIZATION_EXECUTOR = ThreadPoolExecutor(
    max_workers=NORMALIZATION_WORKER_LIMIT,
    thread_name_prefix='nodraw-media-normalizer',
)
_PUBLICATION_LOCK = threading.Lock()


class RecoveredMediaQuarantineError(RuntimeError):
    """A rejected new recovery could not be moved outside watcher-visible media paths."""


class MediaPublishError(RuntimeError):
    """A verified staged download could not be atomically published."""


class IngestCancellationRequested(RuntimeError):
    """Internal signal used to roll back a publication after task cancellation."""


class CancelledIngestPreservedError(RuntimeError):
    """Cancellation stopped public commit and retained any completed bytes."""

    def __init__(self, preserved_paths: list[Path]) -> None:
        self.preserved_paths = preserved_paths
        detail = ", ".join(str(path) for path in preserved_paths) or "no staged media"
        super().__init__(f"Cancelled ingest preserved outside archive indexing: {detail}")


class YtDlpHandler(BaseDownloader):
    """Handler for yt-dlp supported sites"""

    name = "yt-dlp"

    # Domains that yt-dlp handles well
    SUPPORTED_DOMAINS = [
        'youtube.com', 'youtu.be',
        'twitter.com', 'x.com',
        'instagram.com',
        'tiktok.com',
        'vimeo.com',
        'twitch.tv',
        'reddit.com',
        'facebook.com',
        'dailymotion.com',
        'soundcloud.com',
        'bandcamp.com'
    ]

    # Domains to exclude (handled by gallery-dl instead)
    EXCLUDED_DOMAINS = [
        *FLICKR_DOMAINS,
        'pixiv.net',
        'artstation.com',
        'deviantart.com',
        'tumblr.com',
        'pinterest.com',
        'danbooru.donmai.us',
        'gelbooru.com'
    ]

    def __init__(
        self,
        media_normalizer: Optional[MediaNormalizer] = None,
        *,
        normalization_executor: Optional[Executor] = None,
    ) -> None:
        self.media_normalizer = media_normalizer or MediaNormalizer()
        # The production DownloadManager owns one handler, and all normalization
        # work shares this bounded executor. Tests may inject a narrower executor.
        self._normalization_executor = normalization_executor or _NORMALIZATION_EXECUTOR

    def can_handle(self, url: str) -> bool:
        """Check if yt-dlp can handle this URL"""

        # Check exclusions first
        if matches_domains(url, self.EXCLUDED_DOMAINS):
            return False

        # Check known domains
        for domain in self.SUPPORTED_DOMAINS:
            if matches_domains(url, (domain,)):
                return True

        # For unknown domains, let yt-dlp try (it supports 1000+ sites)
        return True

    async def download(
        self,
        url: str,
        cookies: Dict[str, str],
        output_dir: Path,
        options: Optional[Dict] = None
    ) -> DownloadResult:
        """Download media using yt-dlp"""
        loop = asyncio.get_running_loop()

        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        # Detect platform for filename
        platform = detect_platform(url)

        stage_dir = output_dir / f'.nodraw-ingest-{uuid4().hex}'
        register_staging(stage_dir)
        stage_dir.mkdir()

        # Prepare cookie file if cookies provided
        # Skip cookies for YouTube - they cause HTTP 413 errors and aren't needed for public videos
        cookie_file = None
        is_youtube = matches_domains(url, YOUTUBE_DOMAINS)
        if cookies and not is_youtube:
            # Each download owns its credentials inside its unique hidden stage.
            # This prevents simultaneous captures from overwriting or unlinking
            # another yt-dlp process's cookie file.
            cookie_file = stage_dir / '.cookies.txt'
            self._write_netscape_cookies(
                cookie_file,
                cookies,
                url,
                cookie_records=(options or {}).get('_cookie_records'),
            )

        # Configure yt-dlp options (user's preferred settings from ~/.zshrc)
        ydl_opts = {
            # Output template: HHMMSS-platform-title.ext
            # yt-dlp will fill in title and ext; we use restrictfilenames for safety
            # Title capped at 150 chars for filesystem safety
            'outtmpl': str(stage_dir / f'.{self._get_time_prefix()}-{platform}-%(title).150s.%(ext)s'),
            'restrictfilenames': True,  # Sanitize filenames (replaces spaces with _)
            'windowsfilenames': True,   # Cross-platform safe filenames

            # Format selection (user's preferred: bestvideo+bestaudio/best)
            'format': 'bestvideo+bestaudio/best',
            'merge_output_format': 'mp4',

            # Concurrent downloads (user prefers 4, not 5)
            'concurrent_fragment_downloads': 4,

            # Thumbnail handling
            'writethumbnail': True,

            # Subtitles (user wants embedded)
            'writesubtitles': True,
            'writeautomaticsub': True,
            'subtitleslangs': ['en', 'en-US'],
            'embedsubtitles': True,

            # Post-processing (metadata only - thumbnail embed often fails)
            'postprocessors': [
                {
                    'key': 'FFmpegMetadata',
                    'add_metadata': True,
                },
            ],

            # We don't write separate info.json - metadata saved via storage layer
            'writeinfojson': False,
            'writedescription': False,

            # Download options
            'quiet': False,
            'no_warnings': False,
            'extract_flat': False,
            'no_color': True,
            'progress_hooks': [self._progress_hook],

            # Reliability - tolerate post-processing failures
            'retries': 10,
            'fragment_retries': 10,
            'skip_unavailable_fragments': False,
            'ignoreerrors': 'only_download',
            'ignore_no_formats_error': True,

            # Enable remote components for JS challenges (YouTube)
            'enable_remote_components': 'ejs:github'
        }
        if is_youtube:
            # A watch URL may carry a playlist parameter. The toolbar promises
            # one item, so never allow yt-dlp to expand it into the whole list.
            ydl_opts['noplaylist'] = True

        # Twitter's extractor appends quoted videos to its own playlist. The
        # capture processor fetches recorded quotes separately at every depth.
        if platform == 'twitter' and options and options.get('twitterPlaylistItems'):
            # Only the quoted videos that follow the post's own (see download_twitter_quoted_media).
            ydl_opts['playlist_items'] = str(options['twitterPlaylistItems'])
        elif platform == 'twitter' and options and not options.get('twitterQuoted'):
            own_media = (options.get('tweetContent') or {}).get('media')
            if isinstance(own_media, list):
                video_count = sum(1 for entry in own_media if isinstance(entry, dict) and entry.get('kind') in ('video', 'gif'))
                if not video_count and (options['tweetContent'].get('hasVideo') or options['tweetContent'].get('hasGif')):
                    video_count = 1
                if video_count:
                    ydl_opts['playlist_items'] = f'1:{video_count}'

        # Add cookie file if available
        if cookie_file and cookie_file.exists():
            ydl_opts['cookiefile'] = str(cookie_file)
            logger.info(f"Using cookies for {url}")

        # Handle save_mode for YouTube
        save_mode = options.get('save_mode', 'full') if options else 'full'

        if is_youtube and save_mode == 'quick':
            # Audio-only mode: extract audio as mp3 with embedded thumbnail
            logger.info(f"YouTube quick mode: audio-only extraction with thumbnail")
            ydl_opts['format'] = 'bestaudio/best'
            ydl_opts['writethumbnail'] = True  # Download thumbnail for embedding
            ydl_opts['postprocessors'] = [
                {
                    'key': 'FFmpegExtractAudio',
                    'preferredcodec': 'mp3',
                    'preferredquality': '192',
                },
                {
                    'key': 'FFmpegThumbnailsConvertor',
                    'format': 'jpg',  # Convert webp to jpg for better compatibility
                },
                {
                    'key': 'EmbedThumbnail',
                    'already_have_thumbnail': False,
                },
                {
                    'key': 'FFmpegMetadata',
                    'add_metadata': True,
                },
            ]
            # Update output template for mp3
            ydl_opts['outtmpl'] = str(stage_dir / f'.{self._get_time_prefix()}-{platform}-%(title).150s.%(ext)s')
            # No video merging needed
            ydl_opts.pop('merge_output_format', None)
            # Disable subtitles for audio-only
            ydl_opts['writesubtitles'] = False
            ydl_opts['writeautomaticsub'] = False
            ydl_opts['embedsubtitles'] = False

        elif is_youtube and save_mode == 'text':
            # Video + transcripts mode: download video and write subtitles as separate files
            logger.info(f"YouTube text mode: video + subtitle files")
            # Keep video download with current format
            ydl_opts['writesubtitles'] = True
            ydl_opts['writeautomaticsub'] = True
            ydl_opts['subtitleslangs'] = ['en', 'en-US', 'en-GB']
            # Don't embed - write separate files for Obsidian
            ydl_opts['embedsubtitles'] = False
            # Also write thumbnail
            ydl_opts['writethumbnail'] = True

        # Platform-specific options
        if platform == 'twitter':
            # Twitter often needs simpler format selection
            ydl_opts['format'] = 'best[ext=mp4]/best'
            # Prefer stable tweet ids in filenames and avoid standalone thumbnail files.
            ydl_opts['writethumbnail'] = False
            ydl_opts['outtmpl'] = str(
                stage_dir / f'.{self._get_time_prefix()}-{platform}-%(uploader_id)s-%(display_id)s.%(ext)s'
            )
        # A caller fetching a bare media URL (an X GIF's MP4) names the file after its post.
        if options and options.get('filenameStem'):
            ydl_opts['outtmpl'] = str(stage_dir / f".{self._get_time_prefix()}-{options['filenameStem']}.%(ext)s")

        cleanup_stage = True
        download_completed = False
        defer_cookie_cleanup = False
        download_future = None
        normalization_future = None
        cancellation_event = threading.Event()
        try:
            # Run download in thread pool to avoid blocking
            download_future = loop.run_in_executor(
                None,
                self._download_sync,
                url, ydl_opts
            )
            # Do not let task cancellation remove staging while yt-dlp is still
            # writing in the worker thread.
            result = await asyncio.shield(download_future)
            download_completed = result.success
            # yt-dlp has stopped reading credentials. Remove them before any
            # normalization or recovery scan can observe staged artifacts.
            self._remove_cookie_file(cookie_file)
            cookie_file = None

            if result.success:
                normalization_future = loop.run_in_executor(
                    self._normalization_executor,
                    copy_context().run,
                    self._normalize_and_publish,
                    result, stage_dir, output_dir, cancellation_event,
                )
                # A cancelled await does not stop a running executor callable.
                # Shield it so the cancellation path can retain/clean staging
                # without racing the normalizer.
                result = await asyncio.shield(normalization_future)

            return result

        except asyncio.CancelledError:
            cancellation_event.set()
            cleanup_stage = False
            if normalization_future is not None:
                normalization_future.add_done_callback(
                    lambda future: self._finish_cancelled_normalization(
                        future,
                        stage_dir,
                        output_dir,
                    )
                )
                logger.warning(
                    "yt-dlp ingest cancelled; hidden staging retained until active "
                    "normalization completes: %s",
                    stage_dir,
                )
            elif download_future is not None:
                # The executor callable cannot be interrupted. It still owns both
                # staging and credentials until its future settles.
                defer_cookie_cleanup = True
                download_future.add_done_callback(
                    lambda future: self._finish_cancelled_download(
                        future,
                        stage_dir=stage_dir,
                        output_dir=output_dir,
                        cookie_file=cookie_file,
                    )
                )
                logger.warning(
                    "yt-dlp ingest cancelled during download; cleanup will follow "
                    "worker completion: %s",
                    stage_dir,
                )
            else:
                logger.warning(
                    "yt-dlp ingest cancelled before worker creation; hidden staging "
                    "retained for recovery: %s",
                    stage_dir,
                )
            raise
        except Exception as e:
            logger.error(f"yt-dlp download failed: {e}")
            preserve_all_completed_bytes = (
                download_completed or isinstance(e, RecoveredMediaQuarantineError)
            )
            preservation_label = (
                'completed download' if preserve_all_completed_bytes else 'rejected recovery'
            )
            recovery_future = None
            try:
                recovery_callable = (
                    self._preserve_completed_stage
                    if preserve_all_completed_bytes
                    else self._preserve_rejected_recoveries
                )
                recovery_future = loop.run_in_executor(
                    self._normalization_executor,
                    recovery_callable,
                    stage_dir,
                    output_dir,
                )
                preserved_recoveries = await asyncio.shield(recovery_future)
            except asyncio.CancelledError:
                cleanup_stage = False
                if recovery_future is not None:
                    recovery_future.add_done_callback(
                        lambda completed: self._finish_cancelled_stage_recovery(
                            completed,
                            stage_dir,
                        )
                    )
                raise
            except Exception as preservation_error:
                cleanup_stage = False
                logger.critical(
                    f"Could not preserve {preservation_label} from {stage_dir}: "
                    f"{preservation_error}; hidden staging was retained"
                )
                error_detail = (
                    f"{e}; {preservation_label} remains in hidden staging at "
                    f"{stage_dir}: {preservation_error}"
                )
            else:
                error_detail = str(e)
                if preserved_recoveries:
                    error_detail += (
                        f"; {preservation_label} preserved at "
                        + ", ".join(str(path) for path in preserved_recoveries)
                    )
            return DownloadResult(
                file_path=None,
                metadata={},
                success=False,
                error=error_detail,
                failure_kind=DownloadFailureKind.TERMINAL,
            )
        finally:
            if not defer_cookie_cleanup:
                self._remove_cookie_file(cookie_file)
            if cleanup_stage:
                await asyncio.to_thread(shutil.rmtree, stage_dir, ignore_errors=True)

    @staticmethod
    def _finish_cancelled_stage_recovery(future, stage_dir: Path) -> None:
        try:
            future.result()
        except BaseException as error:
            logger.error(
                "Cancelled failure-recovery task failed; hidden staging retained "
                "at %s: %s",
                stage_dir,
                error,
            )
            return
        shutil.rmtree(stage_dir, ignore_errors=True)

    @staticmethod
    def _remove_cookie_file(cookie_file: Optional[Path]) -> None:
        if cookie_file is None:
            return
        try:
            cookie_file.unlink(missing_ok=True)
        except OSError as error:
            logger.warning("Could not remove staged cookie file %s: %s", cookie_file, error)

    def _finish_cancelled_download(
        self,
        future,
        *,
        stage_dir: Path,
        output_dir: Path,
        cookie_file: Optional[Path],
    ) -> None:
        """Settle staging only after a cancelled yt-dlp worker stops writing."""
        try:
            future.result()
        except BaseException as error:
            logger.warning(
                "Cancelled yt-dlp worker ended with an error; preserving any staged "
                "bytes from %s: %s",
                stage_dir,
                error,
            )
        self._remove_cookie_file(cookie_file)

        try:
            recovery_future = self._normalization_executor.submit(
                self._preserve_completed_stage,
                stage_dir,
                output_dir,
            )
        except RuntimeError as error:
            logger.error(
                "Could not schedule cancelled-download recovery; hidden staging "
                "retained at %s: %s",
                stage_dir,
                error,
            )
            return
        recovery_future.add_done_callback(
            lambda completed: self._finish_cancelled_download_recovery(
                completed,
                stage_dir,
            )
        )

    @staticmethod
    def _finish_cancelled_download_recovery(future, stage_dir: Path) -> None:
        try:
            preserved = future.result()
        except BaseException as error:
            logger.error(
                "Cancelled-download recovery failed; hidden staging retained at %s: %s",
                stage_dir,
                error,
            )
            return
        if preserved:
            logger.warning(
                "Preserved cancelled download outside archive indexing: %s",
                ", ".join(str(path) for path in preserved),
            )
        shutil.rmtree(stage_dir, ignore_errors=True)

    def _finish_cancelled_normalization(
        self,
        future,
        stage_dir: Path,
        output_dir: Path,
    ) -> None:
        """Settle a cancelled normalizer without leaving public untracked media."""
        try:
            result = future.result()
        except CancelledIngestPreservedError as error:
            logger.warning("%s", error)
            shutil.rmtree(stage_dir, ignore_errors=True)
            return
        except BaseException as error:
            logger.error(
                "Cancelled normalization failed; hidden staging retained at %s: %s",
                stage_dir,
                error,
            )
            return

        # The event can race the worker's final post-publication check by a few
        # instructions. A successful result carries the exact paths so they can
        # still be retracted into hidden recovery without guessing by basename.
        if not result.published_paths:
            logger.critical(
                "Cancellation raced a completed publication with no path manifest; "
                "public result remains at %s",
                result.file_path,
            )
            return
        try:
            recovery_future = self._normalization_executor.submit(
                self._preserve_staged_artifacts,
                list(result.published_paths),
                output_dir,
            )
        except RuntimeError as error:
            logger.critical(
                "Cancellation raced completed publication; recovery could not be "
                "scheduled and public result remains at %s: %s",
                result.file_path,
                error,
            )
            return
        recovery_future.add_done_callback(
            lambda completed: self._finish_cancelled_publication_recovery(
                completed,
                stage_dir,
            )
        )

    @staticmethod
    def _finish_cancelled_publication_recovery(future, stage_dir: Path) -> None:
        try:
            preserved = future.result()
        except BaseException as error:
            logger.critical(
                "Cancellation raced completed publication and recovery failed; "
                "public files may remain while hidden staging is retained at %s: %s",
                stage_dir,
                error,
            )
            return
        logger.warning(
            "Retracted cancellation-raced publication into hidden recovery: %s",
            ", ".join(str(path) for path in preserved),
        )
        shutil.rmtree(stage_dir, ignore_errors=True)

    def _normalize_and_publish(
        self,
        result: DownloadResult,
        stage_dir: Path,
        output_dir: Path,
        cancellation_event: Optional[threading.Event] = None,
    ) -> DownloadResult:
        """Normalize staged video files, then publish verified artifacts together."""
        stage_dir = stage_dir.resolve()
        output_dir = Path(output_dir)
        metadata = dict(result.metadata)

        if cancellation_event is not None and cancellation_event.is_set():
            self._preserve_cancelled_stage(stage_dir, output_dir)

        staged_media = self._staged_media_paths(result, stage_dir)
        if not staged_media:
            raise MediaPublishError("yt-dlp reported success without staged media")

        if result.file_path is None:
            raise MediaPublishError("yt-dlp reported success without a primary media path")
        primary = self._require_staged_file(Path(result.file_path), stage_dir)
        primary_key = primary.resolve()
        self._snapshot_staged_sources(staged_media)
        normalized_paths: dict[Path, Path] = {}
        normalization_results: list[MediaNormalizationResult] = []

        for staged_path in staged_media:
            if cancellation_event is not None and cancellation_event.is_set():
                self._preserve_cancelled_stage(stage_dir, output_dir)
            source_key = staged_path.resolve()
            try:
                if staged_path.suffix.lower() in VIDEO_EXTENSIONS:
                    if isinstance(self.media_normalizer, MediaNormalizer):
                        normalized = self.media_normalizer.normalize_staged(
                            staged_path,
                            cancellation_event=cancellation_event,
                        )
                    else:
                        normalized = self.media_normalizer.normalize_staged(staged_path)
                    normalized_paths[source_key] = normalized.media_path
                    normalization_results.append(normalized)
                else:
                    # Audio-only downloads use the native audio path and intentionally skip
                    # video compatibility normalization, but still require a complete,
                    # demuxable audio stream before anything becomes watcher-visible.
                    if not self._probe_recovered_media(
                        staged_path,
                        expected_stream='audio',
                        cancellation_event=cancellation_event,
                    ):
                        raise MediaPublishError(
                            f"Audio integrity validation failed for {staged_path.name}"
                        )
                    normalized_paths[source_key] = staged_path
            except MediaNormalizationCancelledError:
                self._preserve_cancelled_stage(stage_dir, output_dir)

        if cancellation_event is not None and cancellation_event.is_set():
            self._preserve_cancelled_stage(stage_dir, output_dir)

        publishable_media: list[Path] = []
        seen_media: set[Path] = set()
        for staged_path in staged_media:
            normalized_path = normalized_paths[staged_path.resolve()]
            if normalized_path not in seen_media:
                seen_media.add(normalized_path)
                publishable_media.append(normalized_path)

        normalized_primary = normalized_paths.get(primary_key)
        if normalized_primary is None:
            raise MediaPublishError("Primary yt-dlp file was not included in staged media")

        preserved_sources = {
            normalized.preserved_source: normalized.source_sha256
            for normalized in normalization_results
            if normalized.preserved_source is not None
        }
        if any(not digest for digest in preserved_sources.values()):
            raise MediaPublishError("Lossy normalization omitted its source SHA-256")
        staged_entries = list(stage_dir.iterdir())
        staged_symlinks = [path for path in staged_entries if path.is_symlink()]
        if staged_symlinks:
            raise MediaPublishError(
                "Refusing staged symbolic-link artifact: "
                + ", ".join(path.name for path in staged_symlinks)
            )
        rejected_sources = self._rejected_staged_files(stage_dir)
        for rejected_source in rejected_sources:
            preserved_sources[rejected_source] = self._sha256_file(rejected_source)
        staged_artifacts = [
            path
            for path in staged_entries
            if path.is_file() and not self._is_transient_staged_file(path)
        ]
        for media_path in publishable_media:
            if media_path not in staged_artifacts:
                staged_artifacts.append(media_path)
        for preserved_path in preserved_sources:
            if preserved_path not in staged_artifacts:
                staged_artifacts.append(preserved_path)

        # Destination selection and publication are one process-local critical
        # section. This keeps simultaneous captures with the same yt-dlp basename
        # from selecting the same suffix and silently replacing one another.
        try:
            with _PUBLICATION_LOCK:
                if cancellation_event is not None and cancellation_event.is_set():
                    raise IngestCancellationRequested(
                        "Ingest cancelled before publication"
                    )
                destinations = self._publication_destinations(
                    staged_artifacts,
                    preserved_sources=preserved_sources,
                    output_dir=output_dir,
                    primary_media=normalized_primary,
                )

                metadata['files'] = [
                    str(destinations[path].relative_to(output_dir))
                    for path in publishable_media
                ]
                if rejected_sources:
                    metadata['rejected_recoveries'] = [
                        str(destinations[path].relative_to(output_dir))
                        for path in rejected_sources
                    ]
                if normalization_results:
                    metadata['media_normalization'] = {
                        'schema_version': 1,
                        'items': [
                            normalized.provenance(
                                media_path=str(
                                    destinations[normalized.media_path].relative_to(output_dir)
                                ),
                                preserved_source=(
                                    str(
                                        destinations[normalized.preserved_source].relative_to(output_dir)
                                    )
                                    if normalized.preserved_source is not None
                                    else None
                                ),
                            )
                            for normalized in normalization_results
                        ],
                    }

                self._publish_staged_files(
                    destinations,
                    media_paths=set(publishable_media),
                    cancellation_event=cancellation_event,
                    archive_root=output_dir,
                )
        except IngestCancellationRequested:
            self._preserve_cancelled_stage(stage_dir, output_dir)

        public_destinations = tuple(
            destination
            for source, destination in destinations.items()
            if source not in preserved_sources
        )
        if cancellation_event is not None and cancellation_event.is_set():
            preserved = self._preserve_staged_artifacts(
                list(public_destinations),
                output_dir,
            )
            raise CancelledIngestPreservedError(preserved)
        return DownloadResult(
            file_path=destinations[normalized_primary],
            metadata=metadata,
            success=True,
            error=result.error,
            published_paths=public_destinations,
        )

    def _preserve_cancelled_stage(
        self,
        stage_dir: Path,
        output_dir: Path,
    ) -> None:
        preserved = self._preserve_completed_stage(stage_dir, output_dir)
        raise CancelledIngestPreservedError(preserved)

    def _staged_media_paths(
        self,
        result: DownloadResult,
        stage_dir: Path,
    ) -> list[Path]:
        paths: list[Path] = []
        seen: set[Path] = set()

        def add(path: Path) -> None:
            staged_path = self._require_staged_file(path, stage_dir)
            resolved = staged_path.resolve()
            if resolved in seen or staged_path.suffix.lower() not in MEDIA_EXTENSIONS:
                return
            seen.add(resolved)
            paths.append(staged_path)

        if result.file_path is not None:
            add(Path(result.file_path))
        raw_files = result.metadata.get('files')
        if isinstance(raw_files, list):
            for raw_path in raw_files:
                if not isinstance(raw_path, str) or not raw_path:
                    continue
                path = Path(raw_path)
                add(path if path.is_absolute() else stage_dir / path)
        return paths

    @staticmethod
    def _require_staged_file(path: Path, stage_dir: Path) -> Path:
        path = Path(path)
        if not path.is_absolute():
            path = stage_dir / path
        resolved = path.resolve()
        try:
            resolved.relative_to(stage_dir)
        except ValueError as error:
            raise MediaPublishError(f"yt-dlp result escaped staging: {path}") from error
        if not resolved.is_file() or resolved.stat().st_size <= 0:
            raise MediaPublishError(f"Staged download is missing or empty: {path}")
        if not resolved.name.startswith('.'):
            raise MediaPublishError(
                f"Transient yt-dlp media filename was watcher-visible: {resolved.name}"
            )
        return resolved

    @staticmethod
    def _snapshot_staged_sources(staged_media: list[Path]) -> list[Path]:
        """Snapshot exact inputs so later transforms cannot destroy sole source bytes."""
        snapshots: list[Path] = []
        for source in staged_media:
            snapshot = source.with_name(
                f".nodraw-source-snapshot-{source.name.lstrip('.')}"
            )
            counter = 1
            while os.path.lexists(snapshot):
                snapshot = source.with_name(
                    f".nodraw-source-snapshot-{counter}-{source.name.lstrip('.')}"
                )
                counter += 1
            try:
                os.link(source, snapshot)
            except OSError as link_error:
                # Hard links can be unavailable on otherwise valid filesystems
                # (network shares, FAT-family volumes, or restrictive mounts).
                # copy2 writes only to the hidden ingest directory; a failed copy
                # is removed before the caller is allowed to normalize anything.
                try:
                    shutil.copy2(source, snapshot)
                except OSError as copy_error:
                    snapshot.unlink(missing_ok=True)
                    for completed_snapshot in snapshots:
                        completed_snapshot.unlink(missing_ok=True)
                    raise MediaPublishError(
                        "Could not snapshot completed staged source "
                        f"{source.name}: hard link failed ({link_error}); "
                        f"copy failed ({copy_error})"
                    ) from copy_error
            snapshots.append(snapshot)
        return snapshots

    @staticmethod
    def _is_transient_staged_file(path: Path) -> bool:
        name = path.name.lower()
        return (
            name == '.cookies.txt'
            or name.startswith('.nodraw-work-')
            or name.startswith('.nodraw-source-snapshot-')
            or '.part' in name
            or name.endswith('.ytdl')
            or YtDlpHandler._is_quarantined_name(path)
        )

    @staticmethod
    def _is_quarantined_name(path: Path) -> bool:
        return re.search(r'\.invalid(?:-\d+)?$', path.name, re.IGNORECASE) is not None

    @staticmethod
    def _rejected_staged_files(stage_dir: Path) -> list[Path]:
        return [
            path
            for path in Path(stage_dir).iterdir()
            if path.is_file() and YtDlpHandler._is_quarantined_name(path)
        ]

    @staticmethod
    def _publication_destinations(
        staged_artifacts: list[Path],
        *,
        preserved_sources: dict[Path, Optional[str]],
        output_dir: Path,
        primary_media: Path,
    ) -> dict[Path, Path]:
        output_dir = Path(output_dir)
        destinations: dict[Path, Path] = {}
        recovery_dir = output_dir / '.nodraw-originals'
        public_sources: list[Path] = []
        recovery_sources: list[tuple[Path, str]] = []
        for source in staged_artifacts:
            if not source.name.startswith('.'):
                raise MediaPublishError(
                    f"Transient yt-dlp artifact was watcher-visible: {source.name}"
                )
            source_digest = preserved_sources.get(source)
            if source_digest:
                recovery_sources.append((source, str(source_digest)))
            else:
                public_sources.append(source)

        primary_name = primary_media.name.lstrip('.')
        primary_stem = Path(primary_name).stem
        ordinal = 1
        while True:
            public_destinations = {
                source: output_dir / YtDlpHandler._suffixed_public_name(
                    source.name.lstrip('.'),
                    family_stem=primary_stem,
                    ordinal=ordinal,
                )
                for source in public_sources
            }
            candidate_paths = list(public_destinations.values())
            if (
                len(set(candidate_paths)) == len(candidate_paths)
                and not any(os.path.lexists(path) for path in candidate_paths)
            ):
                destinations.update(public_destinations)
                break
            ordinal += 1

        reserved = set(destinations.values())
        for source, source_digest in recovery_sources:
            destination = recovery_dir / source_digest / source.name
            counter = 1
            while os.path.lexists(destination) or destination in reserved:
                destination = destination.with_name(f"{source.name}.{counter}")
                counter += 1
            destinations[source] = destination
            reserved.add(destination)
        return destinations

    @staticmethod
    def _suffixed_public_name(
        public_name: str,
        *,
        family_stem: str,
        ordinal: int,
    ) -> str:
        """Apply one stable collision suffix to a media artifact family."""
        if ordinal <= 1:
            return public_name
        family_prefix = f"{family_stem}."
        if public_name.startswith(family_prefix):
            return f"{family_stem}-{ordinal}{public_name[len(family_stem):]}"
        path = Path(public_name)
        return f"{path.stem}-{ordinal}{path.suffix}"

    @staticmethod
    def _publish_staged_files(
        destinations: dict[Path, Path],
        *,
        media_paths: set[Path],
        cancellation_event: Optional[threading.Event] = None,
        archive_root: Optional[Path] = None,
    ) -> None:
        """Publish with atomic no-clobber links and rollback partial families."""
        ordered = sorted(
            destinations.items(),
            key=lambda pair: (pair[0] in media_paths, pair[1].name),
        )
        for source, _ in ordered:
            if source.is_symlink() or not source.is_file():
                raise MediaPublishError(
                    f"Refusing to publish non-regular staged artifact: {source}"
                )

        published: list[tuple[Path, Path]] = []
        try:
            for source, destination in ordered:
                if cancellation_event is not None and cancellation_event.is_set():
                    raise IngestCancellationRequested(
                        "Ingest cancelled before artifact-family publication completed"
                    )
                if archive_root is not None:
                    ensure_contained_directory(destination.parent, root=archive_root)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                YtDlpHandler._move_file_no_clobber(source, destination)
                published.append((source, destination))
                if cancellation_event is not None and cancellation_event.is_set():
                    raise IngestCancellationRequested(
                        "Ingest cancelled during artifact-family publication"
                    )
        except IngestCancellationRequested:
            rollback_errors = YtDlpHandler._rollback_published_files(published)
            if rollback_errors:
                raise MediaPublishError(
                    "Cancellation interrupted publication and rollback failed: "
                    + ", ".join(rollback_errors)
                )
            raise
        except OSError as error:
            rollback_errors = YtDlpHandler._rollback_published_files(published)
            detail = (
                f"; rollback failures: {', '.join(rollback_errors)}"
                if rollback_errors
                else ""
            )
            raise MediaPublishError(
                f"Could not publish verified staged media: {error}{detail}"
            ) from error

    @staticmethod
    def _move_file_no_clobber(source: Path, destination: Path) -> None:
        """Atomically expose one same-volume file without replacing a peer."""
        move_file_no_clobber(source, destination)

    @staticmethod
    def _rollback_published_files(
        published: list[tuple[Path, Path]],
    ) -> list[str]:
        rollback_errors: list[str] = []
        for source, destination in reversed(published):
            try:
                YtDlpHandler._move_file_no_clobber(destination, source)
            except OSError as rollback_error:
                rollback_errors.append(f"{destination}: {rollback_error}")
        return rollback_errors

    def _preserve_rejected_recoveries(
        self,
        stage_dir: Path,
        output_dir: Path,
    ) -> list[Path]:
        """Move recovery-validator rejects to a hidden, content-addressed location."""
        return self._preserve_staged_artifacts(
            self._rejected_staged_files(stage_dir),
            output_dir,
        )

    def _preserve_completed_stage(
        self,
        stage_dir: Path,
        output_dir: Path,
    ) -> list[Path]:
        """Rescue every nonempty artifact after a completed download fails downstream."""
        candidates = [
            path
            for path in Path(stage_dir).rglob('*')
            if (
                path.is_file()
                and not path.is_symlink()
                and path.stat().st_size > 0
                and path.name.lower() != '.cookies.txt'
            )
        ]
        return self._preserve_staged_artifacts(candidates, output_dir)

    def _preserve_staged_artifacts(
        self,
        candidates: list[Path],
        output_dir: Path,
    ) -> list[Path]:
        if not candidates:
            return []

        with _PUBLICATION_LOCK:
            destinations: dict[Path, Path] = {}
            reserved: set[Path] = set()
            for source in candidates:
                if source.is_symlink():
                    raise MediaPublishError(
                        f"Refusing to preserve symbolic-link artifact: {source}"
                    )
                digest = self._sha256_file(source)
                recovery_name = (
                    source.name
                    if source.name.startswith('.')
                    else f'.{source.name}'
                )
                destination = (
                    Path(output_dir)
                    / '.nodraw-originals'
                    / digest
                    / recovery_name
                )
                counter = 1
                while os.path.lexists(destination) or destination in reserved:
                    destination = destination.with_name(
                        f"{recovery_name}.{counter}"
                    )
                    counter += 1
                destinations[source] = destination
                reserved.add(destination)

            self._publish_staged_files(
                destinations,
                media_paths=set(),
                archive_root=output_dir,
            )
        published = list(destinations.values())
        for path in published:
            logger.warning(f"Preserved failed ingest outside archive indexing: {path}")
        return published

    @staticmethod
    def _sha256_file(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open('rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
        return digest.hexdigest()

    def _download_sync(self, url: str, opts: Dict) -> DownloadResult:
        """Synchronous download function"""
        # Snapshot existing files BEFORE download so error recovery only considers new files
        outtmpl_pre = opts.get('outtmpl', '')
        if isinstance(outtmpl_pre, dict):
            outtmpl_pre = outtmpl_pre.get('default', outtmpl_pre.get('', ''))
        pre_download_dir = Path(outtmpl_pre).parent if outtmpl_pre else None
        pre_existing_files = set()
        if pre_download_dir and pre_download_dir.exists():
            pre_existing_files = set(pre_download_dir.glob('*'))

        with yt_dlp.YoutubeDL(opts) as ydl:
            try:
                # Extract info and download
                info = ydl.extract_info(url, download=True)

                download_retcode = getattr(ydl, '_download_retcode', 0)
                try:
                    extraction_failed = int(download_retcode or 0) != 0
                except (TypeError, ValueError):
                    extraction_failed = bool(download_retcode)

                if info is None:
                    if extraction_failed:
                        raise RuntimeError(
                            "yt-dlp extraction failed "
                            f"(status {download_retcode})"
                        )
                    return DownloadResult(
                        file_path=None,
                        metadata={},
                        success=False,
                        error="No media found",
                        failure_kind=DownloadFailureKind.NO_MEDIA,
                    )
                if not isinstance(info, dict):
                    raise TypeError("yt-dlp returned an invalid extraction result")

                output_dir = pre_download_dir if pre_download_dir and pre_download_dir.exists() else None
                actual_path, created_files = self._resolve_downloaded_files(
                    info=info,
                    ydl=ydl,
                    output_dir=output_dir,
                    pre_existing_files=pre_existing_files
                )
                if actual_path is None and extraction_failed:
                    raise RuntimeError(
                        "yt-dlp extraction failed without a downloaded file "
                        f"(status {download_retcode})"
                    )

                # Extract useful metadata
                metadata = {
                    'title': info.get('title', 'Unknown'),
                    'uploader': info.get('uploader'),
                    'uploader_id': info.get('uploader_id'),
                    'display_id': info.get('display_id'),
                    'duration': info.get('duration'),
                    'view_count': info.get('view_count'),
                    'like_count': info.get('like_count'),
                    'description': info.get('description'),
                    'upload_date': info.get('upload_date'),
                    'webpage_url': info.get('webpage_url'),
                    'extractor': info.get('extractor'),
                    'format': info.get('format'),
                    'width': info.get('width'),
                    'height': info.get('height'),
                    'fps': info.get('fps'),
                    'vcodec': info.get('vcodec'),
                    'acodec': info.get('acodec'),
                    'filesize': info.get('filesize'),
                    'categories': info.get('categories'),
                    'tags': info.get('tags'),
                }

                # Platform-specific enrichment:
                # channel_name from uploader or channel field
                channel_name = info.get('channel') or info.get('uploader')
                if channel_name:
                    metadata['channel_name'] = channel_name

                # channel_id from channel_id or uploader_id
                channel_id = info.get('channel_id') or info.get('uploader_id')
                if channel_id:
                    metadata['channel_id'] = channel_id

                # source_tags: yt-dlp 'tags' field (distinct from user-applied tags)
                raw_tags = info.get('tags')
                if raw_tags and isinstance(raw_tags, list):
                    metadata['source_tags'] = [
                        str(t) for t in raw_tags if t
                    ]

                # upload_date: YYYYMMDD -> ISO date (YYYY-MM-DD)
                raw_date = info.get('upload_date')
                if raw_date and isinstance(raw_date, str) and len(raw_date) == 8:
                    try:
                        metadata['upload_date_iso'] = (
                            f"{raw_date[:4]}-{raw_date[4:6]}-{raw_date[6:8]}"
                        )
                    except (ValueError, IndexError):
                        pass

                # Subreddit for Reddit
                if info.get('extractor', '').lower() in ('reddit', 'redditvideo'):
                    # yt-dlp stores subreddit in various places
                    webpage_url = info.get('webpage_url', '')
                    import re as _re
                    sr_match = _re.search(r'/r/([^/]+)', url_path(webpage_url))
                    if sr_match:
                        metadata['subreddit'] = sr_match.group(1)

                # Clean None values
                metadata = {k: v for k, v in metadata.items() if v is not None}
                if output_dir and created_files:
                    metadata['files'] = [
                        str(path.relative_to(output_dir))
                        for path in created_files
                    ]

                has_media = actual_path is not None
                return DownloadResult(
                    file_path=actual_path,
                    metadata=metadata,
                    success=has_media,
                    error=None if has_media else "No media found",
                    failure_kind=(
                        None if has_media else DownloadFailureKind.NO_MEDIA
                    ),
                )

            except Exception as e:
                logger.warning(f"yt-dlp error (may be partial): {e}")
                # Check if files were downloaded despite the error (e.g., post-processing failed)
                # Handle outtmpl being either a string or dict (yt-dlp supports both)
                outtmpl = opts['outtmpl']
                if isinstance(outtmpl, dict):
                    outtmpl = outtmpl.get('default', outtmpl.get('', ''))
                output_dir = Path(outtmpl).parent if outtmpl else None

                if not output_dir or not output_dir.exists():
                    raise
                media_files = self._find_new_media_files(output_dir, pre_existing_files)
                media_files = self._validate_recovered_media_files(media_files)

                if media_files:
                    actual_path = media_files[0]
                    logger.info(f"Recovered file despite error: {actual_path}")
                    metadata = {'title': actual_path.stem, 'error_note': str(e)}
                    if output_dir:
                        metadata['files'] = [
                            str(path.relative_to(output_dir))
                            for path in media_files
                        ]
                    return DownloadResult(
                        file_path=actual_path,
                        metadata=metadata,
                        success=True
                    )
                raise

    def _validate_recovered_media_files(self, media_files: list[Path]) -> list[Path]:
        """Fully demux recovered media before treating an exception as success."""
        validated_files: list[Path] = []
        for path in media_files:
            if self._probe_recovered_media(path):
                validated_files.append(path)
                continue

            self._quarantine_recovered_media(path)

        return validated_files

    def _quarantine_recovered_mp4(self, path: Path) -> Optional[Path]:
        """Compatibility wrapper for older callers and focused MP4 tests."""
        return self._quarantine_recovered_media(path)

    def _quarantine_recovered_media(self, path: Path) -> Optional[Path]:
        """Move a rejected recovery outside recognized media extensions without deleting it."""
        quarantine_path = path.with_name(f"{path.name}.invalid")
        suffix = 1
        while os.path.lexists(quarantine_path):
            quarantine_path = path.with_name(f"{path.name}.invalid-{suffix}")
            suffix += 1

        try:
            path.rename(quarantine_path)
        except OSError as quarantine_error:
            message = (
                f"Could not quarantine invalid recovered media {path}; the only "
                f"downloaded bytes were retained for hidden recovery: {quarantine_error}"
            )
            logger.critical(message)
            raise RecoveredMediaQuarantineError(message) from quarantine_error

        logger.warning(
            f"Quarantined invalid recovered media {path} as {quarantine_path.name}"
        )
        return quarantine_path

    def _probe_recovered_mp4(self, path: Path) -> bool:
        """Compatibility wrapper for the generic recovered-media validator."""
        return self._probe_recovered_media(path, expected_stream='video')

    def _probe_recovered_media(
        self,
        path: Path,
        *,
        expected_stream: Optional[str] = None,
        cancellation_event: Optional[threading.Event] = None,
    ) -> bool:
        """Require a probeable container/stream plus a complete demux-only read.

        The filename can be misleading after a post-processing exception.  Compatibility
        and extension repair belong to MediaNormalizer, so recovery must not reject an
        intact GIF or WebM payload merely because yt-dlp left an ``.mp4`` suffix.
        """
        ffprobe = shutil.which('ffprobe')
        if not ffprobe:
            logger.error("Cannot validate recovered media because ffprobe is unavailable")
            return False

        try:
            probe = MediaNormalizer._run_process(
                [
                    ffprobe,
                    '-v', 'error',
                    '-show_entries', 'format=format_name:stream=codec_type',
                    '-of', 'json',
                    str(path),
                ],
                timeout=10,
                description=f"ffprobe recovery validation for {path.name}",
                cancellation_event=cancellation_event,
            )
        except MediaNormalizationCancelledError:
            raise
        except (OSError, MediaNormalizationError) as probe_error:
            logger.warning(f"ffprobe failed for recovered media {path}: {probe_error}")
            return False

        if probe.returncode != 0:
            detail = probe.stderr.strip()[:500]
            logger.warning(
                f"ffprobe rejected recovered media {path}"
                + (f": {detail}" if detail else "")
            )
            return False

        try:
            payload = json.loads(probe.stdout)
        except (TypeError, json.JSONDecodeError) as parse_error:
            logger.warning(f"Invalid ffprobe response for recovered media {path}: {parse_error}")
            return False

        if not isinstance(payload, dict):
            logger.warning(f"Unexpected ffprobe response for recovered media {path}")
            return False

        format_payload = payload.get('format', {})
        if not isinstance(format_payload, dict):
            format_payload = {}
        format_names = {
            name.strip().lower()
            for name in str(format_payload.get('format_name', '')).split(',')
            if name.strip()
        }
        streams = payload.get('streams', [])
        if not isinstance(streams, list):
            streams = []
        available_stream_types = {
            stream.get('codec_type')
            for stream in streams
            if isinstance(stream, dict)
            and stream.get('codec_type') in {'audio', 'video'}
        }
        if expected_stream is not None:
            stream_type = expected_stream
        elif 'video' in available_stream_types:
            stream_type = 'video'
        elif 'audio' in available_stream_types:
            stream_type = 'audio'
        else:
            stream_type = 'video'
        has_expected_stream = any(
            stream.get('codec_type') == stream_type
            for stream in streams
            if isinstance(stream, dict)
        )

        if not format_names or not has_expected_stream:
            logger.warning(
                "Recovered media probe lacked a recognized container/"
                f"{stream_type} stream: {path}"
            )
            return False

        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            logger.error("Cannot validate recovered media because ffmpeg is unavailable")
            return False

        try:
            integrity = MediaNormalizer._run_process(
                [
                    ffmpeg,
                    '-nostdin',
                    '-v', 'error',
                    '-xerror',
                    '-i', str(path),
                    '-map', f"0:{stream_type[0]}:0",
                    '-c', 'copy',
                    '-f', 'null',
                    '-',
                ],
                timeout=120,
                description=f"ffmpeg recovery integrity for {path.name}",
                cancellation_event=cancellation_event,
            )
        except MediaNormalizationCancelledError:
            raise
        except (OSError, MediaNormalizationError) as integrity_error:
            logger.warning(
                f"Recovered media integrity scan failed for {path}: {integrity_error}"
            )
            return False

        if integrity.returncode != 0:
            detail = integrity.stderr.strip()[:500]
            logger.warning(
                f"Recovered media integrity scan rejected {path}"
                + (f": {detail}" if detail else "")
            )
            return False

        return True

    def _resolve_downloaded_files(
        self,
        info: Dict,
        ydl: yt_dlp.YoutubeDL,
        output_dir: Optional[Path],
        pre_existing_files: set[Path]
    ) -> tuple[Optional[Path], list[Path]]:
        """Resolve the primary downloaded file from yt-dlp metadata and filesystem state."""
        candidate_paths: list[Path] = []
        seen_candidates: set[Path] = set()

        def add_candidate(path_str: Optional[str]) -> None:
            if not path_str:
                return
            path = Path(path_str)
            if path in seen_candidates:
                return
            seen_candidates.add(path)
            candidate_paths.append(path)

        requested_downloads = info.get('requested_downloads')
        if isinstance(requested_downloads, list):
            for download in requested_downloads:
                if isinstance(download, dict):
                    add_candidate(download.get('filepath'))

        add_candidate(info.get('_filename'))
        add_candidate(info.get('filepath'))

        try:
            add_candidate(ydl.prepare_filename(info))
        except Exception:
            pass

        for candidate in candidate_paths:
            resolved = self._resolve_existing_media_path(candidate)
            if resolved is not None:
                created_files = self._find_new_media_files(output_dir, pre_existing_files)
                if resolved not in created_files:
                    created_files = [resolved, *[path for path in created_files if path != resolved]]
                return resolved, created_files

        created_files = self._find_new_media_files(output_dir, pre_existing_files)
        if created_files:
            return created_files[0], created_files

        return None, []

    def _resolve_existing_media_path(self, candidate: Path) -> Optional[Path]:
        """Resolve a candidate yt-dlp filename to an actual media file on disk."""
        if candidate.exists() and candidate.suffix.lower() in MEDIA_EXTENSIONS and candidate.stat().st_size > 0:
            return candidate

        for ext in MEDIA_EXTENSIONS:
            test_path = candidate.with_suffix(ext)
            if test_path.exists() and test_path.stat().st_size > 0:
                return test_path

        return None

    def _find_new_media_files(
        self,
        output_dir: Optional[Path],
        pre_existing_files: set[Path]
    ) -> list[Path]:
        """Find new non-empty media files created by the current yt-dlp invocation."""
        if not output_dir or not output_dir.exists():
            return []

        all_files = set(output_dir.glob('*'))
        new_files = list(all_files - pre_existing_files)
        media_files = [
            path for path in new_files
            if path.is_file() and path.suffix.lower() in MEDIA_EXTENSIONS and path.stat().st_size > 0
        ]
        media_files.sort(key=lambda path: path.stat().st_mtime, reverse=True)
        return media_files

    def _get_time_prefix(self) -> str:
        """Get current date as YYYY-MM-DD for filename"""
        from datetime import datetime
        return datetime.now().strftime('%Y-%m-%d')

    def _write_netscape_cookies(
        self,
        path: Path,
        cookies: Dict[str, str],
        url: str,
        cookie_records: Optional[list] = None,
    ):
        """Write cookies in Netscape format for yt-dlp"""
        from urllib.parse import urlparse

        parsed = urlparse(url)
        # The exact host, without a port: cookies must still reach www. hosts.
        domain = (parsed.hostname or '').lower()

        lines = [
            "# Netscape HTTP Cookie File",
            "# This file was generated by nodraw",
            "",
        ]
        default_domain = domain if domain.startswith('.') else f".{domain}"
        records = cookie_records or [
            {"name": name, "value": value, "domain": default_domain, "path": "/"}
            for name, value in cookies.items()
        ]
        secure_flag = 'TRUE' if parsed.scheme.lower() == 'https' else 'FALSE'
        for record in records:
            getter = record.get if isinstance(record, dict) else lambda key, default=None: getattr(record, key, default)
            name = str(getter('name', ''))
            value = str(getter('value', ''))
            if not name:
                continue
            record_domain = str(getter('domain', '') or domain)
            record_path = str(getter('path', '') or '/')
            include_subdomains = 'TRUE' if record_domain.startswith('.') else 'FALSE'
            lines.append(
                f"{record_domain}\t{include_subdomains}\t{record_path}\t"
                f"{secure_flag}\t0\t{name}\t{value}"
            )
        write_private_text(path, "\n".join(lines) + "\n")

        logger.info(f"Wrote {len(cookies)} cookies to {path}")

    def _progress_hook(self, d):
        """Progress hook for yt-dlp"""
        if d['status'] == 'downloading':
            percent = d.get('_percent_str', 'N/A')
            speed = d.get('_speed_str', 'N/A')
            logger.debug(f"Downloading: {percent} at {speed}")
        elif d['status'] == 'finished':
            logger.info(f"Download finished: {d.get('filename', 'unknown')}")
