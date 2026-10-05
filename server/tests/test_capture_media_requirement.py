"""Captures must publish media, and X authors must survive every save path."""

from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

import pytest
import yaml
from fastapi import BackgroundTasks

from capture_service import CaptureIntent, CaptureService, CaptureSubmission
from database import Database
from downloaders.base import DownloadFailureKind, DownloadResult
from storage import StorageManager


SCREENSHOT = "data:image/png;base64,c2NyZWVuc2hvdA=="
POST_URL = "https://x.com/Sample_Artist/status/1000000000000000008"


def no_media_manager():
    handler = MagicMock()
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        None, {}, success=False, failure_kind=DownloadFailureKind.NO_MEDIA,
    ))
    manager = MagicMock()
    manager.get_handler.return_value = handler
    manager.handlers = [handler]
    return manager


@pytest.mark.asyncio
@pytest.mark.parametrize("mode", ["full", "quick", "text"])
async def test_no_media_no_screenshot_fails_durably_without_sidecar(tmp_path, monkeypatch, mode):
    import main

    database = Database(tmp_path / "archive.db")
    await database.initialize()
    monkeypatch.setattr(main, "db", database)
    monkeypatch.setattr(main, "storage", StorageManager(tmp_path))
    monkeypatch.setattr(main, "downloader", no_media_manager())
    service = CaptureService(database, main.process_download, AsyncMock(), archive_root=tmp_path)
    intent = CaptureIntent(
        captureId=f"missing-{mode}", fingerprint=f"missing-{mode}", kind="page",
        targetUrl=POST_URL, sourcePageUrl="https://x.com/home",
        createdAt=datetime.now(timezone.utc), page={"title": "Home / X"},
        options={"saveMode": mode, "siteData": {"tweetContent": {"text": "No media here."}}},
    )
    tasks = BackgroundTasks()
    try:
        receipt = await service.submit(CaptureSubmission(intent=intent), tasks)
        await tasks()
        job = await database.get_job(receipt.jobId)
        assert job["status"] == "failed"
        assert job["file_path"] is None
        assert not list(tmp_path.rglob("*.md"))
        failed = await service.get(intent.captureId)
        assert failed.status == "failed"
        assert failed.error == failed.message == job["error"]
        assert "retry with Full or Text mode" in failed.error
        repeated = await service.submit(CaptureSubmission(intent=intent), BackgroundTasks())
        assert repeated.disposition == "duplicate"
        assert repeated.status == "failed"
        assert repeated.error == failed.error
    finally:
        await database.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("mode", ["full", "text"])
@pytest.mark.parametrize("source", ["tweet", "intent", "url"])
async def test_feed_post_screenshot_keeps_author_in_sidecar_and_job(tmp_path, monkeypatch, mode, source):
    import main

    database = AsyncMock()
    monkeypatch.setattr(main, "db", database)
    monkeypatch.setattr(main, "storage", StorageManager(tmp_path))
    monkeypatch.setattr(main, "downloader", no_media_manager())
    author = 'Sample Artist "Display"' if source != "url" else "Sample_Artist"
    content = {"text": "A timeline post."}
    page = {"title": "Home / X"}
    if source == "tweet":
        content["userName"] = author + "\n@Sample_Artist"
    elif source == "intent":
        page["author"] = author
    options = {"tweetContent": content, "capture_intent": {"page": page}}

    await main.process_download("author", POST_URL, [], options=options,
                                page_title="Home / X", save_mode=mode, screenshot=SCREENSHOT)

    database.update_job_failed.assert_not_awaited()
    completion = database.update_job_complete.await_args.kwargs
    metadata = completion["metadata"]
    header = Path(metadata["sidecar_path"]).read_text().split("---", 2)[1]
    assert yaml.safe_load(header)["author"] == author
    assert metadata["author"] == author
    assert Path(completion["file_path"]).is_file()


@pytest.mark.parametrize("url, author", [
    ("https://twitter.com/Sample_Artist/status/123?x=1", "Sample_Artist"),
    ("https://mobile.twitter.com/abc/status/123/video/1", "abc"),
    ("https://www.x.com/abc/status/123", "abc"),
    ("https://x.com/i/status/123", ""),
    ("https://x.com/i/web/status/123", ""),
    ("https://x.com/home", ""),
    ("https://x.com.evil.test/abc/status/123", ""),
    ("https://evil.test/?url=https://x.com/abc/status/123", ""),
])
def test_twitter_author_url_fallback_requires_a_real_status_url(url, author):
    from main import _twitter_author

    assert _twitter_author({}, url) == author


@pytest.mark.asyncio
@pytest.mark.parametrize("quoted", [None, "missing", "empty"])
async def test_quoted_media_sidecar_requires_saved_media(tmp_path, quoted):
    from main import create_twitter_metadata_fallback_sidecar

    content = {"text": "No saved media."}
    if quoted:
        media = tmp_path / "quoted.jpg"
        if quoted == "empty":
            media.write_bytes(b"")
        content["quotedFiles"] = [str(media)]
    with pytest.raises((ValueError, OSError)):
        await create_twitter_metadata_fallback_sidecar(tmp_path, "post", content, POST_URL, "quick")
    assert not list(tmp_path.glob("*.md"))
