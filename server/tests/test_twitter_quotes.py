"""Offline regressions for X GIF routing and nested quote captures."""
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from downloaders.base import DownloadResult


POST_URL = "https://x.com/outer/status/123"
GIF_URL = "https://video.twimg.com/tweet_video/loop.mp4"
QUOTES = [
    {"level": 1, "url": "https://x.com/a/status/456", "author": "A", "handle": "@a", "text": "First quote", "media": [{"kind": "image", "url": "https://pbs.twimg.com/media/a.jpg"}]},
    {"level": 2, "url": "https://x.com/b/status/789", "author": "B", "handle": "@b", "text": "Nested quote", "media": [{"kind": "gif", "url": GIF_URL}]},
]


def _capture_mocks(directory, primary_kind="yt-dlp"):
    handler = MagicMock(name=primary_kind)
    handler.name = primary_kind
    primary = directory / "outer.mp4"
    primary.write_bytes(b"fixture media")
    handler.download = AsyncMock(return_value=DownloadResult(primary, {"files": [str(primary)]}, published_paths=(primary,)))
    database = AsyncMock()
    storage = MagicMock()
    storage.get_dated_path.return_value = directory
    storage.generate_base_name.return_value = "capture"
    manager = MagicMock()
    manager.handlers = [handler]
    manager.get_handler.return_value = handler
    return database, storage, manager, handler


@pytest.mark.asyncio
async def test_x_looping_gif_downloads_derived_mp4_instead_of_post(temp_storage_dir):
    import main

    database, storage, manager, handler = _capture_mocks(temp_storage_dir)
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("gif", POST_URL, [], options={"mediaType": "gif", "tweetContent": {"text": "Loop", "hasGif": True, "gifUrl": GIF_URL}}, save_mode="quick")

    assert handler.download.await_args.kwargs["url"] == GIF_URL
    metadata = database.update_job_complete.await_args.kwargs["metadata"]
    assert metadata["original_url"] == POST_URL
    assert "Loop" in Path(metadata["sidecar_path"]).read_text()


@pytest.mark.asyncio
async def test_text_mode_keeps_post_and_quote_chain(temp_storage_dir):
    import main

    database, storage, manager, _ = _capture_mocks(temp_storage_dir)
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("text", POST_URL, [], options={"tweetContent": {"text": "Outer post text"}, "quotes": QUOTES, "user_note": "My note"}, save_mode="text", screenshot="data:image/png;base64,c2NyZWVuc2hvdA==")

    manager.get_handler.assert_not_called()
    assert storage.generate_base_name.call_args.kwargs["stem"] == "outer-123", "named after the post, not the feed tab"
    metadata = database.update_job_complete.await_args.kwargs["metadata"]
    body = Path(metadata["sidecar_path"]).read_text()
    assert "Outer post text" in body
    assert "Quotes @a → @b" in body
    assert "[\u0040a](https://x.com/a/status/456)" in body
    assert "[\u0040b](https://x.com/b/status/789)" in body
    assert "First quote" in body and "Nested quote" in body
    assert "My note" in metadata["notes"]
    assert "Quotes @a → @b" in metadata["notes"]
    assert metadata["quotes"] == QUOTES


@pytest.mark.asyncio
@pytest.mark.parametrize("primary_kind", ["direct-http", "yt-dlp", "gallery-dl"])
async def test_with_quoted_posts_downloads_media_at_every_depth(temp_storage_dir, primary_kind):
    import main

    database, storage, manager, handler = _capture_mocks(temp_storage_dir, "yt-dlp" if primary_kind == "direct-http" else primary_kind)
    quote_image = temp_storage_dir / "quote.jpg"
    quote_image.write_bytes(b"image")
    own_image = temp_storage_dir / "own.jpg"
    own_image.write_bytes(b"image")
    image_download = AsyncMock(side_effect=lambda **kwargs: [own_image] if kwargs["image_urls"] == ["https://pbs.twimg.com/media/own.jpg"] else [quote_image])
    content = {"text": "Outer"}
    if primary_kind == "direct-http":
        content["imageUrls"] = ["https://pbs.twimg.com/media/own.jpg"]
    elif primary_kind == "yt-dlp":
        content["hasVideo"] = True
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager), patch.object(main, "download_twitter_images", image_download):
        await main.process_download("quote", POST_URL, [], options={"tweetContent": content, "quotes": QUOTES, "twitterQuoted": True})

    database.update_job_failed.assert_not_awaited()
    assert any(call.kwargs["image_urls"] == [QUOTES[0]["media"][0]["url"]] for call in image_download.await_args_list)
    assert any(call.kwargs.get("url") == GIF_URL for call in handler.download.await_args_list)
    metadata = database.update_job_complete.await_args.kwargs["metadata"]
    body = Path(metadata["sidecar_path"]).read_text()
    assert f"![[{quote_image.name}]]" in body
    assert "Quotes @a → @b" in body
    assert str(quote_image) in metadata["files"]


@pytest.mark.asyncio
async def test_gallery_fallback_keeps_quote_media_and_download_options(temp_storage_dir):
    import main
    from downloaders.base import DownloadFailureKind

    database, storage, manager, gallery = _capture_mocks(temp_storage_dir, "gallery-dl")
    gallery.download.return_value = DownloadResult(None, {}, False, failure_kind=DownloadFailureKind.NO_MEDIA)
    video = temp_storage_dir / "fallback.mp4"
    video.write_bytes(b"video")
    ytdlp = MagicMock()
    ytdlp.name = "yt-dlp"
    ytdlp.download = AsyncMock(return_value=DownloadResult(video, {"files": [str(video)]}, published_paths=(video,)))
    manager.handlers = [gallery, ytdlp]
    image = temp_storage_dir / "quoted.jpg"
    image.write_bytes(b"image")
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager), patch.object(main, "download_twitter_images", AsyncMock(return_value=[image])):
        await main.process_download("fallback", POST_URL, [], options={"twitterQuoted": True, "quotes": QUOTES[:1], "tweetContent": {"text": "Outer"}, "max_width": 4096})

    database.update_job_failed.assert_not_awaited()
    assert ytdlp.download.await_args.kwargs["options"]["max_width"] == 4096
    assert ytdlp.download.await_args.kwargs["options"]["twitterQuoted"] is False
    metadata = database.update_job_complete.await_args.kwargs["metadata"]
    assert "![[quoted.jpg]]" in Path(metadata["sidecar_path"]).read_text()


@pytest.mark.asyncio
async def test_text_only_outer_with_quoted_photo_survives_no_media(temp_storage_dir):
    import main
    from downloaders.base import DownloadFailureKind

    database, storage, manager, handler = _capture_mocks(temp_storage_dir)
    handler.download.return_value = DownloadResult(None, {}, False, failure_kind=DownloadFailureKind.NO_MEDIA)
    image = temp_storage_dir / "quoted.jpg"
    image.write_bytes(b"image")
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager), patch.object(main, "download_twitter_images", AsyncMock(return_value=[image])):
        await main.process_download("outer-text", POST_URL, [], options={"twitterQuoted": True, "quotes": QUOTES[:1], "tweetContent": {"text": "Outer text", "hasVideo": False, "imageUrls": []}})

    database.update_job_failed.assert_not_awaited()
    result = database.update_job_complete.await_args.kwargs
    assert result["file_path"] == str(image)
    body = Path(result["metadata"]["sidecar_path"]).read_text()
    assert "Outer text" in body and "![[quoted.jpg]]" in body


@pytest.mark.asyncio
async def test_quoted_failure_retracts_downloaded_quote_image(temp_storage_dir):
    import main

    database, storage, manager, handler = _capture_mocks(temp_storage_dir)
    handler.download.return_value = DownloadResult(None, {}, False, error="quoted GIF unavailable")
    image = temp_storage_dir / "quoted.jpg"
    image.write_bytes(b"image")
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager), patch.object(main, "download_twitter_images", AsyncMock(return_value=[image])):
        await main.process_download("failure", POST_URL, [], options={"twitterQuoted": True, "quotes": QUOTES})

    database.update_job_complete.assert_not_awaited()
    assert "quoted GIF unavailable" in database.update_job_failed.await_args.args[1]
    assert not image.exists()


@pytest.mark.asyncio
async def test_recorded_quotes_publish_before_real_database_commit(temp_storage_dir, monkeypatch):
    import json
    import main
    from database import Database
    from sidecar_projection import read_base
    from storage import StorageManager

    database = Database(temp_storage_dir / "archive.db")
    await database.initialize()
    await database.create_job("real", POST_URL, capture_id="real-capture", fingerprint="quotes-v1", intent={"schemaVersion": 1, "captureId": "real-capture", "user": {"note": ""}})
    monkeypatch.setattr(main, "db", database)
    monkeypatch.setattr(main, "storage", StorageManager(temp_storage_dir))
    try:
        await main.process_download("real", POST_URL, [], options={"quotes": QUOTES, "tweetContent": {"text": "Outer post"}}, save_mode="text", screenshot="data:image/png;base64,c2NyZWVuc2hvdA==")
        job = await database.get_job("real")
        assert job["status"] == "completed"
        sidecar = Path(job["metadata"]["sidecar_path"])
        assert "Quotes @a → @b" in read_base(sidecar)["notes"]
        journal = json.loads(next((temp_storage_dir / ".nodraw-attempts").glob("*.json")).read_text())
        assert journal["completion"]["metadata"]["quotes"] == QUOTES
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_recorded_only_quote_never_invokes_outer_video_extractor(temp_storage_dir):
    import main

    database, storage, manager, handler = _capture_mocks(temp_storage_dir)
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("recorded", POST_URL, [], options={"quotes": QUOTES, "tweetContent": {"text": "Outer text", "media": []}}, save_mode="quick")

    handler.download.assert_not_awaited()
    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once()
    assert "No media or screenshot was saved" in database.update_job_failed.await_args.args[1]
    assert not list(temp_storage_dir.glob('*.md'))


@pytest.mark.asyncio
async def test_ytdlp_excludes_appended_quoted_videos(temp_storage_dir):
    from downloaders.base import DownloadFailureKind
    from downloaders.ytdlp_handler import YtDlpHandler

    handler = YtDlpHandler()
    with patch.object(handler, "_download_sync", return_value=DownloadResult(None, {}, success=False, failure_kind=DownloadFailureKind.NO_MEDIA)) as extract:
        await handler.download(POST_URL, {}, temp_storage_dir, options={"twitterQuoted": False, "tweetContent": {"media": [{"kind": "video", "url": "blob:local"}]}})
    assert extract.call_args.args[1]["playlist_items"] == "1:1"


def test_quote_chain_links_profile_and_date_when_x_hides_the_status_url():
    from main import twitter_quote_chain
    chain = twitter_quote_chain([
        {"level": 1, "url": "", "author": "sampledev", "handle": "@sampledev", "text": "testing a new UI", "postedAt": "2025-06-19T17:02:11.000Z"},
        {"level": 2, "url": "https://x.com/b/status/789", "handle": "@b", "text": "Nested"},
        {"level": 3, "url": "", "handle": "", "author": "", "text": "Unknown"},
    ])
    assert "Quotes @sampledev → @b → Quoted post" in chain
    assert "[@sampledev](https://x.com/sampledev) · 2025-06-19" in chain
    assert "[@b](https://x.com/b/status/789)" in chain
    assert "\nQuoted post\n" in chain


@pytest.mark.asyncio
async def test_quoted_blob_video_without_status_url_extracts_from_the_outer_post(temp_storage_dir):
    import main

    database, storage, manager, handler = _capture_mocks(temp_storage_dir)
    quotes = [{"level": 1, "url": "", "author": "sampledev", "handle": "@sampledev", "text": "testing a new UI",
               "media": [{"kind": "video", "url": "blob:https://x.com/7d2e"}]}]
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("blob", POST_URL, [], options={"tweetContent": {"text": "Outer", "media": []}, "quotes": quotes, "twitterQuoted": True})

    database.update_job_failed.assert_not_awaited()
    quoted_call = next(call for call in handler.download.await_args_list if call.kwargs["options"].get("twitterPlaylistItems"))
    assert quoted_call.kwargs["url"] == POST_URL
    assert quoted_call.kwargs["options"]["twitterPlaylistItems"] == "1:1"


@pytest.mark.asyncio
async def test_ytdlp_honours_explicit_quoted_playlist_items(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    captured = {}

    class FakeYDL:
        def __init__(self, opts):
            captured.update(opts)
        def __enter__(self):
            return self
        def __exit__(self, *exc):
            return False
        def extract_info(self, url, download=True):
            raise RuntimeError("stop after options")

    with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYDL):
        await YtDlpHandler().download(url=POST_URL, cookies={}, output_dir=temp_storage_dir,
                                      options={"twitterPlaylistItems": "2:3", "tweetContent": {"media": [{"kind": "video"}]}})
    assert captured.get("playlist_items") == "2:3"


@pytest.mark.asyncio
async def test_utc_intent_time_files_under_the_local_day(temp_storage_dir, monkeypatch):
    import time as _time
    from datetime import datetime, timezone
    import main

    monkeypatch.setenv("TZ", "America/Chicago")
    _time.tzset()
    try:
        database, storage, manager, _ = _capture_mocks(temp_storage_dir)
        evening = datetime(2026, 10, 3, 4, 13, tzinfo=timezone.utc)
        with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
            await main.process_download("tz", POST_URL, [], options={"tweetContent": {"text": "Late", "hasVideo": True}}, timestamp=evening)
        metadata = database.update_job_complete.await_args.kwargs["metadata"]
        assert metadata["download_date"].startswith("2026-10-02T23:13")
        index = (temp_storage_dir / "index.md").read_text()
        assert "## 2026-10-02" in index and "**23:13**" in index
    finally:
        monkeypatch.delenv("TZ")
        _time.tzset()


@pytest.mark.asyncio
async def test_every_gif_of_a_post_is_kept_under_the_post_name(temp_storage_dir):
    import main

    database, storage, manager, handler = _capture_mocks(temp_storage_dir)
    gifs = [f"https://video.twimg.com/tweet_video/g{n}.mp4" for n in range(4)]

    async def fetch(url, cookies, output_dir, options):
        path = output_dir / f"{options['filenameStem']}.mp4"
        path.write_bytes(b"loop")
        return DownloadResult(path, {"files": [str(path)], "title": url.rsplit("/", 1)[-1]}, published_paths=(path,))

    handler.download = AsyncMock(side_effect=fetch)
    content = {"text": "Four loops", "hasGif": True, "gifUrl": gifs[0], "media": [{"kind": "gif", "url": url} for url in gifs]}
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("gifs", POST_URL, [], options={"tweetContent": content}, page_title="outer on X", save_mode="full")

    assert [call.kwargs["url"] for call in handler.download.await_args_list] == gifs
    assert [call.kwargs["options"]["filenameStem"] for call in handler.download.await_args_list] == [
        f"twitter-outer-123-{n}" for n in range(1, 5)]
    metadata = database.update_job_complete.await_args.kwargs["metadata"]
    assert metadata["title"] == "outer on X"
    body = Path(metadata["sidecar_path"]).read_text()
    assert all(f"![[twitter-outer-123-{n}.mp4]]" in body for n in range(1, 5))


@pytest.mark.asyncio
async def test_ytdlp_names_a_bare_media_url_after_the_given_stem(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    captured = {}

    class FakeYDL:
        def __init__(self, opts):
            captured.update(opts)
        def __enter__(self):
            return self
        def __exit__(self, *exc):
            return False
        def extract_info(self, url, download=True):
            raise RuntimeError("stop after options")

    with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYDL):
        await YtDlpHandler().download(url=GIF_URL, cookies={}, output_dir=temp_storage_dir,
                                      options={"filenameStem": "twitter-outer-123-2"})
    assert captured["outtmpl"].endswith("-twitter-outer-123-2.%(ext)s")
