"""
dezoomify-rs handler for tiled/zoomable images (IIIF, Zoomify, Google Arts & Culture, etc.)
"""

import subprocess
import asyncio
from collections import deque
import shutil
from pathlib import Path
from typing import Dict, Optional
from uuid import uuid4
import logging
from platforms import matches_domains, url_path
from .base import BaseDownloader, DownloadFailureKind, DownloadResult
from .runtime_safety import (
    ArtifactSafetyError,
    publish_staged_files,
    require_regular_nonempty,
    terminate_and_reap,
)

logger = logging.getLogger(__name__)

class DezoomifyHandler(BaseDownloader):
    """Handler for dezoomify-rs supported sites (tiled/zoomable images)"""

    name = "dezoomify-rs"

    # Sites that use tiled/zoomable images
    SUPPORTED_DOMAINS = [
        'artsandculture.google.com',  # Google Arts & Culture
        'iiif.io',                     # IIIF protocol
        'wellcomecollection.org',      # Wellcome Collection
        'davidrumsey.com',             # David Rumsey Map Collection
        'gallica.bnf.fr',              # Bibliothèque nationale de France
        'digitalcollections.nypl.org', # NYPL Digital Collections
        'loc.gov',                     # Library of Congress
        'europeana.eu',                # Europeana
        'digi.ub.uni-heidelberg.de',  # Heidelberg University Library
        'e-codices.unifr.ch',          # Virtual Manuscript Library of Switzerland
    ]

    # Patterns that indicate IIIF or zoomable images
    ZOOMABLE_PATTERNS = [
        '/iiif/',
        '/info.json',
        '/ImageProperties.xml',  # Zoomify
        '/deepzoom',             # Deep Zoom Image
        '/zoomify',
        '/dzc/',
        '/dzi/',
    ]

    def __init__(self):
        """Initialize and check for dezoomify-rs"""
        self.dezoomify_path = shutil.which('dezoomify-rs')
        if not self.dezoomify_path:
            logger.warning("dezoomify-rs not found in PATH. Install with: cargo install dezoomify-rs")
        else:
            logger.info(f"Found dezoomify-rs at {self.dezoomify_path}")

    def can_handle(self, url: str) -> bool:
        """Check if dezoomify-rs should handle this URL"""
        if not self.dezoomify_path:
            return False

        path_lower = url_path(url).lower()

        # Check for supported domains
        for domain in self.SUPPORTED_DOMAINS:
            if matches_domains(url, (domain,)):
                return True

        # Check for zoomable image patterns
        for pattern in self.ZOOMABLE_PATTERNS:
            if pattern.lower() in path_lower:
                return True

        return False

    async def download(
        self,
        url: str,
        cookies: Dict[str, str],
        output_dir: Path,
        options: Optional[Dict] = None
    ) -> DownloadResult:
        """Download tiled/zoomable image using dezoomify-rs"""

        if not self.dezoomify_path:
            return DownloadResult(
                file_path=None,
                metadata={},
                success=False,
                error="dezoomify-rs not installed. Install with: cargo install dezoomify-rs",
                failure_kind=DownloadFailureKind.TERMINAL,
            )

        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        stage_dir = output_dir / f".nodraw-dezoomify-{uuid4().hex}"
        from capture_recovery import register_staging
        register_staging(stage_dir)
        stage_dir.mkdir(mode=0o700)
        process = None
        validation_future = None

        try:
            # Generate output filename based on URL
            output_filename = self._generate_filename(url)
            staged_output_path = stage_dir / f".{output_filename}"

            # Prepare command
            cmd = [
                self.dezoomify_path,
                url,
                str(staged_output_path),
            ]

            # Add default options first
            options = options or {}

            # Resolution control:
            # - Default: ~4K (4000px) - quick reference quality
            # - Shift+click: ~8K (8000px) - detailed study
            # - Alt+click: full resolution (--largest) - archival quality
            # Min check (2000px) catches failed/placeholder downloads
            max_width = options.get('max_width', 4000)
            if max_width == 0 or max_width is None:
                cmd.append('--largest')  # Full resolution
            else:
                cmd.extend(['--max-width', str(max_width)])

            # Parallelism for faster downloads
            parallelism = options.get('parallelism', 4)
            cmd.extend(['--parallelism', str(parallelism)])

            # Max retries
            retries = options.get('retries', 3)
            cmd.extend(['--retries', str(retries)])

            # Tile cache for resumable downloads
            if options.get('tile_cache'):
                cache_dir = output_dir / '.dezoomify-cache'
                cache_dir.mkdir(exist_ok=True)
                cmd.extend(['--tile-cache', str(cache_dir)])

            # Custom headers (for authentication if needed)
            if options.get('headers'):
                for key, value in options['headers'].items():
                    if self._is_secret_header(key):
                        raise ArtifactSafetyError(
                            f"Refusing secret-bearing dezoomify header: {key}"
                        )
                    if any(character in str(key) + str(value) for character in ('\r', '\n')):
                        raise ArtifactSafetyError(
                            "Refusing malformed dezoomify custom header"
                        )
                    cmd.extend(['--header', f"{key}: {value}"])

            # dezoomify-rs only accepts headers as command-line arguments. Never
            # place browser credentials in argv (or logs), where other local
            # processes can inspect them. Public captures continue unauthenticated;
            # an auth-gated endpoint will return a normal terminal tool failure.
            if cookies:
                logger.warning(
                    "Omitting %d browser cookies because dezoomify-rs has no "
                    "credential-file input",
                    len(cookies),
                )

            # Add user agent
            cmd.extend(['--header', 'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'])

            logger.info(f"Running dezoomify-rs for {url}")
            logger.debug("dezoomify-rs command prepared with %d arguments", len(cmd))

            # Run dezoomify-rs
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(stage_dir)
            )

            # Stream output line-by-line to avoid memory buffering
            stdout_lines = deque(maxlen=200)
            stderr_lines = deque(maxlen=200)

            async def read_stream(stream, lines_list, log_func, prefix):
                async for line in stream:
                    decoded = line.decode('utf-8', errors='ignore').rstrip()
                    lines_list.append(decoded)
                    log_func(f"{prefix}: {decoded}")

            await asyncio.gather(
                read_stream(process.stdout, stdout_lines, logger.info, "dezoomify-rs"),
                read_stream(process.stderr, stderr_lines, logger.debug, "dezoomify-rs stderr")
            )

            await process.wait()
            stdout = '\n'.join(stdout_lines)
            stderr = '\n'.join(stderr_lines)

            # Check if download was successful
            if process.returncode == 0 and staged_output_path.exists():
                staged_output_path = require_regular_nonempty(
                    staged_output_path,
                    root=stage_dir,
                )
                loop = asyncio.get_running_loop()
                validation_future = loop.run_in_executor(
                    None,
                    self._inspect_downloaded_image,
                    staged_output_path,
                    options.get('min_pixels', 2000),
                )
                image_metadata = await asyncio.shield(validation_future)
                file_size = staged_output_path.stat().st_size

                # Extract metadata from output
                metadata = self._parse_metadata(stdout)
                metadata['file_size'] = file_size
                metadata['url'] = url
                metadata['extractor'] = 'dezoomify-rs'
                metadata['format'] = self._detect_format(url)

                metadata.update(image_metadata)

                destinations = publish_staged_files([staged_output_path], output_dir)
                output_path = destinations[staged_output_path]
                logger.info(f"Successfully downloaded: {output_path}")

                return DownloadResult(
                    file_path=output_path,
                    metadata=metadata,
                    success=True,
                    published_paths=(output_path,),
                )
            else:
                error_msg = stderr if stderr else "Unknown error"
                logger.error(f"dezoomify-rs failed: {error_msg}")

                return DownloadResult(
                    file_path=None,
                    metadata={'url': url},
                    success=False,
                    error=error_msg,
                    failure_kind=DownloadFailureKind.TERMINAL,
                )

        except asyncio.CancelledError:
            await terminate_and_reap(process)
            if validation_future is not None and not validation_future.done():
                try:
                    await asyncio.shield(validation_future)
                except BaseException:
                    pass
            raise
        except Exception as e:
            logger.error(f"dezoomify-rs error: {e}")
            return DownloadResult(
                file_path=None,
                metadata={'url': url},
                success=False,
                error=str(e),
                failure_kind=DownloadFailureKind.TERMINAL,
            )
        finally:
            await asyncio.to_thread(shutil.rmtree, stage_dir, ignore_errors=True)

    @staticmethod
    def _inspect_downloaded_image(path: Path, min_pixels: int) -> Dict:
        """Validate image bytes and collect dimensions outside the event loop."""
        try:
            from PIL import Image
        except ImportError as error:
            raise ArtifactSafetyError(
                "Pillow is required to validate dezoomify output"
            ) from error

        try:
            with Image.open(path) as image:
                image.verify()
            with Image.open(path) as image:
                width, height = image.size
        except Exception as error:
            raise ArtifactSafetyError(
                f"dezoomify-rs produced an invalid image: {error}"
            ) from error
        if width <= 0 or height <= 0:
            raise ArtifactSafetyError("dezoomify-rs produced an empty image canvas")

        metadata = {
            'width': width,
            'height': height,
            'resolution': f"{width}x{height}",
        }
        if min(width, height) < int(min_pixels):
            logger.warning(
                "Downloaded image small: %dx%d (min: %dpx)",
                width,
                height,
                min_pixels,
            )
            metadata['is_small'] = True
        return metadata

    @staticmethod
    def _is_secret_header(name: object) -> bool:
        """Reject credentials that dezoomify-rs would expose through argv."""
        normalized = str(name).strip().lower().replace('_', '-')
        explicit = {
            'authorization',
            'proxy-authorization',
            'cookie',
            'set-cookie',
            'x-api-key',
            'api-key',
        }
        if normalized in explicit:
            return True
        return any(
            marker in normalized
            for marker in ('auth', 'cookie', 'credential', 'secret', 'token')
        )

    def _generate_filename(self, url: str) -> str:
        """Generate appropriate filename from URL"""
        from urllib.parse import urlparse, unquote

        parsed = urlparse(url)

        # Try to extract meaningful filename from URL
        path_parts = [p for p in parsed.path.split('/') if p]

        if matches_domains(url, ('artsandculture.google.com',)):
            # Google Arts & Culture: extract asset ID
            if '/asset/' in parsed.path:
                # Format: /asset/title/assetId
                asset_parts = [p for p in path_parts if p != 'asset']
                if asset_parts:
                    filename = asset_parts[-1]  # Use asset ID
                else:
                    filename = 'google-arts-culture'
            else:
                filename = 'google-arts-culture'
        elif 'info.json' in parsed.path:
            # IIIF: use parent directory name
            if len(path_parts) > 1:
                filename = path_parts[-2]
            else:
                filename = 'iiif-image'
        elif 'ImageProperties.xml' in parsed.path:
            # Zoomify: use parent directory name
            if len(path_parts) > 1:
                filename = path_parts[-2]
            else:
                filename = 'zoomify-image'
        else:
            # Generic: use last path component
            if path_parts:
                filename = path_parts[-1].split('.')[0]
            else:
                filename = parsed.netloc.replace('.', '-')

        # Clean filename
        filename = unquote(filename)
        filename = ''.join(c if c.isalnum() or c in '-_' else '-' for c in filename)
        filename = filename[:100]  # Limit length

        # Add extension (dezoomify-rs will auto-detect, but we default to jpg)
        if not any(filename.endswith(ext) for ext in ['.jpg', '.png', '.tif', '.tiff']):
            filename += '.jpg'

        return filename

    def _detect_format(self, url: str) -> str:
        """Detect the zoomable image format from URL"""
        path_lower = url_path(url).lower()

        if matches_domains(url, ('artsandculture.google.com',)):
            return 'google-arts-culture'
        elif '/iiif/' in path_lower or 'info.json' in path_lower:
            return 'iiif'
        elif 'imageproperties.xml' in path_lower or '/zoomify' in path_lower:
            return 'zoomify'
        elif '/deepzoom' in path_lower or '.dzi' in path_lower or '/dzc/' in path_lower:
            return 'deepzoom'
        else:
            return 'unknown'

    def _parse_metadata(self, output: str) -> Dict:
        """Parse metadata from dezoomify-rs output"""
        metadata = {}

        # Look for image dimensions in output
        # dezoomify-rs typically outputs: "Image size: WIDTHxHEIGHT"
        for line in output.split('\n'):
            if 'image size' in line.lower():
                parts = line.split(':')
                if len(parts) > 1:
                    size_str = parts[1].strip()
                    if 'x' in size_str:
                        try:
                            width, height = size_str.split('x')
                            metadata['width'] = int(width.strip())
                            metadata['height'] = int(height.strip())
                            metadata['resolution'] = size_str.strip()
                        except:
                            pass

            # Look for tile count
            if 'tile' in line.lower() and any(word in line.lower() for word in ['total', 'tiles', 'count']):
                try:
                    # Extract number from line
                    import re
                    numbers = re.findall(r'\d+', line)
                    if numbers:
                        metadata['tile_count'] = int(numbers[0])
                except:
                    pass

        return metadata
