"""Real database checks for collision-safe capture admission and intentional copies."""
from datetime import datetime, timezone
from unittest.mock import AsyncMock

import pytest
from fastapi import BackgroundTasks
from database import Database
from capture_service import CaptureIntent, CaptureService, CaptureSubmission, capture_identity


def intent(capture_id, **overrides):
    return CaptureIntent(**dict({
        "captureId": capture_id,
        "fingerprint": "v1-same-client-hash",
        "kind": "page", "targetUrl": "https://example.com/post",
        "sourcePageUrl": "https://example.com/post",
        "createdAt": datetime(2026, 1, 1, tzinfo=timezone.utc),
    }, **overrides))


@pytest.mark.asyncio
async def test_colliding_client_hash_cannot_discard_different_capture(tmp_path):
    database = Database(tmp_path / "captures.sqlite")
    await database.initialize()
    try:
        service = CaptureService(database, AsyncMock(), AsyncMock())
        one = await service.submit(CaptureSubmission(intent=intent("one")), BackgroundTasks())
        two = await service.submit(CaptureSubmission(intent=intent("two", targetUrl="https://example.com/other")), BackgroundTasks())
        assert one.disposition == two.disposition == "accepted"
        assert one.jobId != two.jobId
        stored = await database.get_job_by_capture_id("one")
        assert stored["fingerprint"].startswith("server-v2-")
        replay = await service.submit(CaptureSubmission(intent=intent("three")), BackgroundTasks())
        assert replay.disposition == "duplicate"
        assert replay.jobId == one.jobId
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_explicit_capture_again_is_new_but_retry_is_same_operation(tmp_path):
    database = Database(tmp_path / "captures.sqlite")
    await database.initialize()
    try:
        service = CaptureService(database, AsyncMock(), AsyncMock())
        first = await service.submit(CaptureSubmission(intent=intent("first")), BackgroundTasks())
        again = intent("again", options={"saveMode": "quick", "captureAgain": True})
        fresh = await service.submit(CaptureSubmission(intent=again), BackgroundTasks())
        retry = await service.submit(CaptureSubmission(intent=again), BackgroundTasks())
        next_copy = await service.submit(CaptureSubmission(intent=intent("next", options=again.options)), BackgroundTasks())
        assert len({first.jobId, fresh.jobId, next_copy.jobId}) == 3
        assert retry.jobId == fresh.jobId and retry.disposition == "duplicate"
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_legacy_hash_requires_full_intent_comparison(tmp_path):
    database = Database(tmp_path / "captures.sqlite")
    await database.initialize()
    try:
        previous = intent("legacy")
        await database.create_job("old-job", previous.targetUrl, capture_id=previous.captureId,
                                  fingerprint=previous.fingerprint, intent=previous.model_dump(mode="json"))
        service = CaptureService(database, AsyncMock(), AsyncMock())
        same = await service.submit(CaptureSubmission(intent=intent("same")), BackgroundTasks())
        different = await service.submit(CaptureSubmission(intent=intent("different", user={"note": "retain this"})), BackgroundTasks())
        assert same.jobId == "old-job"
        assert different.disposition == "accepted"
        assert different.jobId != "old-job"
    finally:
        await database.close()


def test_identity_preserves_modes_screenshots_context_notes_and_edits():
    base = intent("one")
    key = capture_identity(base)
    assert capture_identity(intent("two")) == key
    for change in [
        {"options": {"saveMode": "quick"}},
        {"options": {"screenshot": "data:image/png;base64,changed"}},
        {"options": {"siteData": {"caption": "different"}}},
        {"user": {"tags": ["keep"]}}, {"user": {"note": "new note"}},
        {"page": {"description": "edited post"}},
    ]:
        assert capture_identity(intent("two", **change)) != key
    first = intent("one", options={"siteData": {"a": 1, "b": 2}})
    second = intent("two", options={"siteData": {"b": 2, "a": 1}})
    assert capture_identity(first) == capture_identity(second)
