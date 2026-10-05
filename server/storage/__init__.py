"""
Storage management for archived media

Structure: ~/MediaArchive/YYYY-MM/YYYY-MM-DD-HHMMSS-platform-slug.ext
"""

from pathlib import Path
from datetime import datetime
import asyncio
import json
import hashlib
import re
from typing import Dict, Optional
from platforms import detect_platform
import logging

from sidecar_writer import DateText, render_sidecar

logger = logging.getLogger(__name__)

class StorageManager:
    """Manages file storage and organization"""

    def __init__(self, base_path: Path):
        self.base = Path(base_path)
        self.ensure_directories()

    def ensure_directories(self):
        """Create required directory structure"""
        # Simplified: just ensure base and temp exist
        directories = [
            self.base,
            self.base / "temp"
        ]

        for directory in directories:
            directory.mkdir(parents=True, exist_ok=True)

        logger.info(f"Storage initialized at {self.base}")

    def get_dated_path(self) -> Path:
        """Get path organized by YYYY-MM format"""
        now = datetime.now()
        path = self.base / f"{now.year:04d}-{now.month:02d}"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def generate_filename(self, platform: str, title: str, extension: str) -> str:
        """
        Generate filename: YYYY-MM-DD-HHMMSS-platform-slug.ext

        Args:
            platform: Platform name (twitter, youtube, etc)
            title: Original title to slugify
            extension: File extension (with or without dot)

        Returns:
            Formatted filename string
        """
        now = datetime.now()
        date_prefix = now.strftime('%Y-%m-%d-%H%M%S')  # includes seconds for uniqueness

        # Sanitize platform
        platform = platform.lower().strip() or 'unknown'
        platform = re.sub(r'[^a-z0-9]', '', platform)

        # Create slug from title
        slug = self._create_slug(title)

        # Ensure extension has dot
        if extension and not extension.startswith('.'):
            extension = f'.{extension}'

        return f"{date_prefix}-{platform}-{slug}{extension}"

    def generate_base_name(self, platform: str, title: str, stem: Optional[str] = None) -> str:
        """
        Generate base filename without extension: YYYY-MM-DD-HHMMSS-platform-slug
        Useful for outtmpl where yt-dlp adds extension

        `stem` replaces the title slug verbatim when the item has a stable name of
        its own (an X post's `user-id`, the name its media files carry).
        """
        now = datetime.now()
        date_prefix = now.strftime('%Y-%m-%d-%H%M%S')  # includes seconds for uniqueness

        platform = platform.lower().strip() or 'unknown'
        platform = re.sub(r'[^a-z0-9]', '', platform)

        slug = stem or self._create_slug(title)

        return f"{date_prefix}-{platform}-{slug}"

    def _create_slug(self, title: str, max_length: int = 150) -> str:
        """
        Create URL-safe slug from title

        - Lowercase
        - Replace spaces/underscores with hyphens
        - Remove special characters
        - Max 150 chars (safe for most filesystems, leaves room for path)
        - No trailing hyphens
        """
        if not title:
            return 'untitled'

        # Lowercase and strip
        slug = title.lower().strip()

        # Replace spaces and underscores with hyphens
        slug = re.sub(r'[\s_]+', '-', slug)

        # Remove anything that isn't alphanumeric or hyphen
        slug = re.sub(r'[^a-z0-9\-]', '', slug)

        # Collapse multiple hyphens
        slug = re.sub(r'-+', '-', slug)

        # Trim to max length
        if len(slug) > max_length:
            slug = slug[:max_length]

        # Remove trailing hyphens
        slug = slug.rstrip('-')

        return slug or 'untitled'

    async def save_context_screenshot(self, base_path: Path, png_bytes: bytes) -> Optional[Path]:
        """
        Save context screenshot alongside media file

        Args:
            base_path: Path to the media file (e.g., /path/143052-twitter-post.mp4)
            png_bytes: PNG image data as bytes

        Returns:
            Path to saved screenshot or None on failure
        """
        if not png_bytes:
            logger.warning("No screenshot data provided")
            return None

        # Create screenshot path: same as media but with .context.png
        screenshot_path = base_path.with_suffix('.context.png')

        try:
            await asyncio.to_thread(screenshot_path.write_bytes, png_bytes)
            logger.info(f"Saved context screenshot: {screenshot_path.name}")
            return screenshot_path
        except Exception as e:
            logger.error(f"Failed to save context screenshot: {e}")
            return None

    async def save_metadata(self, file_path: Path, metadata: Dict, user: Optional[Dict] = None) -> Optional[Path]:
        """
        Save metadata as .md sidecar with YAML frontmatter (Obsidian-native)

        Args:
            file_path: Path to the media file
            metadata: Dictionary of metadata to save
            user: The tags and notes the user gave the capture

        Returns:
            Path to saved metadata file or None on failure
        """
        if not file_path:
            return None

        meta_file = file_path.with_suffix('.md')
        now = datetime.now()
        download_date = metadata.get('download_date') or metadata.get('download_date_iso')

        fields = {
            "source": metadata.get('original_url'),
            "capture_id": metadata.get('capture_id'),
            "platform": metadata.get('platform'),
            "title": metadata.get('title'),
            "author": metadata.get('author'),
            "archived": now,
            "download_date": DateText(download_date) if download_date else now,
            "page_url": metadata.get('page_url'),
            "description": metadata.get('description'),
            "save_mode": metadata.get('save_mode'),
            "handler": metadata.get('handler'),
        }

        # Platform-specific source context fields (only non-empty)
        _platform_fields = [
            ('subreddit', 'subreddit'),
            ('board_name', 'board_name'),
            ('blog_name', 'blog_name'),
            ('channel_name', 'channel_name'),
            ('channel_id', 'channel_id'),
            ('artist_name', 'artist_name'),
            ('artist_display_name', 'artist_display_name'),
            ('gallery_name', 'gallery_name'),
            ('group_name', 'group_name'),
            ('album_title', 'album_title'),
            ('original_source', 'original_source'),
            ('rating', 'rating'),
        ]
        for meta_key, yaml_key in _platform_fields:
            value = metadata.get(meta_key)
            if value:
                fields[yaml_key] = str(value)

        # Source tags (from platform, not user-applied)
        source_tags = metadata.get('source_tags')
        if source_tags and isinstance(source_tags, list):
            # Cap at 50 tags to keep sidecar reasonable
            fields["source_tags"] = [str(t) for t in source_tags[:50]]

        # Upload/publish date from source platform
        upload_date = metadata.get('upload_date_iso') or metadata.get('upload_date')
        if upload_date:
            # Normalize YYYYMMDD to YYYY-MM-DD if needed
            if isinstance(upload_date, str) and len(upload_date) == 8 and upload_date.isdigit():
                upload_date = f"{upload_date[:4]}-{upload_date[4:6]}-{upload_date[6:8]}"
            fields["upload_date"] = DateText(upload_date)

        # Engagement metrics (integers)
        for metric_key in ('view_count', 'like_count', 'score'):
            value = metadata.get(metric_key)
            if value is not None:
                try:
                    fields[metric_key] = int(value)
                except (ValueError, TypeError):
                    pass

        # File info
        if file_path.exists():
            fields["file_size"] = file_path.stat().st_size

        fields.update(user or {})

        try:
            # Local import avoids a storage <-> downloader package cycle during
            # server startup (gallery_handler imports detect_platform above).
            from downloaders.runtime_safety import publish_bytes_no_clobber

            published_file = await publish_bytes_no_clobber(
                render_sidecar(fields, ["", f"![[{file_path.name}]]", ""]),
                meta_file,
                output_dir=meta_file.parent,
            )
            logger.info(f"Saved metadata: {published_file.name}")
            return published_file
        except Exception as e:
            logger.error(f"Failed to save metadata: {e}")
            return None

    def get_metadata(self, file_path: Path) -> Optional[Dict]:
        """Retrieve metadata for a file (checks .md sidecar, falls back to .json)"""
        # Primary: .md sidecar with YAML frontmatter
        md_file = file_path.with_suffix('.md')
        if md_file.exists():
            try:
                content = md_file.read_text()
                return self._parse_yaml_frontmatter(content)
            except Exception as e:
                logger.error(f"Failed to parse .md metadata: {e}")

        # Fallback: legacy .json sidecar
        json_file = file_path.with_suffix('.json')
        if json_file.exists():
            try:
                with open(json_file, 'r') as f:
                    return json.load(f)
            except Exception as e:
                logger.error(f"Failed to load .json metadata: {e}")

        return None

    def _parse_yaml_frontmatter(self, content: str) -> Dict:
        """Parse YAML frontmatter from markdown content"""
        metadata = {}
        if not content.startswith('---'):
            return metadata

        # Find end of frontmatter
        end_idx = content.find('\n---', 3)
        if end_idx == -1:
            return metadata

        frontmatter = content[4:end_idx]  # Skip initial '---\n'

        for line in frontmatter.split('\n'):
            line = line.strip()
            if not line or ':' not in line:
                continue

            key, _, value = line.partition(':')
            key = key.strip()
            value = value.strip()

            # Remove quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1].replace('\\"', '"')

            # Parse arrays like tags: ["a", "b"]
            if value.startswith('[') and value.endswith(']'):
                import ast
                try:
                    value = ast.literal_eval(value)
                except:
                    pass

            metadata[key] = value

        return metadata

    def get_storage_stats(self) -> Dict:
        """Get storage statistics across all YYYY-MM folders"""
        total_size = 0
        file_count = 0
        month_stats = {}

        # Scan all YYYY-MM directories
        for item in self.base.iterdir():
            if item.is_dir() and re.match(r'^\d{4}-\d{2}$', item.name):
                # Single-pass: count media files and sum sizes without materializing lists
                month_size = 0
                month_media_count = 0

                for f in item.iterdir():
                    if not f.is_file():
                        continue
                    month_size += f.stat().st_size
                    # Exclude metadata/sidecar files from count
                    if f.suffix not in ('.json', '.md'):
                        month_media_count += 1

                month_stats[item.name] = {
                    'count': month_media_count,
                    'size': month_size
                }

                total_size += month_size
                file_count += month_media_count

        return {
            'total_size': total_size,
            'file_count': file_count,
            'months': month_stats,
            'storage_path': str(self.base)
        }

    def cleanup_temp(self):
        """Clean temporary files"""
        temp_dir = self.base / "temp"
        if temp_dir.exists():
            for file in temp_dir.glob('*'):
                if file.is_file():
                    # Only delete files older than 1 day
                    age = datetime.now().timestamp() - file.stat().st_mtime
                    if age > 86400:  # 24 hours
                        file.unlink()
                        logger.info(f"Cleaned up temp file: {file.name}")

    def _get_file_hash(self, file_path: Path) -> str:
        """Calculate SHA256 hash of file"""
        if not file_path.exists():
            return hashlib.sha256(str(file_path).encode()).hexdigest()

        sha256_hash = hashlib.sha256()
        with open(file_path, "rb") as f:
            for byte_block in iter(lambda: f.read(4096), b""):
                sha256_hash.update(byte_block)
        return sha256_hash.hexdigest()


__all__ = ['StorageManager', 'detect_platform']
