"""Offline regressions for site-specific text/context capture behavior."""

import base64
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi import BackgroundTasks

from capture_service import CaptureIntent, CaptureService
from downloaders.base import DownloadResult


SCREENSHOT_BYTES = b"fixture context screenshot"
SCREENSHOT = "data:image/png;base64," + base64.b64encode(SCREENSHOT_BYTES).decode()


@pytest.mark.asyncio
@pytest.mark.parametrize("save_mode", ["full", "quick", "text"])
async def test_youtube_context_screenshot_matches_save_mode(storage_manager, save_mode):
    import main

    output_dir = storage_manager.get_dated_path()
    output_dir.mkdir(parents=True, exist_ok=True)
    media = output_dir / "video.mp4"
    media.write_bytes(b"fixture media")
    handler = MagicMock()
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        media, {"title": "Video title"}, published_paths=(media,)
    ))
    manager = MagicMock()
    manager.get_handler.return_value = handler
    database = AsyncMock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", storage_manager),
        patch.object(main, "downloader", manager),
    ):
        await main.process_download(
            "youtube-context", "https://www.youtube.com/watch?v=fixture", [],
            options={}, screenshot=SCREENSHOT, save_mode=save_mode,
        )

    database.update_job_failed.assert_not_awaited()
    completion = database.update_job_complete.await_args.kwargs
    assert completion["file_path"] == str(media)
    assert handler.download.await_args.kwargs["options"]["save_mode"] == save_mode
    assert Path(completion["metadata"]["sidecar_path"]).is_file()
    context = media.with_suffix(".context.png")
    if save_mode == "quick":
        assert not context.exists()
    else:
        assert context.read_bytes() == SCREENSHOT_BYTES


@pytest.mark.asyncio
@pytest.mark.parametrize("with_screenshot", [False, True])
async def test_reddit_text_mode_keeps_site_data_post_text(storage_manager, with_screenshot):
    import main

    url = "https://www.reddit.com/r/fixture/comments/abc/post/"
    post_text = "First paragraph with **Markdown**.\n\nSecond paragraph."
    intent = CaptureIntent(
        captureId="reddit-text", fingerprint="reddit-text-fixture", kind="page",
        targetUrl=url, sourcePageUrl=url, createdAt=datetime.now(timezone.utc),
        page={"title": "Post title"},
        user={"note": "Personal note", "tags": ["reading"]},
        options={
            "saveMode": "text", "platform": "reddit",
            "screenshot": SCREENSHOT if with_screenshot else "",
            "siteData": {"redditContent": {"text": post_text, "subreddit": "fixture"}},
        },
    )
    database = AsyncMock()
    manager = MagicMock()
    tasks = BackgroundTasks()
    service = CaptureService(database, main.process_download, AsyncMock())
    service._dispatch("reddit-text-job", intent, [], tasks)

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", storage_manager),
        patch.object(main, "downloader", manager),
    ):
        await tasks()

    manager.get_handler.assert_not_called()
    if not with_screenshot:
        database.update_job_complete.assert_not_awaited()
        database.update_job_failed.assert_awaited_once()
        assert 'No screenshot was captured' in database.update_job_failed.await_args.args[1]
        assert not list(storage_manager.get_dated_path().glob('*.md'))
        return
    database.update_job_failed.assert_not_awaited()
    completion = database.update_job_complete.await_args.kwargs
    body = Path(completion["metadata"]["sidecar_path"]).read_text()
    assert post_text in body
    assert 'notes: "Personal note"' in body
    assert 'tags: ["reading"]' in body
    saved_file = Path(completion["file_path"])
    assert saved_file.read_bytes() == SCREENSHOT_BYTES
    assert f"![[{saved_file.name}]]" in body
