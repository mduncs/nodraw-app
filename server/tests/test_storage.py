"""
Tests for storage module
"""
import pytest
from pathlib import Path
from datetime import datetime
import re


class TestStorageManager:
    """Tests for StorageManager class"""

    def test_init_creates_directories(self, storage_manager, temp_storage_dir):
        """Storage manager creates base and temp directories"""
        assert temp_storage_dir.exists()
        assert (temp_storage_dir / "temp").exists()

    def test_get_dated_path_creates_folder(self, storage_manager):
        """get_dated_path creates YYYY-MM folder"""
        path = storage_manager.get_dated_path()
        now = datetime.now()
        expected_name = f"{now.year:04d}-{now.month:02d}"

        assert path.exists()
        assert path.name == expected_name

    def test_generate_filename_format(self, storage_manager):
        """Filename follows YYYY-MM-DD-HHMMSS-platform-slug.ext format"""
        filename = storage_manager.generate_filename(
            platform="youtube",
            title="Some Video",
            extension="mp4"
        )

        # Generic format: YYYY-MM-DD-HHMMSS-platform-slug.ext
        pattern = r"^\d{4}-\d{2}-\d{2}-\d{6}-youtube-some-video\.mp4$"
        assert re.match(pattern, filename), f"Filename {filename} doesn't match pattern"

    def test_generate_filename_twitter(self, storage_manager):
        """Twitter filename format for future context reference"""
        filename = storage_manager.generate_filename(
            platform="twitter",
            title="Hello World Test",
            extension="mp4"
        )

        # Twitter format: YYYY-MM-DD-HHMMSS-twitter-slug.ext
        pattern = r"^\d{4}-\d{2}-\d{2}-\d{6}-twitter-hello-world-test\.mp4$"
        assert re.match(pattern, filename), f"Filename {filename} doesn't match pattern"

    def test_generate_filename_sanitizes_platform(self, storage_manager):
        """Platform name is sanitized to lowercase alphanumeric"""
        filename = storage_manager.generate_filename(
            platform="Twitter.COM",
            title="test",
            extension="mp4"
        )
        assert "-twittercom-" in filename

    def test_generate_filename_handles_extension_with_dot(self, storage_manager):
        """Extension can be provided with or without dot"""
        with_dot = storage_manager.generate_filename("test", "title", ".mp4")
        without_dot = storage_manager.generate_filename("test", "title", "mp4")

        assert with_dot.endswith(".mp4")
        assert without_dot.endswith(".mp4")

    def test_generate_base_name_keeps_an_item_stem_verbatim(self, storage_manager):
        """An X post keeps its media files' `user-id` name, underscores and case intact"""
        basename = storage_manager.generate_base_name("twitter", "Home / X", stem="abc__Def-1000000000000000016")
        assert basename.endswith("-twitter-abc__Def-1000000000000000016")
        assert "home" not in basename

    def test_generate_base_name_no_extension(self, storage_manager):
        """generate_base_name returns filename without extension"""
        basename = storage_manager.generate_base_name("youtube", "Video Title")

        assert not basename.endswith(".mp4")
        assert not "." in basename.split("-")[-1]  # No extension in last segment

    def test_create_slug_basic(self, storage_manager):
        """Slug creation handles basic cases"""
        assert storage_manager._create_slug("Hello World") == "hello-world"
        assert storage_manager._create_slug("UPPERCASE") == "uppercase"
        assert storage_manager._create_slug("with_underscores") == "with-underscores"

    def test_create_slug_special_chars(self, storage_manager):
        """Slug removes special characters"""
        slug = storage_manager._create_slug("Hello! @World #2024")
        assert slug == "hello-world-2024"

    def test_create_slug_max_length(self, storage_manager):
        """Slug truncates at max_length"""
        long_title = "a" * 200
        slug = storage_manager._create_slug(long_title, max_length=150)
        assert len(slug) <= 150

    def test_create_slug_no_trailing_hyphens(self, storage_manager):
        """Slug doesn't end with hyphen"""
        slug = storage_manager._create_slug("test---")
        assert not slug.endswith("-")

    def test_create_slug_empty_returns_untitled(self, storage_manager):
        """Empty title returns 'untitled'"""
        assert storage_manager._create_slug("") == "untitled"
        assert storage_manager._create_slug("   ") == "untitled"

    def test_create_slug_collapses_hyphens(self, storage_manager):
        """Multiple hyphens collapse to one"""
        slug = storage_manager._create_slug("a - - - b")
        assert "--" not in slug
        assert slug == "a-b"

    @pytest.mark.asyncio
    async def test_save_context_screenshot(self, storage_manager, temp_storage_dir):
        """Screenshot saves with .context.png suffix"""
        media_path = temp_storage_dir / "2024-01" / "test-video.mp4"
        media_path.parent.mkdir(parents=True, exist_ok=True)
        media_path.touch()

        # Minimal valid PNG
        png_bytes = b'\x89PNG\r\n\x1a\n' + b'\x00' * 100

        result = await storage_manager.save_context_screenshot(media_path, png_bytes)

        assert result is not None
        assert result.name == "test-video.context.png"
        assert result.exists()

    @pytest.mark.asyncio
    async def test_save_context_screenshot_empty_bytes(self, storage_manager, temp_storage_dir):
        """Empty screenshot bytes returns None"""
        media_path = temp_storage_dir / "test.mp4"
        result = await storage_manager.save_context_screenshot(media_path, b"")
        assert result is None

    @pytest.mark.asyncio
    async def test_save_metadata_creates_md(self, storage_manager, temp_storage_dir):
        """Metadata saves as .md sidecar with YAML frontmatter"""
        media_path = temp_storage_dir / "test-video.mp4"
        media_path.write_bytes(b"fake video data")

        metadata = {
            "original_url": "https://example.com/video",
            "platform": "example",
            "title": "Test Video",
            "author": "testuser"
        }

        result = await storage_manager.save_metadata(media_path, metadata)

        assert result is not None
        assert result.name == "test-video.md"
        assert result.exists()

        # Verify YAML frontmatter
        content = result.read_text()
        assert content.startswith("---")
        assert 'source: "https://example.com/video"' in content
        assert "platform: example" in content
        assert "download_date:" in content
        assert 'title: "Test Video"' in content
        assert "![[test-video.mp4]]" in content

    @pytest.mark.asyncio
    async def test_save_metadata_collision_does_not_overwrite_existing_sidecar(
        self,
        storage_manager,
        temp_storage_dir,
    ):
        media_path = temp_storage_dir / "collision.mp4"
        media_path.write_bytes(b"media")
        existing = temp_storage_dir / "collision.md"
        existing.write_text("pre-existing sidecar")

        result = await storage_manager.save_metadata(
            media_path,
            {"original_url": "https://example.com/new"},
        )

        assert existing.read_text() == "pre-existing sidecar"
        assert result == temp_storage_dir / "collision-2.md"
        assert 'source: "https://example.com/new"' in result.read_text()

    def test_get_metadata_reads_md_sidecar(self, storage_manager, temp_storage_dir):
        """get_metadata reads .md sidecar with YAML frontmatter"""
        media_path = temp_storage_dir / "test.mp4"
        md_path = temp_storage_dir / "test.md"

        md_content = """---
source: https://example.com
platform: youtube
title: "Test Title"
author: "Test User"
tags: ["tag1", "tag2"]
---

![[test.mp4]]
"""
        md_path.write_text(md_content)

        result = storage_manager.get_metadata(media_path)

        assert result["source"] == "https://example.com"
        assert result["platform"] == "youtube"
        assert result["title"] == "Test Title"
        assert result["author"] == "Test User"
        assert result["tags"] == ["tag1", "tag2"]

    def test_get_metadata_falls_back_to_json(self, storage_manager, temp_storage_dir):
        """get_metadata falls back to legacy .json if no .md exists"""
        import json

        media_path = temp_storage_dir / "legacy.mp4"
        json_path = temp_storage_dir / "legacy.json"

        test_data = {"title": "Legacy", "author": "user"}
        json_path.write_text(json.dumps(test_data))

        result = storage_manager.get_metadata(media_path)

        assert result["title"] == "Legacy"
        assert result["author"] == "user"

    def test_get_metadata_missing_file(self, storage_manager, temp_storage_dir):
        """get_metadata returns None for missing sidecar"""
        media_path = temp_storage_dir / "nonexistent.mp4"
        result = storage_manager.get_metadata(media_path)
        assert result is None

    def test_get_storage_stats(self, storage_manager, temp_storage_dir):
        """Storage stats counts files correctly, excludes sidecars"""
        # Create some test files in dated folders
        month_dir = temp_storage_dir / "2024-01"
        month_dir.mkdir()
        (month_dir / "video1.mp4").write_bytes(b"x" * 1000)
        (month_dir / "video2.mp4").write_bytes(b"x" * 2000)
        (month_dir / "video1.md").write_text("---\n---\n")  # .md sidecar, shouldn't count
        (month_dir / "video1.json").write_text("{}")  # legacy .json, shouldn't count

        stats = storage_manager.get_storage_stats()

        assert stats["file_count"] == 2  # Excludes .json and .md
        assert stats["total_size"] >= 3000
        assert "2024-01" in stats["months"]

    def test_cleanup_temp_removes_old_files(self, storage_manager, temp_storage_dir):
        """cleanup_temp removes files older than 24h"""
        import os
        import time

        temp_dir = temp_storage_dir / "temp"
        old_file = temp_dir / "old.tmp"
        old_file.touch()

        # Set mtime to 2 days ago
        old_time = time.time() - (2 * 86400)
        os.utime(old_file, (old_time, old_time))

        storage_manager.cleanup_temp()

        assert not old_file.exists()


class TestPlatformDetection:
    """Tests for detect_platform function"""

    def test_platform_detection(self, platform_url_case):
        """Platform detection works for known URLs"""
        from storage import detect_platform

        url, expected = platform_url_case
        result = detect_platform(url)

        assert result == expected, f"URL {url} should detect as {expected}, got {result}"

    def test_platform_detection_with_www(self):
        """Platform detection strips www prefix"""
        from storage import detect_platform

        assert detect_platform("https://www.twitter.com/user") == "twitter"
        assert detect_platform("https://www.youtube.com/watch") == "youtube"

    def test_platform_detection_invalid_url(self):
        """Invalid URL returns 'unknown'"""
        from storage import detect_platform

        assert detect_platform("not a url") == "unknown"
        assert detect_platform("") == "unknown"
