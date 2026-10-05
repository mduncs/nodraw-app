"""
gallery-dl handler for image galleries and art sites
"""

import subprocess
import asyncio
from collections import deque
import json
import os
import re
import shutil
import threading
from pathlib import Path
from typing import Dict, Optional
import logging
from platforms import FLICKR_DOMAINS, matches_domains, url_hostname, url_path
from uuid import uuid4
from .base import BaseDownloader, DownloadFailureKind, DownloadResult
from .runtime_safety import (
    ArtifactSafetyError,
    publish_staged_files,
    require_regular_nonempty,
    terminate_and_reap,
    write_private_text,
)
from .metadata_extract import (
    parse_gallery_dl_metadata_files,
    extract_source_context,
)
from storage import detect_platform
from media_normalization import (
    MediaNormalizationCancelledError,
    MediaNormalizationError,
    MediaNormalizer,
)

logger = logging.getLogger(__name__)

class GalleryDlHandler(BaseDownloader):
    """Handler for gallery-dl supported sites"""

    name = "gallery-dl"

    # Sites that gallery-dl handles well
    SUPPORTED_DOMAINS = [
        *FLICKR_DOMAINS,
        'pixiv.net',
        'artstation.com',
        'deviantart.com',
        'tumblr.com',
        'pinterest.com',
        'danbooru.donmai.us',
        'gelbooru.com',
        'instagram.com',  # Also supports Instagram
        'twitter.com',    # Can handle Twitter images better than yt-dlp for galleries
        'x.com',
        'bsky.app',       # Bluesky
        'reddit.com',     # Images + videos (needs OAuth config for rate limits)
        'imgur.com',
        'behance.net',
        'unsplash.com',
        'pexels.com',
        '500px.com',
        'weibo.com',
        'mangadex.org',
        'nhentai.net',
        'rule34.xxx',
        'safebooru.org'
    ]

    def can_handle(self, url: str) -> bool:
        """Check if gallery-dl should handle this URL"""
        path_lower = url_path(url).lower()

        # Check if it's an image gallery site
        for domain in self.SUPPORTED_DOMAINS:
            if matches_domains(url, (domain,)):
                return True

        # Check for specific patterns that indicate galleries
        gallery_patterns = [
            '/gallery/',
            '/album/',
            '/collection/',
            '/portfolio/',
            '/user/',
            '/artist/'
        ]

        return any(pattern in path_lower for pattern in gallery_patterns)

    async def download(
        self,
        url: str,
        cookies: Dict[str, str],
        output_dir: Path,
        options: Optional[Dict] = None
    ) -> DownloadResult:
        """Download media using gallery-dl"""
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        control_id = uuid4().hex
        stage_dir = output_dir / f'.nodraw-gallery-{control_id}'
        from capture_recovery import register_staging
        register_staging(stage_dir)
        stage_dir.mkdir(mode=0o700)
        process = None
        postprocess_future = None
        cancellation_event = threading.Event()

        # Generate timestamp for filename
        from datetime import datetime
        timestamp = datetime.now().strftime("%Y-%m-%d")

        # Detect platform for metadata extraction
        platform = detect_platform(url)

        # Prepare configuration
        # Filename: YYYY-MM-DD-twitter-username-tweetid-N.ext
        # - tweet_id: unique identifier (clean, no special chars)
        # - num: image number within tweet (1, 2, 3 for multi-image posts)
        # Content has colons/slashes that break paths, tweet_id is safer
        # Default filename template: generic safe format for all platforms.
        # Platform-specific templates (Twitter, Flickr, Bluesky) override below.
        is_twitter = matches_domains(url, ('twitter.com', 'x.com'))
        if is_twitter:
            default_filename = f"{timestamp}-twitter-{{user[name]}}-{{tweet_id}}-{{num}}.{{extension}}"
        else:
            default_filename = f"{timestamp}-{platform}-{{filename}}.{{extension}}"

        config = {
            "extractor": {
                "base-directory": str(stage_dir),
                "parent-directory": False,
                "directory": [],  # Flat output, no subdirectories
                "filename": default_filename,
                "skip": True,  # Skip already downloaded files
                "sleep": 1,    # Be polite to servers
                "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "retries": 3,
                "timeout": 30.0,
                "verify": True,
                "fallback": True
            },
            "output": {
                "mode": "terminal",
                "progress": True,
                "log": {
                    "level": "info"
                }
            }
        }

        # Add site-specific configurations
        if matches_domains(url, ('twitter.com', 'x.com')):
            twitter_quoted = bool(options.get('twitterQuoted')) if options else False
            config["extractor"]["twitter"] = {
                "cards": True,
                "conversations": False,
                "replies": False,
                "retweets": False,
                "quoted": twitter_quoted,
                "videos": True
            }

        if matches_domains(url, FLICKR_DOMAINS):
            # Use max_width from options, default to 8000 (8K cap), None = original
            max_width = options.get('max_width') if options else 8000
            flickr_config = {
                "videos": True
            }
            if max_width is not None:
                # gallery-dl size-max limits the maximum dimension
                flickr_config["size-max"] = max_width
                logger.info(f"Flickr: size-max set to {max_width}")
            else:
                # No limit - get true original
                # Use a very high value to effectively get original
                flickr_config["size-max"] = 99999
                logger.info("Flickr: downloading at full original resolution (no cap)")
            config["extractor"]["flickr"] = flickr_config
            # Flickr-specific filename: YYYY-MM-DD-flickr-username-photoid.ext
            config["extractor"]["filename"] = f"{timestamp}-flickr-{{user[username]}}-{{id}}.{{extension}}"

        if matches_domains(url, ('instagram.com',)):
            config["extractor"]["instagram"] = {
                "posts": True,
                "stories": True,
                "highlights": True,
                "tagged": False,
                "reels": True,
                "videos": True
            }

        if matches_domains(url, ('pixiv.net',)):
            config["extractor"]["pixiv"] = {
                "ugoira": True,  # Download animations
                "metadata": True
            }

        if matches_domains(url, ('bsky.app',)):
            config["extractor"]["bluesky"] = {
                "videos": True,
                "metadata": True
            }
            # Bluesky-specific filename: YYYY-MM-DD-bluesky-handle-postid-N.ext
            config["extractor"]["filename"] = f"{timestamp}-bluesky-{{author[handle]}}-{{post_id}}-{{num}}.{{extension}}"

        # Write cookies to Netscape-format file (gallery-dl has cache bugs with dict cookies)
        cookies_file = stage_dir / '.cookies.txt'
        browser_cookie_source = None
        config_file = stage_dir / '.gallery-dl.conf'
        try:
            if cookies:
                self._write_cookies_file(
                    cookies,
                    cookies_file,
                    url,
                    cookie_records=(options or {}).get('_cookie_records'),
                )
                config["extractor"]["cookies"] = str(cookies_file)
            else:
                browser_cookie_source = self._browser_cookie_source(url)

            # The config contains the path to a credential file and should not
            # be world-readable either.
            write_private_text(config_file, json.dumps(config, indent=2))
        except BaseException:
            await asyncio.to_thread(shutil.rmtree, stage_dir, ignore_errors=True)
            raise

        try:
            command = self._gallery_dl_command()
            if not command:
                return DownloadResult(
                    file_path=None,
                    metadata={},
                    success=False,
                    error="gallery-dl is not available in PATH or the server Python environment",
                    failure_kind=DownloadFailureKind.TERMINAL,
                )

            cmd = [
                *command,
                '--config', str(config_file),
                '--no-part',  # Don't use .part files
                '--write-metadata',  # Write .json sidecar per file for platform metadata
                url
            ]
            if browser_cookie_source:
                cmd[-1:-1] = ['--cookies-from-browser', browser_cookie_source]
                logger.info(f"Using browser cookies from {browser_cookie_source} for {url}")

            # Run gallery-dl
            logger.info(f"Running gallery-dl for {url}")
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=subprocess.DEVNULL,  # Don't capture stdout - we don't parse it
                stderr=asyncio.subprocess.PIPE,
                cwd=str(stage_dir)
            )

            # Stream stderr line-by-line while retaining only bounded diagnostics.
            stderr_lines = deque(maxlen=200)
            async for line in process.stderr:
                decoded = line.decode('utf-8', errors='ignore').rstrip()
                stderr_lines.append(decoded)
                logger.debug(f"gallery-dl: {decoded}")

            await process.wait()

            if process.returncode != 0:
                error_detail = (
                    stderr_lines[-1]
                    if stderr_lines
                    else f"gallery-dl exited with status {process.returncode}"
                )
                logger.error(f"gallery-dl failed: {error_detail}")
                return DownloadResult(
                    file_path=None,
                    metadata={},
                    success=False,
                    error=error_detail,
                    failure_kind=(
                        DownloadFailureKind.UNSUPPORTED
                        if any('unsupported url' in line.lower() for line in stderr_lines)
                        else DownloadFailureKind.TERMINAL
                    ),
                )

            discovered_files = list(self._find_all_media_files(stage_dir))
            if discovered_files:
                try:
                    loop = asyncio.get_running_loop()
                    postprocess_future = loop.run_in_executor(
                        None,
                        self._validate_and_extract_metadata,
                        discovered_files,
                        stage_dir,
                        platform,
                        cancellation_event,
                    )
                    new_files, platform_meta = await asyncio.shield(postprocess_future)
                except ArtifactSafetyError as error:
                    return DownloadResult(
                        file_path=None,
                        metadata={},
                        success=False,
                        error=str(error),
                        failure_kind=DownloadFailureKind.TERMINAL,
                    )
                new_files.sort(key=lambda x: x.stat().st_mtime, reverse=True)
                if is_twitter:
                    new_files = self._prioritize_twitter_files(url, new_files)
                logger.info(f"Found {len(new_files)} validated files after download")

                # URL-based fallback for fields not found in JSON
                url_context = extract_source_context(url, platform)
                for key, value in url_context.items():
                    if key not in platform_meta:
                        platform_meta[key] = value

                destinations = publish_staged_files(new_files, output_dir)
                published_files = [destinations[path] for path in new_files]
                metadata = {
                    'file_count': len(new_files),
                    'files': [str(path.relative_to(output_dir)) for path in published_files],
                    'extractor': 'gallery-dl',
                    **platform_meta,
                }

                return DownloadResult(
                    file_path=published_files[0],  # Return first new file as primary
                    metadata=metadata,
                    success=True,
                    published_paths=tuple(published_files),
                )
            else:
                return DownloadResult(
                    file_path=None,
                    metadata={},
                    success=False,
                    error="No files downloaded",
                    failure_kind=DownloadFailureKind.NO_MEDIA,
                )

        except asyncio.CancelledError:
            cancellation_event.set()
            await terminate_and_reap(process)
            if postprocess_future is not None and not postprocess_future.done():
                try:
                    await asyncio.shield(postprocess_future)
                except BaseException:
                    pass
            raise
        except Exception as e:
            logger.error(f"gallery-dl error: {e}")
            return DownloadResult(
                file_path=None,
                metadata={},
                success=False,
                error=str(e),
                failure_kind=DownloadFailureKind.TERMINAL,
            )
        finally:
            # Cleanup temp files
            if config_file.exists():
                config_file.unlink()
            if cookies_file.exists():
                cookies_file.unlink()
            shutil.rmtree(stage_dir, ignore_errors=True)

    def _gallery_dl_command(self) -> Optional[list[str]]:
        """Resolve gallery-dl the same way launchd/server status does."""
        executable = shutil.which('gallery-dl')
        if executable:
            return [executable]

        import importlib.util
        import sys
        if importlib.util.find_spec('gallery_dl') is not None:
            return [sys.executable, '-m', 'gallery_dl']

        return None

    def _prioritize_twitter_files(self, url: str, files: list[Path]) -> list[Path]:
        """Prefer files belonging to the requested top-level tweet."""
        top_level_tweet_id = self._extract_twitter_status_id(url)
        if not top_level_tweet_id:
            return files

        def sort_key(path: Path) -> tuple[int, str]:
            filename = path.name
            is_top_level = f"-{top_level_tweet_id}-" in filename
            return (0 if is_top_level else 1, filename)

        return sorted(files, key=sort_key)

    def _extract_twitter_status_id(self, url: str) -> Optional[str]:
        match = re.search(r'/status/(\d+)', url_path(url))
        return match.group(1) if match else None

    def _browser_cookie_source(self, url: str) -> Optional[str]:
        """Return a gallery-dl browser-cookie source for auth-heavy sites."""
        exact_source = os.environ.get("MEDIA_ARCHIVER_BROWSER_COOKIE_SOURCE", "").strip()
        if exact_source:
            return exact_source

        browser = os.environ.get("MEDIA_ARCHIVER_BROWSER_COOKIES", "firefox").strip()
        if browser.lower() in {"", "0", "false", "no", "off", "none"}:
            return None

        cookie_domain = None
        if matches_domains(url, ("x.com",)):
            cookie_domain = "x.com"
        elif matches_domains(url, ("twitter.com",)):
            cookie_domain = "twitter.com"
        elif matches_domains(url, ("instagram.com",)):
            cookie_domain = "instagram.com"

        if not cookie_domain:
            return None

        # If a caller supplied profile/keyring/container syntax, let gallery-dl
        # parse it directly rather than guessing where to insert the domain.
        if any(separator in browser for separator in ("/", ":", "+")):
            return browser
        return f"{browser}/{cookie_domain}"

    def _write_cookies_file(
        self,
        cookies: Dict,
        filepath: Path,
        url: str = "",
        cookie_records: Optional[list] = None,
    ) -> None:
        """Write cookies to Netscape-format cookies.txt file"""
        lines = ["# Netscape HTTP Cookie File"]

        # Determine domains based on URL
        domains = []
        if matches_domains(url, FLICKR_DOMAINS):
            domains = ['.flickr.com', '.staticflickr.com']
        elif matches_domains(url, ('twitter.com', 'x.com')):
            domains = ['.x.com', '.twitter.com']
        elif matches_domains(url, ('instagram.com',)):
            domains = ['.instagram.com']
        elif matches_domains(url, ('pinterest.com',)):
            domains = ['.pinterest.com']
        else:
            # Fallback: write for common domains
            domains = ['.flickr.com', '.x.com', '.twitter.com']

        if cookie_records:
            for record in cookie_records:
                getter = record.get if isinstance(record, dict) else lambda key, default=None: getattr(record, key, default)
                name = str(getter('name', ''))
                value = str(getter('value', ''))
                if not name:
                    continue
                record_domain = str(getter('domain', '') or domains[0])
                record_path = str(getter('path', '') or '/')
                tailmatch = 'TRUE' if record_domain.startswith('.') else 'FALSE'
                lines.append(
                    f"{record_domain}\t{tailmatch}\t{record_path}\tTRUE\t0\t"
                    f"{name}\t{value}"
                )
        else:
            for name, value in cookies.items():
                # Format: domain, tailmatch, path, secure, expiry, name, value
                for domain in domains:
                    lines.append(f"{domain}\tTRUE\t/\tTRUE\t0\t{name}\t{value}")
        write_private_text(filepath, "\n".join(lines) + "\n")

    @staticmethod
    def _validate_and_extract_metadata(
        discovered_files: list[Path],
        stage_dir: Path,
        platform: str,
        cancellation_event: Optional[threading.Event] = None,
    ) -> tuple[list[Path], Dict]:
        new_files = [
            GalleryDlHandler._validate_downloaded_file(
                path,
                stage_dir,
                cancellation_event,
            )
            for path in discovered_files
        ]
        platform_meta = parse_gallery_dl_metadata_files(
            stage_dir,
            platform,
            cleanup=True,
        )
        return new_files, platform_meta

    @staticmethod
    def _validate_downloaded_file(
        path: Path,
        stage_dir: Path,
        cancellation_event: Optional[threading.Event] = None,
    ) -> Path:
        """Reject empty, linked, corrupt, or streamless gallery output."""
        path = require_regular_nonempty(path, root=stage_dir)
        suffix = path.suffix.lower()
        if suffix == '.svg':
            import xml.etree.ElementTree as ElementTree

            try:
                root = ElementTree.parse(path).getroot()
            except (ElementTree.ParseError, OSError) as error:
                raise ArtifactSafetyError(
                    f"gallery-dl produced invalid SVG {path.name}: {error}"
                ) from error
            if not root.tag.lower().endswith('svg'):
                raise ArtifactSafetyError(
                    f"gallery-dl produced invalid SVG {path.name}"
                )
            return path

        if suffix in {'.jpg', '.jpeg', '.png', '.gif', '.webp'}:
            try:
                from PIL import Image

                with Image.open(path) as image:
                    image.verify()
            except Exception as error:
                raise ArtifactSafetyError(
                    f"gallery-dl produced invalid image {path.name}: {error}"
                ) from error
            return path

        ffprobe = shutil.which('ffprobe')
        if not ffprobe:
            raise ArtifactSafetyError(
                f"Cannot validate gallery media {path.name}: ffprobe is unavailable"
            )
        try:
            probe = MediaNormalizer._run_process(
                [
                    ffprobe,
                    '-v', 'error',
                    '-show_entries', 'format=format_name:stream=codec_type',
                    '-of', 'json',
                    str(path),
                ],
                timeout=20,
                description=f"gallery ffprobe for {path.name}",
                cancellation_event=cancellation_event,
            )
            payload = json.loads(probe.stdout) if probe.returncode == 0 else {}
        except MediaNormalizationCancelledError:
            raise
        except (OSError, MediaNormalizationError, json.JSONDecodeError) as error:
            raise ArtifactSafetyError(
                f"Could not validate gallery media {path.name}: {error}"
            ) from error
        if not isinstance(payload, dict):
            payload = {}
        streams = payload.get('streams', [])
        if not payload.get('format') or not any(
            isinstance(stream, dict) and stream.get('codec_type') in {'audio', 'video'}
            for stream in streams
        ):
            raise ArtifactSafetyError(
                f"gallery-dl produced invalid media {path.name}"
            )

        ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            raise ArtifactSafetyError(
                f"Cannot integrity-check gallery media {path.name}: ffmpeg is unavailable"
            )
        try:
            integrity = MediaNormalizer._run_process(
                [
                    ffmpeg,
                    '-nostdin',
                    '-v', 'error',
                    '-xerror',
                    '-i', str(path),
                    '-map', '0:v?',
                    '-map', '0:a?',
                    '-c', 'copy',
                    '-f', 'null',
                    '-',
                ],
                timeout=300,
                description=f"gallery full demux for {path.name}",
                cancellation_event=cancellation_event,
            )
        except MediaNormalizationCancelledError:
            raise
        except (OSError, MediaNormalizationError) as error:
            raise ArtifactSafetyError(
                f"Could not integrity-check gallery media {path.name}: {error}"
            ) from error
        if integrity.returncode != 0:
            detail = integrity.stderr.strip()[:500]
            raise ArtifactSafetyError(
                f"gallery-dl produced corrupt media {path.name}"
                + (f": {detail}" if detail else "")
            )
        return path

    def _get_domain_from_url(self, url: str) -> str:
        """Extract domain from URL"""
        return url_hostname(url)

    def _find_all_media_files(self, output_dir: Path) -> list:
        """Find all media files in output_dir and subdirectories"""
        media_extensions = [
            '.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg',
            '.mp4', '.webm', '.mkv', '.avi', '.mov',
            '.mp3', '.m4a', '.flac', '.wav', '.ogg'
        ]

        media_files = set()
        for ext in media_extensions:
            # rglob includes files in output_dir and nested folders.
            media_files.update(output_dir.rglob(f'*{ext}'))

        return sorted(media_files)
