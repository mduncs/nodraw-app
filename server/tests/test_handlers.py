"""
Tests for download handlers (yt-dlp, gallery-dl, dezoomify)
"""
import asyncio
import pytest
from pathlib import Path
import stat
from unittest.mock import patch, MagicMock, AsyncMock


class TestYtDlpHandler:
    """Tests for YtDlpHandler"""

    @pytest.fixture
    def handler(self):
        from downloaders.ytdlp_handler import YtDlpHandler
        return YtDlpHandler()

    def test_can_handle_supported_domains(self, handler):
        """Handler accepts known video platforms"""
        assert handler.can_handle("https://www.youtube.com/watch?v=abc")
        assert handler.can_handle("https://youtu.be/abc")
        assert handler.can_handle("https://twitter.com/user/status/123")
        assert handler.can_handle("https://x.com/user/status/123")
        assert handler.can_handle("https://www.instagram.com/p/abc/")
        assert handler.can_handle("https://www.tiktok.com/@user/video/123")
        assert handler.can_handle("https://vimeo.com/123456")

    def test_can_handle_excludes_gallery_sites(self, handler):
        """Handler excludes sites better handled by gallery-dl"""
        assert not handler.can_handle("https://www.flickr.com/photos/user/123")
        assert not handler.can_handle("https://www.pixiv.net/artworks/12345")
        assert not handler.can_handle("https://www.deviantart.com/user/art/title")
        assert not handler.can_handle("https://danbooru.donmai.us/posts/123")

    def test_can_handle_unknown_defaults_true(self, handler):
        """Unknown domains default to trying yt-dlp (1000+ sites)"""
        assert handler.can_handle("https://random-video-site.com/video/123")

    def test_get_time_prefix_format(self, handler):
        """Time prefix is YYYY-MM-DD format"""
        prefix = handler._get_time_prefix()
        assert len(prefix) == 10  # YYYY-MM-DD
        assert prefix.count("-") == 2

    def test_write_netscape_cookies(self, handler, temp_storage_dir, sample_cookies):
        """Cookie file written in Netscape format"""
        cookie_path = temp_storage_dir / "cookies.txt"
        handler._write_netscape_cookies(
            cookie_path,
            sample_cookies,
            "https://twitter.com/user/status/123"
        )

        content = cookie_path.read_text()

        assert "# Netscape HTTP Cookie File" in content
        assert "auth_token" in content
        assert "abc123xyz" in content
        assert ".twitter.com" in content

    def test_empty_extraction_is_explicitly_no_media(self, handler, temp_storage_dir):
        from downloaders.base import DownloadFailureKind

        class EmptyYoutubeDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                return None

        stage_dir = temp_storage_dir / ".nodraw-ingest-test"
        stage_dir.mkdir()
        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", EmptyYoutubeDL):
            result = handler._download_sync(
                "https://example.com/post/without-media",
                {"outtmpl": str(stage_dir / ".media.%(ext)s")},
            )

        assert result.success is False
        assert result.file_path is None
        assert result.failure_kind == DownloadFailureKind.NO_MEDIA
        assert result.is_no_media is True

    def test_suppressed_extraction_error_is_terminal_not_no_media(
        self,
        handler,
        temp_storage_dir,
    ):
        class FailedYoutubeDL:
            _download_retcode = 1

            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                return None

        stage_dir = temp_storage_dir / ".nodraw-ingest-failed"
        stage_dir.mkdir()
        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FailedYoutubeDL):
            with pytest.raises(RuntimeError, match="extraction failed"):
                handler._download_sync(
                    "https://example.com/post/extractor-error",
                    {"outtmpl": str(stage_dir / ".media.%(ext)s")},
                )

    def test_info_dict_without_file_honors_suppressed_error_retcode(
        self,
        handler,
        temp_storage_dir,
    ):
        class FailedYoutubeDL:
            _download_retcode = 3

            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                return {"title": "suppressed failure"}

            def prepare_filename(self, info):
                return str(temp_storage_dir / ".missing.mp4")

        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FailedYoutubeDL):
            with pytest.raises(RuntimeError, match="without a downloaded file"):
                handler._download_sync(
                    "https://example.com/post/suppressed-error",
                    {"outtmpl": str(temp_storage_dir / ".media.%(ext)s")},
                )

    def test_cookie_file_is_private_and_preserves_explicit_scope(
        self,
        handler,
        temp_storage_dir,
    ):
        cookie_path = temp_storage_dir / "scoped-cookies.txt"
        handler._write_netscape_cookies(
            cookie_path,
            {"session": "secret"},
            "https://example.com/watch",
            cookie_records=[{
                "name": "session",
                "value": "secret",
                "domain": ".media.example.com",
                "path": "/private/video",
            }],
        )

        assert stat.S_IMODE(cookie_path.stat().st_mode) == 0o600
        assert ".media.example.com\tTRUE\t/private/video" in cookie_path.read_text()

    @pytest.mark.asyncio
    async def test_youtube_watch_playlist_is_forced_to_one_video(self, handler, temp_storage_dir):
        from downloaders.base import DownloadResult

        with patch.object(handler, '_download_sync') as mock_download:
            mock_download.return_value = DownloadResult(
                file_path=temp_storage_dir / "test.mp4",
                metadata={"title": "Test"},
                success=True,
            )
            await handler.download(
                url="https://www.youtube.com/watch?v=video-id&list=playlist-id",
                cookies={},
                output_dir=temp_storage_dir,
            )

        assert mock_download.call_args.args[1]["noplaylist"] is True

    @pytest.mark.asyncio
    async def test_download_creates_cookie_file(self, handler, temp_storage_dir, sample_cookies):
        """Download creates and cleans up cookie file"""
        with patch.object(handler, '_download_sync') as mock_download:
            from downloaders.base import DownloadResult
            mock_download.return_value = DownloadResult(
                file_path=temp_storage_dir / "test.mp4",
                metadata={"title": "Test"},
                success=True
            )

            result = await handler.download(
                url="https://twitter.com/user/status/123",
                cookies=sample_cookies,
                output_dir=temp_storage_dir
            )

            # Cookie file should be cleaned up
            assert not (temp_storage_dir / ".cookies.txt").exists()


class TestGalleryDlHandler:
    """Tests for GalleryDlHandler"""

    @pytest.fixture
    def handler(self):
        from downloaders.gallery_handler import GalleryDlHandler
        return GalleryDlHandler()

    def test_can_handle_gallery_sites(self, handler):
        """Handler accepts known gallery/image sites"""
        assert handler.can_handle("https://www.flickr.com/photos/user/123")
        assert handler.can_handle("https://www.pixiv.net/artworks/12345")
        assert handler.can_handle("https://www.artstation.com/artwork/abc")
        assert handler.can_handle("https://www.deviantart.com/user/art/title")
        assert handler.can_handle("https://www.pinterest.com/pin/123")
        assert handler.can_handle("https://imgur.com/gallery/abc")

    def test_can_handle_gallery_patterns(self, handler):
        """Handler detects gallery URLs by pattern"""
        assert handler.can_handle("https://example.com/gallery/123")
        assert handler.can_handle("https://example.com/album/summer")
        assert handler.can_handle("https://example.com/portfolio/works")

    def test_can_handle_rejects_video_sites(self, handler):
        """Handler rejects pure video platforms"""
        # Note: gallery-dl CAN handle twitter/instagram but they're shared
        assert not handler.can_handle("https://www.youtube.com/watch?v=abc")
        assert not handler.can_handle("https://vimeo.com/123456")

    def test_write_cookies_file_netscape_format(self, handler, temp_storage_dir):
        """Cookies written in Netscape format for both x.com and twitter.com"""
        cookies = {"auth_token": "test123"}
        cookie_path = temp_storage_dir / "cookies.txt"

        handler._write_cookies_file(cookies, cookie_path)

        content = cookie_path.read_text()
        assert ".x.com" in content
        assert ".twitter.com" in content
        assert "auth_token\ttest123" in content

    def test_gallery_cookie_file_is_private_and_preserves_explicit_scope(
        self,
        handler,
        temp_storage_dir,
    ):
        cookie_path = temp_storage_dir / "scoped-gallery-cookies.txt"
        handler._write_cookies_file(
            {"session": "secret"},
            cookie_path,
            "https://example.com/gallery/1",
            cookie_records=[{
                "name": "session",
                "value": "secret",
                "domain": ".images.example.com",
                "path": "/members",
            }],
        )

        assert stat.S_IMODE(cookie_path.stat().st_mode) == 0o600
        assert ".images.example.com\tTRUE\t/members" in cookie_path.read_text()

    def test_browser_cookie_source_defaults_to_firefox_for_x(self, handler, monkeypatch):
        """Manual retries can use logged-in Firefox cookies when request cookies are absent."""
        monkeypatch.delenv("MEDIA_ARCHIVER_BROWSER_COOKIE_SOURCE", raising=False)
        monkeypatch.delenv("MEDIA_ARCHIVER_BROWSER_COOKIES", raising=False)

        assert handler._browser_cookie_source("https://x.com/user/status/123") == "firefox/x.com"

    def test_browser_cookie_source_can_be_disabled(self, handler, monkeypatch):
        """Browser-cookie fallback stays opt-out for privacy-sensitive setups."""
        monkeypatch.delenv("MEDIA_ARCHIVER_BROWSER_COOKIE_SOURCE", raising=False)
        monkeypatch.setenv("MEDIA_ARCHIVER_BROWSER_COOKIES", "0")

        assert handler._browser_cookie_source("https://x.com/user/status/123") is None

    def test_browser_cookie_source_skips_non_auth_domains(self, handler, monkeypatch):
        """Do not load browser cookies for arbitrary gallery downloads."""
        monkeypatch.delenv("MEDIA_ARCHIVER_BROWSER_COOKIE_SOURCE", raising=False)
        monkeypatch.delenv("MEDIA_ARCHIVER_BROWSER_COOKIES", raising=False)

        assert handler._browser_cookie_source("https://example.com/gallery/123") is None

    def test_gallery_dl_command_prefers_path_executable(self, handler, monkeypatch):
        """A launchd PATH/gallery-dl binary is a valid runtime provider."""
        monkeypatch.setattr("downloaders.gallery_handler.shutil.which", lambda name: "/tmp/gallery-dl")

        assert handler._gallery_dl_command() == ["/tmp/gallery-dl"]

    def test_gallery_dl_command_falls_back_to_python_module(self, handler, monkeypatch):
        """Dev server venvs can provide gallery-dl as a Python module."""
        monkeypatch.setattr("downloaders.gallery_handler.shutil.which", lambda name: None)
        monkeypatch.setattr("importlib.util.find_spec", lambda name: object() if name == "gallery_dl" else None)

        command = handler._gallery_dl_command()

        assert command[:2] == [__import__("sys").executable, "-m"]
        assert command[2] == "gallery_dl"

    def test_find_all_media_files(self, handler, temp_storage_dir):
        """Media file finder catches all extensions, excludes sidecars"""
        # Create various media files
        (temp_storage_dir / "image.jpg").touch()
        (temp_storage_dir / "image.png").touch()
        (temp_storage_dir / "video.mp4").touch()
        (temp_storage_dir / "audio.mp3").touch()
        (temp_storage_dir / "video.md").touch()  # .md sidecar - should be excluded
        (temp_storage_dir / "metadata.json").touch()  # legacy .json - should be excluded

        files = handler._find_all_media_files(temp_storage_dir)
        unique_files = set(files)  # Handler may return duplicates from glob patterns

        assert len(unique_files) == 4
        extensions = {f.suffix for f in unique_files}
        assert ".jpg" in extensions
        assert ".png" in extensions
        assert ".mp4" in extensions
        assert ".mp3" in extensions

    def test_prioritize_twitter_files_prefers_top_level_tweet(self, handler, temp_storage_dir):
        """Quoted-mode batches should stay anchored to the requested tweet when possible."""
        top_level = temp_storage_dir / "2026-03-11-twitter-user-111-1.jpg"
        quoted = temp_storage_dir / "2026-03-11-twitter-user-222-1.jpg"
        top_level.touch()
        quoted.touch()

        ordered = handler._prioritize_twitter_files(
            "https://x.com/user/status/111",
            [quoted, top_level]
        )

        assert ordered[0] == top_level
        assert ordered[1] == quoted

    def test_prioritize_twitter_files_leaves_batch_when_top_level_missing(self, handler, temp_storage_dir):
        """If gallery-dl only returns quoted files, keep the original batch intact."""
        first = temp_storage_dir / "2026-03-11-twitter-user-222-1.jpg"
        second = temp_storage_dir / "2026-03-11-twitter-user-333-1.jpg"
        first.touch()
        second.touch()

        ordered = handler._prioritize_twitter_files(
            "https://x.com/user/status/111",
            [first, second]
        )

        assert ordered == [first, second]
        extensions = {f.suffix for f in ordered}
        assert ".json" not in extensions
        assert ".md" not in extensions

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        ("returncode", "expected_kind"),
        [(0, "no_media"), (2, "terminal")],
    )
    async def test_empty_gallery_result_has_explicit_disposition(
        self,
        handler,
        temp_storage_dir,
        returncode,
        expected_kind,
    ):
        async def empty_stderr():
            if False:
                yield b""

        process = MagicMock()
        process.returncode = returncode
        process.stderr = empty_stderr()
        process.wait = AsyncMock()

        with (
            patch.object(handler, "_gallery_dl_command", return_value=["gallery-dl"]),
            patch(
                "downloaders.gallery_handler.asyncio.create_subprocess_exec",
                AsyncMock(return_value=process),
            ),
        ):
            result = await handler.download(
                "https://example.com/gallery/empty",
                cookies={},
                output_dir=temp_storage_dir,
            )

        assert result.success is False
        assert result.failure_kind.value == expected_kind
        assert not list(temp_storage_dir.glob(".gallery-dl-*"))

    @pytest.mark.asyncio
    async def test_nonzero_gallery_exit_never_publishes_partial_output(
        self,
        handler,
        temp_storage_dir,
    ):
        async def empty_stderr():
            if False:
                yield b""

        process = MagicMock()
        process.returncode = 2
        process.stderr = empty_stderr()
        process.wait = AsyncMock()

        async def spawn(*args, **kwargs):
            (Path(kwargs["cwd"]) / ".partial.jpg").write_bytes(b"partial")
            return process

        with (
            patch.object(handler, "_gallery_dl_command", return_value=["gallery-dl"]),
            patch(
                "downloaders.gallery_handler.asyncio.create_subprocess_exec",
                side_effect=spawn,
            ),
        ):
            result = await handler.download(
                "https://example.com/gallery/partial",
                cookies={},
                output_dir=temp_storage_dir,
            )

        assert result.success is False
        assert result.failure_kind.value == "terminal"
        assert not (temp_storage_dir / "partial.jpg").exists()
        assert not list(temp_storage_dir.glob(".nodraw-gallery-*"))

    @pytest.mark.asyncio
    async def test_zero_exit_corrupt_gallery_file_is_terminal_and_not_published(
        self,
        handler,
        temp_storage_dir,
    ):
        async def empty_stderr():
            if False:
                yield b""

        process = MagicMock()
        process.returncode = 0
        process.stderr = empty_stderr()
        process.wait = AsyncMock()

        async def spawn(*args, **kwargs):
            (Path(kwargs["cwd"]) / ".corrupt.jpg").write_bytes(b"not an image")
            return process

        with (
            patch.object(handler, "_gallery_dl_command", return_value=["gallery-dl"]),
            patch(
                "downloaders.gallery_handler.asyncio.create_subprocess_exec",
                side_effect=spawn,
            ),
        ):
            result = await handler.download(
                "https://example.com/gallery/corrupt",
                cookies={},
                output_dir=temp_storage_dir,
            )

        assert result.success is False
        assert result.failure_kind.value == "terminal"
        assert "invalid image" in result.error
        assert not (temp_storage_dir / "corrupt.jpg").exists()
        assert not list(temp_storage_dir.glob(".nodraw-gallery-*"))

    @pytest.mark.asyncio
    async def test_gallery_cancellation_terminates_reaps_and_cleans_child_stage(
        self,
        handler,
        temp_storage_dir,
    ):
        stream_started = asyncio.Event()

        class BlockingStream:
            def __aiter__(self):
                return self

            async def __anext__(self):
                stream_started.set()
                await asyncio.Event().wait()

        class Process:
            returncode = None

            def __init__(self):
                self.stderr = BlockingStream()
                self.terminate_calls = 0
                self.wait_calls = 0

            def terminate(self):
                self.terminate_calls += 1
                self.returncode = -15

            async def wait(self):
                self.wait_calls += 1
                return self.returncode

        process = Process()
        with (
            patch.object(handler, "_gallery_dl_command", return_value=["gallery-dl"]),
            patch(
                "downloaders.gallery_handler.asyncio.create_subprocess_exec",
                AsyncMock(return_value=process),
            ),
        ):
            task = asyncio.create_task(handler.download(
                "https://example.com/gallery/cancel",
                cookies={},
                output_dir=temp_storage_dir,
            ))
            await stream_started.wait()
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task

        assert process.terminate_calls == 1
        assert process.wait_calls >= 1
        assert not list(temp_storage_dir.glob(".nodraw-gallery-*"))

    def test_gallery_audio_video_validation_runs_full_cancellable_demux(
        self,
        handler,
        temp_storage_dir,
    ):
        from downloaders.gallery_handler import GalleryDlHandler

        path = temp_storage_dir / "media.webm"
        path.write_bytes(b"container bytes")
        probe = MagicMock(
            returncode=0,
            stdout='{"format":{"format_name":"matroska,webm"},'
                   '"streams":[{"codec_type":"audio"}]}',
            stderr="",
        )
        demux = MagicMock(returncode=0, stdout="", stderr="")

        with (
            patch("downloaders.gallery_handler.shutil.which", side_effect=[
                "/fake/ffprobe",
                "/fake/ffmpeg",
            ]),
            patch(
                "downloaders.gallery_handler.MediaNormalizer._run_process",
                side_effect=[probe, demux],
            ) as run_process,
        ):
            assert GalleryDlHandler._validate_downloaded_file(
                path,
                temp_storage_dir,
            ) == path.resolve()

        assert run_process.call_count == 2
        demux_command = run_process.call_args_list[1].args[0]
        assert "-xerror" in demux_command
        assert ["-map", "0:a?"] == demux_command[
            demux_command.index("-map", demux_command.index("-map") + 1):
            demux_command.index("-map", demux_command.index("-map") + 1) + 2
        ]


class TestDezoomifyHandler:
    """Tests for DezoomifyHandler (IIIF/zoomable images)"""

    @pytest.fixture
    def handler(self):
        from downloaders.dezoomify_handler import DezoomifyHandler
        # Classification tests must not depend on a native binary on the host.
        with patch('downloaders.dezoomify_handler.shutil.which', return_value='/fake/dezoomify-rs'):
            return DezoomifyHandler()

    def test_can_handle_requires_installed_binary(self, handler):
        handler.dezoomify_path = None
        assert not handler.can_handle('https://example.org/iiif/image/info.json')

    def test_can_handle_iiif_urls(self, handler):
        """Handler accepts IIIF image URLs"""
        assert handler.can_handle("https://example.org/iiif/image/123/info.json")
        assert handler.can_handle("https://library.org/images/iiif/page1")

    def test_can_handle_google_arts(self, handler):
        """Handler accepts Google Arts & Culture"""
        assert handler.can_handle("https://artsandculture.google.com/asset/starry-night/abc")

    def test_can_handle_zoomify(self, handler):
        """Handler accepts Zoomify patterns"""
        assert handler.can_handle("https://example.org/zoomify/image/ImageProperties.xml")
        assert handler.can_handle("https://example.org/deepzoom/image.dzi")

    def test_can_handle_known_institutions(self, handler):
        """Handler accepts known museum/library domains"""
        assert handler.can_handle("https://wellcomecollection.org/works/abc")
        assert handler.can_handle("https://www.davidrumsey.com/luna/servlet/detail/abc")
        assert handler.can_handle("https://gallica.bnf.fr/ark:/12345/abc")

    def test_can_handle_rejects_regular_images(self, handler):
        """Handler rejects regular image URLs"""
        assert not handler.can_handle("https://example.com/image.jpg")
        assert not handler.can_handle("https://twitter.com/user/status/123")

    def test_generate_filename_google_arts(self, handler):
        """Filename extraction for Google Arts URLs"""
        url = "https://artsandculture.google.com/asset/the-starry-night/bgEuwDxel93-Pg"
        filename = handler._generate_filename(url)

        assert "starry-night" in filename.lower() or "bgEuwDxel93-Pg" in filename

    def test_generate_filename_iiif(self, handler):
        """Filename extraction for IIIF URLs"""
        url = "https://example.org/iiif/manuscript-page-42/info.json"
        filename = handler._generate_filename(url)

        # Should use parent directory name
        assert "manuscript-page-42" in filename or "info" in filename

    def test_detect_format_iiif(self, handler):
        """Format detection for IIIF"""
        url = "https://example.org/iiif/image/info.json"
        fmt = handler._detect_format(url)
        assert fmt == "iiif"

    def test_detect_format_zoomify(self, handler):
        """Format detection for Zoomify"""
        url = "https://example.org/images/ImageProperties.xml"
        fmt = handler._detect_format(url)
        assert fmt == "zoomify"

    def test_detect_format_deepzoom(self, handler):
        """Format detection for Deep Zoom"""
        url = "https://example.org/images/photo.dzi"
        fmt = handler._detect_format(url)
        assert fmt == "deepzoom"

    @pytest.mark.asyncio
    async def test_dezoomify_cancellation_terminates_reaps_and_cleans_child_stage(
        self,
        handler,
        temp_storage_dir,
    ):
        handler.dezoomify_path = "/fake/dezoomify-rs"
        stream_started = asyncio.Event()

        class BlockingStream:
            def __aiter__(self):
                return self

            async def __anext__(self):
                stream_started.set()
                await asyncio.Event().wait()

        class Process:
            returncode = None

            def __init__(self):
                self.stdout = BlockingStream()
                self.stderr = BlockingStream()
                self.terminate_calls = 0
                self.wait_calls = 0

            def terminate(self):
                self.terminate_calls += 1
                self.returncode = -15

            async def wait(self):
                self.wait_calls += 1
                return self.returncode

        process = Process()
        with patch(
            "downloaders.dezoomify_handler.asyncio.create_subprocess_exec",
            AsyncMock(return_value=process),
        ):
            task = asyncio.create_task(handler.download(
                "https://example.org/iiif/item/info.json",
                cookies={},
                output_dir=temp_storage_dir,
            ))
            await stream_started.wait()
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task

        assert process.terminate_calls == 1
        assert process.wait_calls >= 1
        assert not list(temp_storage_dir.glob(".nodraw-dezoomify-*"))

    @pytest.mark.asyncio
    async def test_dezoomify_never_places_browser_cookie_secret_in_argv_or_logs(
        self,
        handler,
        temp_storage_dir,
        caplog,
    ):
        handler.dezoomify_path = "/fake/dezoomify-rs"

        async def empty_stream():
            if False:
                yield b""

        process = MagicMock()
        process.returncode = 2
        process.stdout = empty_stream()
        process.stderr = empty_stream()
        process.wait = AsyncMock()
        spawn = AsyncMock(return_value=process)
        secret = "cookie-value-must-not-leak"

        with patch(
            "downloaders.dezoomify_handler.asyncio.create_subprocess_exec",
            spawn,
        ):
            result = await handler.download(
                "https://example.org/iiif/item/info.json",
                cookies={"session": secret},
                output_dir=temp_storage_dir,
                options={
                    "_cookie_records": [{
                        "name": "session",
                        "value": secret,
                        "domain": ".example.org",
                        "path": "/iiif",
                    }],
                },
            )

        assert result.success is False
        assert secret not in repr(spawn.await_args.args)
        assert secret not in caplog.text

    @pytest.mark.asyncio
    async def test_dezoomify_rejects_secret_custom_header_before_spawn(
        self,
        handler,
        temp_storage_dir,
        caplog,
    ):
        handler.dezoomify_path = "/fake/dezoomify-rs"
        spawn = AsyncMock()
        secret = "bearer-secret-value"

        with patch(
            "downloaders.dezoomify_handler.asyncio.create_subprocess_exec",
            spawn,
        ):
            result = await handler.download(
                "https://example.org/iiif/item/info.json",
                cookies={},
                output_dir=temp_storage_dir,
                options={"headers": {"Authorization": f"Bearer {secret}"}},
            )

        assert result.success is False
        assert result.failure_kind.value == "terminal"
        assert "secret-bearing" in result.error
        spawn.assert_not_awaited()
        assert secret not in caplog.text


class TestHandlerRegistry:
    """Tests for handler selection logic"""

    def test_handler_priority(self):
        """Handlers checked in correct order: dezoomify > gallery-dl > yt-dlp"""
        from downloaders import DownloadManager

        manager = DownloadManager()

        # This test checks priority with all handlers available.
        manager.handlers[0].dezoomify_path = '/fake/dezoomify-rs'

        # IIIF URL should get dezoomify handler
        iiif_url = "https://example.org/iiif/image/info.json"
        handler = manager.get_handler(iiif_url)
        assert "dezoomify" in handler.name  # Could be "dezoomify" or "dezoomify-rs"

        # Flickr should get gallery-dl handler
        flickr_url = "https://www.flickr.com/photos/user/123"
        handler = manager.get_handler(flickr_url)
        assert handler.name == "gallery-dl"

        # YouTube should get yt-dlp handler
        youtube_url = "https://www.youtube.com/watch?v=abc"
        handler = manager.get_handler(youtube_url)
        assert handler.name == "yt-dlp"

    def test_fallback_to_ytdlp(self):
        """Unknown URLs fall back to yt-dlp"""
        from downloaders import DownloadManager

        manager = DownloadManager()
        unknown_url = "https://unknown-video-site.com/video/123"
        handler = manager.get_handler(unknown_url)
        assert handler.name == "yt-dlp"
