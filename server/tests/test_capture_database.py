import json
from datetime import datetime, timezone

import aiosqlite
import pytest

from database import Database


@pytest.mark.asyncio
async def test_initialize_migrates_legacy_jobs_and_enforces_capture_identity(tmp_path):
    db_path = tmp_path / "legacy.db"
    connection = await aiosqlite.connect(db_path)
    await connection.execute(
        """
        CREATE TABLE archive_jobs (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            status TEXT DEFAULT 'pending',
            page_title TEXT,
            page_url TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            completed_at TIMESTAMP,
            file_path TEXT,
            file_size INTEGER,
            file_hash TEXT,
            metadata TEXT,
            error TEXT
        )
        """
    )
    await connection.commit()
    await connection.close()

    database = Database(db_path)
    await database.initialize()
    try:
        async with database.conn.execute("PRAGMA table_info(archive_jobs)") as cursor:
            columns = {row[1] async for row in cursor}
        assert {"capture_id", "fingerprint", "capture_kind", "intent_json"} <= columns

        assert await database.create_job(
            job_id="job-1",
            url="https://example.com/post",
            timestamp=datetime(2026, 1, 1, tzinfo=timezone.utc),
            capture_id="capture-1",
            fingerprint="v1-deadbeef",
            capture_kind="page",
            intent={"captureId": "capture-1"},
        ) is True
        migrated_job = await database.get_job_by_capture_id("capture-1")
        assert migrated_job["fingerprint"] == "v1-deadbeef"
        assert migrated_job["intent"] == {"captureId": "capture-1"}

        assert await database.create_job(
            job_id="job-duplicate",
            url="https://example.com/elsewhere",
            capture_id="capture-1",
        ) is False
        assert await database.create_job(
            job_id="job-equivalent",
            url="https://example.com/elsewhere",
            capture_id="capture-2",
            fingerprint="v1-deadbeef",
        ) is False

        async with database.conn.execute("PRAGMA index_list(archive_jobs)") as cursor:
            indexes = {row[1]: row[2] async for row in cursor}
        assert indexes["idx_jobs_fingerprint"] == 1
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_status_job_poll_uses_ordered_composite_index(tmp_path):
    database = Database(tmp_path / "polling.db")
    await database.initialize()
    try:
        async with database.conn.execute(
            """
            EXPLAIN QUERY PLAN
            SELECT * FROM archive_jobs
            WHERE status = ?
            ORDER BY created_at DESC
            LIMIT ?
            """,
            ("completed", 50),
        ) as cursor:
            details = [row[3] async for row in cursor]

        assert any("idx_jobs_status_created" in detail for detail in details)
        assert all("TEMP B-TREE" not in detail for detail in details)
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_claim_capture_retry_is_single_use_and_clears_failed_result(tmp_path):
    database = Database(tmp_path / "captures.db")
    await database.initialize()
    try:
        await database.create_job(
            job_id="job-1",
            url="https://example.com/post",
            capture_id="capture-1",
            fingerprint="v1-deadbeef",
            capture_kind="page",
            intent={"captureId": "capture-1"},
        )
        await database.update_job_failed("job-1", "network down", "network")

        assert await database.claim_capture_retry("capture-1") is True
        assert await database.claim_capture_retry("capture-1") is False

        job = await database.get_job_by_capture_id("capture-1")
        assert job["status"] == "pending"
        assert job["error"] is None
        assert job["metadata"] == {}
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_unique_fingerprint_migration_preserves_duplicate_jobs(tmp_path):
    db_path = tmp_path / "early-captures.db"
    early_database = Database(db_path)
    await early_database.initialize()
    try:
        await early_database.conn.execute("DROP INDEX idx_jobs_fingerprint")
        await early_database.conn.execute(
            "CREATE INDEX idx_jobs_fingerprint ON archive_jobs(fingerprint)"
        )
        await early_database.conn.commit()
        assert await early_database.create_job(
            job_id="job-old",
            url="https://example.com/post",
            capture_id="capture-old",
            fingerprint="v1-same",
        ) is True
        assert await early_database.create_job(
            job_id="job-new",
            url="https://example.com/post",
            capture_id="capture-new",
            fingerprint="v1-same",
        ) is True
    finally:
        await early_database.close()

    migrated_database = Database(db_path)
    await migrated_database.initialize()
    try:
        async with migrated_database.conn.execute(
            "SELECT id, fingerprint FROM archive_jobs ORDER BY rowid"
        ) as cursor:
            jobs = await cursor.fetchall()
        assert jobs == [("job-old", None), ("job-new", "v1-same")]
    finally:
        await migrated_database.close()


@pytest.mark.asyncio
async def test_second_initialize_keeps_healthy_fingerprint_index_in_place(tmp_path):
    db_path = tmp_path / "idempotent.db"
    first = Database(db_path)
    await first.initialize()
    try:
        assert await first.create_job(
            job_id="job-stable",
            url="https://example.com/stable",
            capture_id="capture-stable",
            fingerprint="v1-stable",
        ) is True
        async with first.conn.execute("PRAGMA schema_version") as cursor:
            schema_version_before = (await cursor.fetchone())[0]
        async with first.conn.execute(
            """
            SELECT rootpage, sql FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_jobs_fingerprint'
            """
        ) as cursor:
            index_before = await cursor.fetchone()
    finally:
        await first.close()

    second = Database(db_path)
    await second.initialize()
    try:
        async with second.conn.execute("PRAGMA schema_version") as cursor:
            schema_version_after = (await cursor.fetchone())[0]
        async with second.conn.execute(
            """
            SELECT rootpage, sql FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_jobs_fingerprint'
            """
        ) as cursor:
            index_after = await cursor.fetchone()
        async with second.conn.execute(
            "SELECT id, fingerprint FROM archive_jobs"
        ) as cursor:
            jobs = await cursor.fetchall()

        assert schema_version_after == schema_version_before
        assert index_after == index_before
        assert jobs == [("job-stable", "v1-stable")]
    finally:
        await second.close()


def _intent(capture_id, screenshot):
    return {"captureId": capture_id, "options": {"saveMode": "full", "screenshot": screenshot}}


@pytest.mark.asyncio
async def test_finished_captures_drop_their_screenshot_and_failed_ones_keep_it(tmp_path):
    database = Database(tmp_path / "captures.db")
    await database.initialize()
    try:
        for name in ("done", "failed"):
            await database.create_job(
                job_id=name, url=f"https://example.com/{name}", capture_id=name,
                fingerprint=f"v1-{name}", capture_kind="page", intent=_intent(name, "data:image/png;base64,AAAA"),
            )
        await database.update_job_complete("done", str(tmp_path / "done.md"), {})
        await database.update_job_failed("failed", "network down", "network")

        done = await database.get_job_by_capture_id("done")
        failed = await database.get_job_by_capture_id("failed")
        assert done["intent"] == _intent("done", "")
        # A failed capture may be retried, and the retry still needs its screenshot.
        assert failed["intent"] == _intent("failed", "data:image/png;base64,AAAA")
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_initialize_drops_screenshots_kept_by_older_builds(tmp_path):
    db_path = tmp_path / "captures.db"
    database = Database(db_path)
    await database.initialize()
    rows = {
        "old-done": ("completed", json.dumps(_intent("old-done", "data:image/png;base64,AAAA"))),
        "old-failed": ("failed", json.dumps(_intent("old-failed", "data:image/png;base64,BBBB"))),
        "no-intent": ("completed", None),
        "not-json": ("completed", "{broken"),
        "no-options": ("completed", json.dumps({"captureId": "no-options"})),
    }
    for job_id, (status, intent_json) in rows.items():
        await database.conn.execute(
            "INSERT INTO archive_jobs (id, url, status, capture_id, intent_json) VALUES (?, ?, ?, ?, ?)",
            (job_id, f"https://example.com/{job_id}", status, job_id, intent_json),
        )
    await database.conn.commit()
    await database.close()

    for _ in range(2):
        database = Database(db_path)
        await database.initialize()
        async with database.conn.execute("SELECT id, intent_json FROM archive_jobs") as cursor:
            stored = {row[0]: row[1] async for row in cursor}
        await database.close()
        assert json.loads(stored["old-done"]) == _intent("old-done", "")
        assert json.loads(stored["old-failed"]) == _intent("old-failed", "data:image/png;base64,BBBB")
        assert stored["no-intent"] is None
        assert stored["not-json"] == "{broken"
        assert json.loads(stored["no-options"]) == {"captureId": "no-options"}
