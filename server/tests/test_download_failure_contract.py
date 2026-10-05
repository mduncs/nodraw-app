"""End-to-end job-state coverage for downloader-reported failures."""

import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from downloaders.base import DownloadFailureKind, DownloadResult


def _storage(root: Path) -> MagicMock:
    storage = MagicMock()
    storage.get_dated_path.return_value = root
    storage.generate_base_name.return_value = "capture"
    return storage


def _downloader(*handlers) -> MagicMock:
    downloader = MagicMock()
    downloader.handlers = list(handlers)
    downloader.get_handler.return_value = handlers[0]
    return downloader


def test_preservation_path_does_not_misclassify_failure_as_private_content():
    from main import _categorize_error

    message = (
        "media normalization failed; completed download preserved at "
        "/private/var/folders/example/.nodraw-originals/source"
    )
    assert _categorize_error(RuntimeError(message), message) == "server_error"
    assert _categorize_error(RuntimeError("Private video"), "Private video") == "access_denied"


def test_legacy_untyped_failure_is_terminal_but_explicit_no_media_is_not():
    legacy_failure = DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="legacy handler failure",
    )
    no_media = DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="No media found",
        failure_kind=DownloadFailureKind.NO_MEDIA,
    )

    assert legacy_failure.is_terminal_failure is True
    assert legacy_failure.is_no_media is False
    assert no_media.is_terminal_failure is False
    assert no_media.is_no_media is True


@pytest.mark.asyncio
async def test_reported_normalization_failure_is_terminal_even_with_screenshot(tmp_path):
    """A preserved hidden source must not turn into a completed screenshot job."""
    import main

    error = (
        "ffprobe is required for media normalization; completed download preserved at "
        f"{tmp_path}/.nodraw-originals/source"
    )
    handler = MagicMock(name="yt-dlp-handler")
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error=error,
        failure_kind=DownloadFailureKind.TERMINAL,
    ))
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "downloader", _downloader(handler)),
        patch.object(main, "decode_and_save_screenshot", AsyncMock()) as save_screenshot,
        patch.object(main, "append_to_index") as append_to_index,
    ):
        await main.process_download(
            job_id="job-normalization",
            url="https://example.com/video/1",
            cookies=[],
            options={},
            screenshot="data:image/png;base64,aW1hZ2U=",
            save_mode="full",
        )

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once_with(
        "job-normalization", error, "server_error"
    )
    save_screenshot.assert_not_awaited()
    append_to_index.assert_not_called()


@pytest.mark.asyncio
async def test_twitter_reported_failure_does_not_become_metadata_only_success(tmp_path):
    import main

    error = "injected media publication failure"
    handler = MagicMock(name="yt-dlp-handler")
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error=error,
        failure_kind=DownloadFailureKind.TERMINAL,
    ))
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "downloader", _downloader(handler)),
        patch.object(
            main,
            "create_twitter_metadata_fallback_sidecar",
            AsyncMock(),
        ) as metadata_fallback,
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            job_id="job-twitter",
            url="https://x.com/example/status/123",
            cookies=[],
            options={"tweetContent": {"hasVideo": True}},
            screenshot=None,
            save_mode="quick",
        )

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once_with(
        "job-twitter", error, "server_error"
    )
    metadata_fallback.assert_not_awaited()


@pytest.mark.asyncio
async def test_failed_ytdlp_fallback_preserves_its_error_instead_of_completing(tmp_path):
    import main

    gallery = MagicMock(name="gallery-handler")
    gallery.name = "gallery-dl"
    gallery.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="gallery extraction failed",
        failure_kind=DownloadFailureKind.NO_MEDIA,
    ))
    ytdlp = MagicMock(name="ytdlp-handler")
    ytdlp.name = "yt-dlp"
    ytdlp.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="yt-dlp normalization failed",
        failure_kind=DownloadFailureKind.TERMINAL,
    ))
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()
    downloader = _downloader(gallery, ytdlp)

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "downloader", downloader),
        patch.object(main, "decode_and_save_screenshot", AsyncMock()) as save_screenshot,
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            job_id="job-gallery-fallback",
            url="https://x.com/example/status/456",
            cookies=[],
            options={"tweetContent": {}},
            screenshot="data:image/png;base64,aW1hZ2U=",
            save_mode="full",
        )

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once_with(
        "job-gallery-fallback", "yt-dlp normalization failed", "server_error"
    )
    save_screenshot.assert_not_awaited()


@pytest.mark.asyncio
async def test_explicit_no_media_result_remains_screenshot_fallback_eligible(tmp_path):
    import main

    handler = MagicMock(name="yt-dlp-handler")
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="No media found",
        failure_kind=DownloadFailureKind.NO_MEDIA,
    ))
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()
    screenshot = "data:image/png;base64,aW1hZ2U="

    async def save_screenshot(_payload, path):
        path.write_bytes(b"image")
        return True

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "downloader", _downloader(handler)),
        patch.object(
            main,
            "decode_and_save_screenshot",
            AsyncMock(side_effect=save_screenshot),
        ) as save_screenshot_mock,
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            job_id="job-no-media",
            url="https://example.com/post/without-media",
            cookies=[],
            options={},
            screenshot=screenshot,
            save_mode="full",
        )

    fallback_path = tmp_path / "capture.context.png"
    save_screenshot_mock.assert_awaited_once_with(screenshot, fallback_path)
    database.update_job_complete.assert_awaited_once()
    assert database.update_job_complete.await_args.kwargs["file_path"] == str(fallback_path)
    assert database.update_job_complete.await_args.kwargs["metadata"]["reason"] == (
        "no_media_found"
    )
    assert database.update_job_complete.await_args.kwargs["metadata"]["sidecar_path"] == (
        str(tmp_path / "capture.md")
    )
    database.update_job_failed.assert_not_awaited()


@pytest.mark.asyncio
async def test_process_download_cancellation_records_durable_failed_state(tmp_path):
    import main

    started = asyncio.Event()

    async def blocked_download(**kwargs):
        started.set()
        await asyncio.Event().wait()

    handler = MagicMock(name="yt-dlp-handler")
    handler.name = "yt-dlp"
    handler.download = AsyncMock(side_effect=blocked_download)
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "downloader", _downloader(handler)),
        patch.object(main, "append_to_index"),
    ):
        task = asyncio.create_task(main.process_download(
            job_id="job-cancelled",
            url="https://example.com/video/cancelled",
            cookies=[],
            options={},
            screenshot=None,
            save_mode="full",
        ))
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once_with(
        "job-cancelled", "Download cancelled", "cancelled"
    )


def _successful_media_handler(path: Path):
    handler = MagicMock(name="yt-dlp-handler")
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        file_path=path,
        metadata={"files": [path.name]},
        success=True,
        published_paths=(path,),
    ))
    return handler


def _database_mock():
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()
    return database


async def _write_sidecar(path: Path, _metadata=None, user=None):
    sidecar = path.with_suffix(".json")
    sidecar.write_text("{}")
    return sidecar


@pytest.mark.asyncio
async def test_sidecar_failure_retracts_only_handler_manifest_media(tmp_path):
    import main

    preexisting = tmp_path / "capture.mp4"
    preexisting.write_bytes(b"pre-existing peer")
    attempt = tmp_path / "capture-2.mp4"
    attempt.write_bytes(b"this attempt")
    archive_storage = _storage(tmp_path)
    archive_storage.save_metadata = AsyncMock(side_effect=OSError("sidecar failed"))
    database = _database_mock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", archive_storage),
        patch.object(main, "downloader", _downloader(_successful_media_handler(attempt))),
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            "job-sidecar-failure",
            "https://example.com/video/sidecar-failure",
            [],
            {},
            save_mode="quick",
        )

    assert preexisting.read_bytes() == b"pre-existing peer"
    assert not attempt.exists()
    preserved = list((tmp_path / ".nodraw-originals").glob("*/.capture-2.mp4"))
    assert len(preserved) == 1
    assert preserved[0].read_bytes() == b"this attempt"
    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once()


@pytest.mark.asyncio
async def test_database_completion_failure_retracts_published_media(tmp_path):
    import main

    media = tmp_path / "database-failure.mp4"
    media.write_bytes(b"attempt")
    archive_storage = _storage(tmp_path)
    archive_storage.save_metadata = AsyncMock(side_effect=_write_sidecar)
    database = _database_mock()
    database.update_job_complete.side_effect = OSError("database unavailable")

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", archive_storage),
        patch.object(main, "downloader", _downloader(_successful_media_handler(media))),
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            "job-db-failure",
            "https://example.com/video/database-failure",
            [],
            {},
            save_mode="quick",
        )

    assert not media.exists()
    assert list((tmp_path / ".nodraw-originals").glob("*/.database-failure.mp4"))
    assert not (tmp_path / "database-failure.json").exists()
    assert list(
        (tmp_path / ".nodraw-originals").glob("*/.database-failure.json")
    )
    database.update_job_failed.assert_awaited_once()


@pytest.mark.asyncio
async def test_text_sidecar_collision_and_db_failure_preserve_existing_file(tmp_path):
    import main

    existing = tmp_path / "capture.md"
    existing.write_text("pre-existing sidecar")
    database = _database_mock()
    database.update_job_complete.side_effect = OSError("database unavailable")

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            "job-text-db-failure",
            "https://example.com/article",
            [],
            {},
            save_mode="text",
            page_title="Article",
            screenshot="data:image/png;base64,c2NyZWVuc2hvdA==",
        )

    assert existing.read_text() == "pre-existing sidecar"
    assert not (tmp_path / "capture-2.md").exists()
    preserved = list((tmp_path / ".nodraw-originals").glob("*/.capture-2.md"))
    assert len(preserved) == 1
    assert "platform:" in preserved[0].read_text()
    database.update_job_complete.assert_awaited_once()
    database.update_job_failed.assert_awaited_once()


@pytest.mark.asyncio
async def test_cancellation_racing_database_commit_keeps_completed_job_and_media(tmp_path):
    import main

    media = tmp_path / "commit-race.mp4"
    media.write_bytes(b"attempt")
    archive_storage = _storage(tmp_path)
    archive_storage.save_metadata = AsyncMock(side_effect=_write_sidecar)
    database = _database_mock()
    commit_started = asyncio.Event()
    release_commit = asyncio.Event()

    async def complete(**kwargs):
        commit_started.set()
        await release_commit.wait()

    database.update_job_complete.side_effect = complete

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", archive_storage),
        patch.object(main, "downloader", _downloader(_successful_media_handler(media))),
        patch.object(main, "append_to_index"),
    ):
        task = asyncio.create_task(main.process_download(
            "job-commit-race",
            "https://example.com/video/commit-race",
            [],
            {},
            save_mode="quick",
        ))
        await commit_started.wait()
        task.cancel()
        release_commit.set()
        with pytest.raises(asyncio.CancelledError):
            await task

    assert media.read_bytes() == b"attempt"
    database.update_job_complete.assert_awaited_once()
    assert database.update_job_complete.await_args.kwargs["metadata"]["sidecar_path"] == (
        str(tmp_path / "commit-race.json")
    )
    database.update_job_failed.assert_not_awaited()


@pytest.mark.asyncio
async def test_index_failure_cannot_flip_committed_download_to_failed(tmp_path):
    import main

    media = tmp_path / "index-failure.mp4"
    media.write_bytes(b"attempt")
    archive_storage = _storage(tmp_path)
    archive_storage.save_metadata = AsyncMock(side_effect=_write_sidecar)
    database = _database_mock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", archive_storage),
        patch.object(main, "downloader", _downloader(_successful_media_handler(media))),
        patch.object(main, "append_to_index", side_effect=OSError("index unavailable")),
    ):
        await main.process_download(
            "job-index-failure",
            "https://example.com/video/index-failure",
            [],
            {},
            save_mode="quick",
        )

    assert media.read_bytes() == b"attempt"
    database.update_job_complete.assert_awaited_once()
    assert database.update_job_complete.await_args.kwargs["metadata"]["sidecar_path"] == (
        str(tmp_path / "index-failure.json")
    )
    database.update_job_failed.assert_not_awaited()


@pytest.mark.asyncio
async def test_screenshot_mock_success_without_file_is_not_completed(tmp_path):
    import main

    handler = MagicMock(name="yt-dlp-handler")
    handler.name = "yt-dlp"
    handler.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="No media found",
        failure_kind=DownloadFailureKind.NO_MEDIA,
    ))
    database = _database_mock()

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", _storage(tmp_path)),
        patch.object(main, "downloader", _downloader(handler)),
        patch.object(main, "decode_and_save_screenshot", AsyncMock(return_value=True)),
        patch.object(main, "append_to_index"),
    ):
        await main.process_download(
            "job-missing-screenshot",
            "https://example.com/no-media",
            [],
            {},
            screenshot="data:image/png;base64,aW1hZ2U=",
            save_mode="full",
        )

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once()
