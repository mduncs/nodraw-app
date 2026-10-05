import base64
from io import BytesIO
import pytest
from pathlib import Path
from unittest.mock import patch


MINIMAL_MP4_BASE64 = """
AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMVbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAA
AAAD6AAAACgAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAj90cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAAB
AAAAAAAAACgAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAA
ABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAAoAAAAAAABAAAAAAG3bWRpYQAAACBtZGhk
AAAAAAAAAAAAAAAAAAAyAAAAAgBVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRl
b0hhbmRsZXIAAAABYm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAA
AQAAAAx1cmwgAAAAAQAAASJzdGJsAAAAvnN0c2QAAAAAAAAAAQAAAK5hdmMxAAAAAAAAAAEAAAAAAAAA
AAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDAgbGlieDI2NAAAAAAAAAAAAAAA
GP//AAAANGF2Y0MBZAAK/+EAF2dkAAqs2V7ARAAAAwAEAAADAMg8SJZYAQAGaOvjyyLA/fj4AAAAABBw
YXNwAAAAAQAAAAEAAAAUYnJ0cgAAAAAAAinoAAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAAACAAAAABxz
dHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAALFAAAAAQAAABRzdGNvAAAAAAAAAAEA
AANFAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAA
taWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDAAAAAIZnJlZQAAAs1tZGF0AAAC
rgYF//+q3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQv
TVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4u
b3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTEgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNl
PTB4MzoweDExMyBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0x
IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MSBjcW09MCBkZWFkem9uZT0y
MSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3Ro
cmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5
X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0zIGJfcHlyYW1pZD0yIGJfYWRhcHQ9
MSBiX2JpYXM9MCBkaXJlY3Q9MSB3ZWlnaHRiPTEgb3Blbl9nb3A9MCB3ZWlnaHRwPTIga2V5aW50PTI1
MCBrZXlpbnRfbWluPTI1IHNjZW5lY3V0PTQwIGludHJhX3JlZnJlc2g9MCByY19sb29rYWhlYWQ9NDAg
cmM9Y3JmIG1idHJlZT0xIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9
NCBpcF9yYXRpbz0xLjQwIGFxPTE6MS4wMACAAAAAD2WIhAAr//72c3wKa22xgQ==
"""


def _png_bytes() -> bytes:
    from PIL import Image

    output = BytesIO()
    Image.new("RGB", (2, 2), color="red").save(output, format="PNG")
    return output.getvalue()


class TestTwitterFallbacks:
    @pytest.mark.asyncio
    async def test_direct_twitter_family_uses_one_collision_suffix(
        self,
        temp_storage_dir,
    ):
        from main import download_twitter_images

        existing = temp_storage_dir / "capture-1.png"
        existing.write_bytes(b"peer")

        class Response:
            headers = {"content-type": "image/png"}
            content = _png_bytes()

            def raise_for_status(self):
                return None

        class Client:
            def __init__(self, *args, **kwargs):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

            async def get(self, *args, **kwargs):
                return Response()

        with (
            patch("httpx.AsyncClient", Client),
            patch("main.TWITTER_IMAGE_DELAY", 0),
        ):
            paths = await download_twitter_images(
                ["https://img.example/1", "https://img.example/2"],
                temp_storage_dir,
                "capture",
                {},
            )

        assert existing.read_bytes() == b"peer"
        assert [path.name for path in paths] == [
            "capture-2-1.png",
            "capture-2-2.png",
        ]
        assert not list(temp_storage_dir.glob(".nodraw-twitter-images-*"))

    @pytest.mark.asyncio
    async def test_direct_twitter_family_does_not_publish_missing_members(
        self,
        temp_storage_dir,
    ):
        from main import download_twitter_images

        class Response:
            headers = {"content-type": "image/png"}
            content = _png_bytes()

            def raise_for_status(self):
                return None

        class Client:
            def __init__(self, *args, **kwargs):
                self.calls = 0

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

            async def get(self, *args, **kwargs):
                self.calls += 1
                if self.calls == 2:
                    raise OSError("second member unavailable")
                return Response()

        with (
            patch("httpx.AsyncClient", Client),
            patch("main.TWITTER_IMAGE_DELAY", 0),
        ):
            with pytest.raises(OSError, match="second member unavailable"):
                await download_twitter_images(
                    ["https://img.example/1", "https://img.example/2"],
                    temp_storage_dir,
                    "capture",
                    {},
                )

        assert not list(temp_storage_dir.glob("capture*.png"))
        assert not list(temp_storage_dir.glob(".nodraw-twitter-images-*"))

    @pytest.mark.asyncio
    async def test_create_twitter_quoted_media_sidecar_writes_note(self, temp_storage_dir):
        from main import create_twitter_metadata_fallback_sidecar

        quoted = temp_storage_dir / "quoted.jpg"
        quoted.write_bytes(b"quoted photo")
        md_path = await create_twitter_metadata_fallback_sidecar(
            output_dir=temp_storage_dir,
            basename="2026-03-30-twitter-home-x",
            tweet_content={
                "userName": "sampleanimals\n@sampleanimals",
                "text": "A text-only fallback should still preserve the tweet.",
                "timestamp": "2026-03-30T20:54:33.000Z",
                "imageAlts": ["alt one"],
                "mediaCount": 1,
                "quotedFiles": [str(quoted)],
            },
            url="https://x.com/sampleanimals/status/1000000000000000014",
            save_mode="quick",
            title="Home / X",
            fallback_reason="no_media_found_no_screenshot"
        )

        assert md_path == temp_storage_dir / "2026-03-30-twitter-home-x.md"
        content = md_path.read_text()
        assert 'platform: twitter' in content
        assert 'author: "sampleanimals"' in content
        assert 'tweet_id: 1000000000000000014' in content
        assert 'save_mode: quick' in content
        assert 'fallback_reason: quoted_media_only' in content
        assert 'A text-only fallback should still preserve the tweet.' in content
        assert '**Image 1:** alt one' in content

    @pytest.mark.asyncio
    async def test_fallback_sidecar_counts_the_quoted_media_it_embeds(self, temp_storage_dir):
        from main import create_twitter_metadata_fallback_sidecar

        quoted = temp_storage_dir / "2026-10-02-twitter-sampledev-1000000000000000012.mp4"
        quoted.write_bytes(b"quoted video")
        md_path = await create_twitter_metadata_fallback_sidecar(
            output_dir=temp_storage_dir,
            basename="2026-10-02-230951-twitter-sampledev-1000000000000000012",
            tweet_content={"userName": "sampledev", "text": "Pocket-sized gadgets.", "mediaCount": 0,
                           "quotedFiles": [str(quoted)]},
            url="https://x.com/sampledev/status/1000000000000000012",
            save_mode="full",
            fallback_reason="no_media_found_no_screenshot",
        )

        content = md_path.read_text()
        assert 'fallback_reason: quoted_media_only' in content
        assert 'media_count: 1' in content
        assert f'![[{quoted.name}]]' in content

    @pytest.mark.asyncio
    async def test_twitter_sidecar_returns_exact_collision_path(self, temp_storage_dir):
        from main import create_twitter_sidecar

        existing = temp_storage_dir / "tweet.md"
        existing.write_text("pre-existing")
        media = temp_storage_dir / "tweet.mp4"
        media.write_bytes(b"media")

        created = await create_twitter_sidecar(
            output_dir=temp_storage_dir,
            files=[str(media)],
            tweet_content={"text": "new tweet"},
            url="https://x.com/user/status/123",
        )

        assert existing.read_text() == "pre-existing"
        assert created == temp_storage_dir / "tweet-2.md"
        assert "new tweet" in created.read_text()

    @pytest.mark.asyncio
    async def test_bluesky_sidecar_collision_is_non_clobbering(self, temp_storage_dir):
        from main import create_bluesky_sidecar

        existing = temp_storage_dir / "post.md"
        existing.write_text("pre-existing")
        media = temp_storage_dir / "post.jpg"
        media.write_bytes(b"media")

        created = await create_bluesky_sidecar(
            output_dir=temp_storage_dir,
            files=[media],
            post_content={"text": "new post"},
            url="https://bsky.app/profile/example/post/1",
            basename="post",
        )

        assert existing.read_text() == "pre-existing"
        assert created == temp_storage_dir / "post-2.md"
        assert "new post" in created.read_text()

    @pytest.mark.asyncio
    async def test_metadata_fallback_collision_is_non_clobbering(self, temp_storage_dir):
        from main import create_twitter_metadata_fallback_sidecar

        existing = temp_storage_dir / "fallback.md"
        existing.write_text("pre-existing")
        quoted = temp_storage_dir / "quoted.jpg"
        quoted.write_bytes(b"quoted photo")
        created = await create_twitter_metadata_fallback_sidecar(
            output_dir=temp_storage_dir,
            basename="fallback",
            tweet_content={"text": "fallback text", "quotedFiles": [str(quoted)]},
            url="https://x.com/user/status/99",
            save_mode="quick",
        )

        assert existing.read_text() == "pre-existing"
        assert created == temp_storage_dir / "fallback-2.md"
        assert "fallback text" in created.read_text()


class TestYtDlpRecovery:
    def test_download_sync_uses_created_media_when_prepare_filename_misses(self, temp_storage_dir):
        from downloaders.ytdlp_handler import YtDlpHandler

        handler = YtDlpHandler()
        actual_path = temp_storage_dir / "2026-03-30-twitter-sample_1video-1000000000000000015.mp4"
        misleading_path = temp_storage_dir / "2026-03-30-twitter-sample_1video-1000000000000000015.webm"

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                actual_path.write_bytes(base64.b64decode(MINIMAL_MP4_BASE64))
                return {
                    "title": "Recovered Tweet",
                    "uploader_id": "sample_1video",
                    "display_id": "1000000000000000015",
                    "extractor": "twitter",
                }

            def prepare_filename(self, info):
                return str(misleading_path)

        opts = {
            "outtmpl": str(temp_storage_dir / "%(title)s.%(ext)s")
        }

        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
            result = handler._download_sync(
                "https://x.com/sample_1video/status/1000000000000000015",
                opts
            )

        assert result.success is True
        assert result.file_path == actual_path
        assert result.metadata["files"] == [actual_path.name]

    def test_download_sync_rejects_nonempty_invalid_recovered_mp4(self, temp_storage_dir):
        from downloaders.ytdlp_handler import YtDlpHandler

        handler = YtDlpHandler()
        invalid_path = temp_storage_dir / "invalid-recovered.mp4"

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                invalid_path.write_bytes(b"not actually an mp4")
                raise RuntimeError("post-processing failed")

        opts = {"outtmpl": str(temp_storage_dir / "%(title)s.%(ext)s")}

        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
            with pytest.raises(RuntimeError, match="post-processing failed"):
                handler._download_sync("https://x.com/example/status/1", opts)

        assert not invalid_path.exists()
        quarantine_path = invalid_path.with_name(f"{invalid_path.name}.invalid")
        assert quarantine_path.read_bytes() == b"not actually an mp4"

    def test_download_sync_rejects_nonempty_invalid_recovered_audio(self, temp_storage_dir):
        from downloaders.ytdlp_handler import YtDlpHandler

        handler = YtDlpHandler()
        invalid_path = temp_storage_dir / "invalid-recovered.mp3"

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                invalid_path.write_bytes(b"ID3 but not a complete audio stream")
                raise RuntimeError("audio post-processing failed")

        opts = {"outtmpl": str(temp_storage_dir / "%(title)s.%(ext)s")}

        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
            with pytest.raises(RuntimeError, match="audio post-processing failed"):
                handler._download_sync("https://example.com/audio/1", opts)

        assert not invalid_path.exists()
        quarantine_path = invalid_path.with_name(f"{invalid_path.name}.invalid")
        assert quarantine_path.read_bytes() == b"ID3 but not a complete audio stream"

    def test_download_sync_accepts_valid_minimal_recovered_mp4(self, temp_storage_dir):
        from downloaders.ytdlp_handler import YtDlpHandler

        handler = YtDlpHandler()
        valid_path = temp_storage_dir / "valid-recovered.mp4"

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                valid_path.write_bytes(base64.b64decode(MINIMAL_MP4_BASE64))
                raise RuntimeError("post-processing failed after download")

        opts = {"outtmpl": str(temp_storage_dir / "%(title)s.%(ext)s")}

        with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
            result = handler._download_sync("https://x.com/example/status/2", opts)

        assert result.success is True
        assert result.file_path == valid_path
        assert result.metadata["files"] == [valid_path.name]
        assert result.metadata["error_note"] == "post-processing failed after download"

    def test_probe_rejects_truncated_moov_first_mp4(self, temp_storage_dir):
        from downloaders.ytdlp_handler import YtDlpHandler

        complete_media = base64.b64decode(MINIMAL_MP4_BASE64)
        assert complete_media.find(b"moov") < complete_media.find(b"mdat")
        truncated_path = temp_storage_dir / "truncated-moov-first.mp4"
        truncated_path.write_bytes(complete_media[:-146])

        assert YtDlpHandler()._probe_recovered_mp4(truncated_path) is False

    def test_missing_probe_quarantines_only_new_recovery(self, temp_storage_dir):
        from downloaders.ytdlp_handler import YtDlpHandler

        handler = YtDlpHandler()
        pre_existing_path = temp_storage_dir / "pre-existing.mp4"
        pre_existing_content = b"pre-existing file must not be touched"
        pre_existing_path.write_bytes(pre_existing_content)
        recovered_path = temp_storage_dir / "new-recovery.mp4"
        recovered_content = base64.b64decode(MINIMAL_MP4_BASE64)

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def extract_info(self, url, download=True):
                recovered_path.write_bytes(recovered_content)
                raise RuntimeError("post-processing failed without probe")

        opts = {"outtmpl": str(temp_storage_dir / "%(title)s.%(ext)s")}

        with (
            patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL),
            patch("downloaders.ytdlp_handler.shutil.which", return_value=None),
        ):
            with pytest.raises(RuntimeError, match="post-processing failed without probe"):
                handler._download_sync("https://x.com/example/status/3", opts)

        assert pre_existing_path.read_bytes() == pre_existing_content
        assert not recovered_path.exists()
        quarantine_path = recovered_path.with_name(f"{recovered_path.name}.invalid")
        assert quarantine_path.read_bytes() == recovered_content

    def test_quarantine_rename_failure_retains_only_downloaded_bytes(self, temp_storage_dir):
        from downloaders.ytdlp_handler import (
            RecoveredMediaQuarantineError,
            YtDlpHandler,
        )

        handler = YtDlpHandler()
        recovered_path = temp_storage_dir / "known-new-recovery.mp4"
        recovered_path.write_bytes(b"invalid")

        with patch.object(Path, "rename", side_effect=OSError("rename denied")):
            with pytest.raises(
                RecoveredMediaQuarantineError,
                match="bytes were retained",
            ):
                handler._quarantine_recovered_mp4(recovered_path)

        assert recovered_path.read_bytes() == b"invalid"

    def test_quarantine_hard_failure_names_watcher_visible_path(self, temp_storage_dir):
        from downloaders.ytdlp_handler import (
            RecoveredMediaQuarantineError,
            YtDlpHandler,
        )

        handler = YtDlpHandler()
        recovered_path = temp_storage_dir / "stuck-new-recovery.mp4"
        recovered_path.write_bytes(b"invalid")

        with patch.object(Path, "rename", side_effect=OSError("rename denied")):
            with pytest.raises(
                RecoveredMediaQuarantineError,
                match="bytes were retained",
            ) as raised:
                handler._quarantine_recovered_mp4(recovered_path)

        assert str(recovered_path) in str(raised.value)
        assert recovered_path.exists()
