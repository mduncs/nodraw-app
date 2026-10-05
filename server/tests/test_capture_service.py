from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi import BackgroundTasks
from database import Database

from capture_service import (
    CaptureIntent,
    CapturePatch,
    CaptureRetry,
    CaptureRetryError,
    CaptureService,
    CaptureSubmission,
    CaptureTargetRejectedError,
    collection_capture_block_reason,
)


def make_intent(**overrides):
    data = {
        "captureId": "capture-1",
        "fingerprint": "v1-deadbeef",
        "kind": "page",
        "targetUrl": "https://example.com/post",
        "sourcePageUrl": "https://example.com/post",
        "createdAt": datetime(2026, 1, 1, tzinfo=timezone.utc),
        "page": {"title": "A post"},
    }
    data.update(overrides)
    return CaptureIntent(**data)


@pytest.mark.parametrize("url", [
    "https://x.com/home",
    "https://x.com./home",
    "https://x.com/search?q=media",
    "https://x.com/example",
    "https://mobile.twitter.com/home",
    "https://m.youtube.com/feed/subscriptions",
    "https://www.youtube.com/feed/subscriptions",
    "https://bsky.app/profile/example.test",
    "https://old.reddit.com/r/example/",
])
def test_collection_urls_are_identified_before_dispatch(url):
    assert collection_capture_block_reason(url)


@pytest.mark.parametrize("url", [
    "https://x.com/example/status/1234567890",
    "https://twitter.com/i/web/status/1234567890",
    "https://www.youtube.com/watch?v=video-id",
    "https://www.youtube.com/watch?v=video-id&list=playlist-id",
    "https://youtu.be/video-id",
    "https://bsky.app/profile/example.test/post/post-id",
    "https://www.reddit.com/r/example/comments/postid/title/",
    "https://example.com/an-ordinary-page",
])
def test_specific_item_and_ordinary_page_urls_remain_valid(url):
    assert collection_capture_block_reason(url) is None


@pytest.mark.asyncio
async def test_submit_rejects_timeline_without_creating_job_or_task():
    database = AsyncMock()
    service = CaptureService(database, AsyncMock(), AsyncMock())
    tasks = BackgroundTasks()

    with pytest.raises(CaptureTargetRejectedError, match="specific post"):
        await service.submit(
            CaptureSubmission(intent=make_intent(
                targetUrl="https://x.com/home",
                sourcePageUrl="https://x.com/home",
            )),
            tasks,
        )

    database.get_job_by_capture_id.assert_not_awaited()
    database.create_job.assert_not_awaited()
    assert len(tasks.tasks) == 0


@pytest.mark.asyncio
async def test_submit_creates_one_durable_job_and_background_task():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = None
    database.get_job_by_fingerprint.return_value = None
    service = CaptureService(database, AsyncMock(), AsyncMock())
    tasks = BackgroundTasks()

    receipt = await service.submit(
        CaptureSubmission(intent=make_intent(options={
            "siteData": {
                "tweetContent": {"text": "hello"},
                "emotionTag": "joy",
            },
            "download": {"max_width": 4096},
        })),
        tasks,
    )

    assert receipt.disposition == "accepted"
    assert receipt.status == "accepted"
    assert len(tasks.tasks) == 1
    database.create_job.assert_awaited_once()
    assert database.create_job.await_args.kwargs["capture_id"] == "capture-1"
    dispatched_options = tasks.tasks[0].kwargs["options"]
    assert dispatched_options["tweetContent"] == {"text": "hello"}
    assert dispatched_options["emotionTag"] == "joy"
    assert dispatched_options["max_width"] == 4096
    assert dispatched_options["capture_intent"]["options"]["download"] == {
        "max_width": 4096,
    }


@pytest.mark.asyncio
async def test_client_options_cannot_set_the_servers_own_keys():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = None
    database.get_job_by_fingerprint.return_value = None
    service = CaptureService(database, AsyncMock(), AsyncMock())
    tasks = BackgroundTasks()

    await service.submit(
        CaptureSubmission(intent=make_intent(
            user={"tags": ["mine"], "note": "kept"},
            options={
                "siteData": {
                    "tweetContent": {"text": "hello"},
                    "filenameStem": "../../escape",
                    "user_tags": ["forged"],
                    "capture_intent": {},
                },
                "download": {"max_width": 4096, "tile_cache": "/tmp/x", "headers": {"A": "b"}},
            },
        )),
        tasks,
    )

    options = tasks.tasks[0].kwargs["options"]
    assert options["tweetContent"] == {"text": "hello"}
    assert options["max_width"] == 4096
    for key in ("filenameStem", "tile_cache", "headers"):
        assert key not in options
    assert options["user_tags"] == ["mine"]
    assert options["capture_intent"]["captureId"] == "capture-1"


@pytest.mark.asyncio
async def test_duplicate_receipt_carries_the_date_the_copy_was_kept():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = {
        "id": "job-1",
        "capture_id": "capture-1",
        "status": "completed",
        "created_at": "2026-09-29 23:58:00",
        "completed_at": "2026-09-30 00:01:12.512000",
    }
    service = CaptureService(database, AsyncMock(), AsyncMock())

    receipt = await service.submit(CaptureSubmission(intent=make_intent()), BackgroundTasks())

    assert receipt.disposition == "duplicate"
    assert receipt.savedAt == "2026-09-30"


@pytest.mark.asyncio
async def test_repeated_capture_id_returns_truthful_duplicate_receipt():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = {
        "id": "job-1",
        "capture_id": "capture-1",
        "status": "completed",
    }
    service = CaptureService(database, AsyncMock(), AsyncMock())

    receipt = await service.submit(
        CaptureSubmission(intent=make_intent()),
        BackgroundTasks(),
    )

    assert receipt.disposition == "duplicate"
    assert receipt.status == "saved"
    database.create_job.assert_not_awaited()


@pytest.mark.asyncio
async def test_same_fingerprint_collapses_different_capture_ids():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = None
    database.get_job_by_fingerprint.return_value = {
        "id": "job-original",
        "capture_id": "capture-original",
        "status": "downloading",
    }
    service = CaptureService(database, AsyncMock(), AsyncMock())

    receipt = await service.submit(
        CaptureSubmission(intent=make_intent(captureId="capture-new")),
        BackgroundTasks(),
    )

    assert receipt.jobId == "job-original"
    assert receipt.captureId == "capture-original"
    assert receipt.disposition == "duplicate"
    assert receipt.status == "processing"


@pytest.mark.asyncio
async def test_insert_race_resolves_to_winning_fingerprint_receipt():
    database = AsyncMock()
    database.get_job_by_capture_id.side_effect = [None, None]
    database.get_job_by_fingerprint.side_effect = [
        None,
        None,  # no verified legacy receipt
        {
            "id": "job-winner",
            "capture_id": "capture-winner",
            "status": "pending",
        },
    ]
    database.create_job.return_value = False
    service = CaptureService(database, AsyncMock(), AsyncMock())
    tasks = BackgroundTasks()

    receipt = await service.submit(CaptureSubmission(intent=make_intent()), tasks)

    assert receipt.disposition == "duplicate"
    assert receipt.jobId == "job-winner"
    assert receipt.captureId == "capture-winner"
    assert len(tasks.tasks) == 0


@pytest.mark.asyncio
async def test_patch_updates_tags_note_and_existing_markdown_sidecar(tmp_path):
    media_path = tmp_path / "saved-video.mp4"
    sidecar_path = media_path.with_suffix(".md")
    sidecar_path.write_text(
        '---\nsource: "https://example.com/post"\ntags: ["old"]\n'
        'notes: "old note"\nsource_tags: ["remote"]\n---\n\nBody stays here.\n',
        encoding="utf-8",
    )
    database = Database(tmp_path / "captures.db")
    await database.initialize()
    await database.create_job("job-1", "https://example.com/post", capture_id="capture-1", intent={"user": {"tags": [], "note": ""}})
    await database.update_job_complete("job-1", str(media_path), {})
    service = CaptureService(database, AsyncMock(), AsyncMock())

    receipt = await service.patch(
        "capture-1",
        CapturePatch(
            tags=[" art ", "art", "reference"],
            note=' keep "this" \u2603 ',
        ),
    )

    assert receipt.status == "saved"
    assert (await database.get_job("job-1"))["intent"] == {"user": {"tags": ["art", "reference"], "note": 'keep "this" \u2603'}}
    await database.close()
    rewritten = sidecar_path.read_text(encoding="utf-8")
    assert 'tags: ["art", "reference"]' in rewritten
    assert 'notes: "keep \\"this\\" ☃"' in rewritten
    assert 'source_tags: ["remote"]' in rewritten
    assert rewritten.count("tags:") == 2  # user tags plus source_tags
    assert "Body stays here." in rewritten


@pytest.mark.asyncio
async def test_patch_finds_tweet_level_sidecar_for_numbered_media(tmp_path):
    media_path = tmp_path / "2026-01-01-twitter-user-123-1.jpg"
    sidecar_path = tmp_path / "2026-01-01-twitter-user-123.md"
    sidecar_path.write_text("---\nplatform: twitter\n---\n\nA tweet.\n")
    database = Database(tmp_path / "captures.db")
    await database.initialize()
    await database.create_job("job-1", "https://example.com/post", capture_id="capture-1", intent={"user": {"tags": [], "note": ""}})
    await database.update_job_complete("job-1", str(media_path), {})
    service = CaptureService(database, AsyncMock(), AsyncMock())

    await service.patch("capture-1", CapturePatch(tags=["mood"], note="later"))
    await database.close()

    rewritten = sidecar_path.read_text()
    assert 'tags: ["mood"]' in rewritten
    assert 'notes: "later"' in rewritten


@pytest.mark.asyncio
async def test_retry_atomically_redispatches_failed_job_with_fresh_cookies():
    intent = make_intent()
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = {
        "id": "job-1",
        "capture_id": "capture-1",
        "status": "failed",
        "intent": intent.model_dump(mode="json"),
    }
    database.claim_capture_retry.return_value = True
    archive_processor = AsyncMock()
    service = CaptureService(database, archive_processor, AsyncMock())
    tasks = BackgroundTasks()

    receipt = await service.retry(
        "capture-1",
        CaptureRetry(cookies=[{"name": "session", "value": "fresh"}]),
        tasks,
    )

    assert receipt.disposition == "accepted"
    assert receipt.status == "accepted"
    assert receipt.jobId == "job-1"
    assert receipt.message == "Retry accepted"
    database.claim_capture_retry.assert_awaited_once_with("capture-1")
    assert len(tasks.tasks) == 1
    assert tasks.tasks[0].kwargs["job_id"] == "job-1"
    assert tasks.tasks[0].kwargs["cookies"][0].value == "fresh"
    database.create_job.assert_not_awaited()


@pytest.mark.asyncio
async def test_retry_does_not_redispatch_nonfailed_job():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = {
        "id": "job-1",
        "capture_id": "capture-1",
        "status": "completed",
    }
    service = CaptureService(database, AsyncMock(), AsyncMock())
    tasks = BackgroundTasks()

    receipt = await service.retry("capture-1", CaptureRetry(), tasks)

    assert receipt.disposition == "duplicate"
    assert receipt.status == "saved"
    assert len(tasks.tasks) == 0
    database.claim_capture_retry.assert_not_awaited()


@pytest.mark.asyncio
async def test_retry_rejects_legacy_failed_job_without_stored_intent():
    database = AsyncMock()
    database.get_job_by_capture_id.return_value = {
        "id": "job-1",
        "capture_id": "capture-1",
        "status": "failed",
        "intent": None,
    }
    service = CaptureService(database, AsyncMock(), AsyncMock())

    with pytest.raises(CaptureRetryError, match="predates durable intents"):
        await service.retry("capture-1", CaptureRetry(), BackgroundTasks())

    database.claim_capture_retry.assert_not_awaited()
