"""Journal settlement, bounded recovery scans, and nondestructive inventories."""
import json
import logging
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio

from capture_recovery import Attempt, current_attempt, reconcile_job, reconcile_startup, register_staging, track_capture
from database import Database


@pytest_asyncio.fixture
async def database(tmp_path):
    database = Database(tmp_path / "archive.db")
    await database.initialize()
    try:
        yield database
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_success_settles_after_projection_and_cleans_only_staged_credentials(database, monkeypatch):
    root = database.db_path.parent
    await database.create_job("job", "https://example.com")
    service = AsyncMock()
    stage = root / ".nodraw-ingest-success"
    media = root / "media.jpg"
    attempt = None

    async def flush(job):
        assert job["status"] == "completed"
        assert not json.loads(attempt.path.read_text())["settled"]
        assert (stage / ".cookies.txt").is_file()
        # Projection may legitimately change a prepared output's digest.
        media.write_bytes(b"projected metadata")

    service.flush_projection.side_effect = flush

    @track_capture(lambda: database, lambda: service)
    async def capture(job_id):
        nonlocal attempt
        attempt = current_attempt.get()
        register_staging(stage)
        stage.mkdir()
        for name in (".cookies.txt", ".gallery-dl.conf", ".original.jpg", "cookies.txt"):
            (stage / name).write_bytes(b"retained fixture")
        media.write_bytes(b"original media")
        await database.update_job_complete(job_id, str(media), {})
        return "captured"

    def no_scan(*args, **kwargs):
        pytest.fail("Successful capture must settle its own attempt without scanning journals")

    monkeypatch.setattr(Path, "glob", no_scan)
    assert await capture("job") == "captured"
    assert current_attempt.get() is None
    state = json.loads(attempt.path.read_text())
    assert state["version"] == 1 and state["settled"]
    assert not (stage / ".cookies.txt").exists()
    assert not (stage / ".gallery-dl.conf").exists()
    assert (stage / ".original.jpg").read_bytes() == b"retained fixture"
    assert (stage / "cookies.txt").read_bytes() == b"retained fixture"
    assert media.read_bytes() == b"projected metadata"
    assert stage.is_dir() and attempt.path.is_file()
    service.flush_projection.assert_awaited_once()


@pytest.mark.asyncio
async def test_unsafe_staging_after_success_keeps_the_result_and_the_journal(database, caplog):
    root = database.db_path.parent
    await database.create_job("job", "https://example.com")
    service = AsyncMock()
    outside = root.parent / f"{root.name}-outside"
    attempt = None

    @track_capture(lambda: database, lambda: service)
    async def capture(job_id):
        nonlocal attempt
        attempt = current_attempt.get()
        register_staging(outside)
        (root / "media.jpg").write_bytes(b"media")
        await database.update_job_complete(job_id, str(root / "media.jpg"), {})
        return "captured"

    with caplog.at_level(logging.ERROR):
        assert await capture("job") == "captured"
    assert not json.loads(attempt.path.read_text())["settled"]
    assert "Could not settle capture attempt" in caplog.text
    assert (await database.get_job("job"))["status"] == "completed"


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["capture", "projection"])
async def test_failure_leaves_attempt_unsettled(database, failure):
    root = database.db_path.parent
    await database.create_job("job", "https://example.com")
    service = AsyncMock()
    service.flush_projection.side_effect = OSError("projection failed")

    @track_capture(lambda: database, lambda: service)
    async def capture(job_id):
        if failure == "capture":
            await database.update_job_failed(job_id, "capture failed")
            return
        media = root / "media.jpg"
        media.write_bytes(b"media")
        await database.update_job_complete(job_id, str(media), {})

    if failure == "projection":
        with pytest.raises(OSError, match="projection failed"):
            await capture("job")
    else:
        await capture("job")
        service.flush_projection.assert_not_awaited()
    assert current_attempt.get() is None
    assert not json.loads(next((root / ".nodraw-attempts").glob("*.json")).read_text())["settled"]


@pytest.mark.asyncio
@pytest.mark.parametrize("job_count", [1, 8])
async def test_startup_reads_attempts_once_per_pass_and_skips_settled(database, monkeypatch, job_count):
    root = database.db_path.parent
    paths = []
    for index in range(job_count):
        job_id = f"job-{index}"
        await database.create_job(job_id, "https://example.com")
        if index % 2:
            await database.update_job_status(job_id, "completed")
        # Multiple attempts for one job must share the same scan.
        paths.extend([Attempt(root, job_id).path, Attempt(root, job_id).path])
    await database.create_job("no-attempt", "https://example.com")
    settled = Attempt(root, "settled-orphan")
    settled.state.update(settled=True, staging=["/outside/archive"])
    settled.save()
    paths.append(settled.path)
    settled_bytes = settled.path.read_bytes()
    scans = 0
    reads = {path: 0 for path in paths}
    original_glob, original_read = Path.glob, Path.read_text

    def glob(path, pattern, *args, **kwargs):
        nonlocal scans
        if path == root / ".nodraw-attempts":
            scans += 1
        return original_glob(path, pattern, *args, **kwargs)

    def read(path, *args, **kwargs):
        if path in reads:
            reads[path] += 1
        return original_read(path, *args, **kwargs)

    monkeypatch.setattr(Path, "glob", glob)
    monkeypatch.setattr(Path, "read_text", read)
    for pass_number in (1, 2):
        await reconcile_startup(database)
        assert scans == pass_number
        assert set(reads.values()) == {pass_number}
    assert settled.path.read_bytes() == settled_bytes
    for index in range(job_count):
        job = await database.get_job(f"job-{index}")
        assert job["status"] == ("completed" if index % 2 else "failed")
        if not index % 2:
            assert job["error_category"] == "server_restart"


@pytest.mark.asyncio
@pytest.mark.parametrize("bad_record", ["{broken", "[]", '{"job_id": []}', '{"job_id": "bad", "moves": null}'])
async def test_corrupt_journal_is_skipped_without_losing_missing_record_safety(database, caplog, bad_record):
    root = database.db_path.parent
    await database.create_job("good", "https://example.com")
    good = Attempt(root, "good")
    await database.create_job("missing-record", "https://example.com")
    media = root / "unowned.jpg"
    media.write_bytes(b"irreplaceable")
    await database.update_job_complete("missing-record", str(media), {})
    await database.update_job_status("missing-record", "downloading")
    bad = root / ".nodraw-attempts" / "bad.json"
    bad.write_text(bad_record)
    with caplog.at_level(logging.ERROR, logger="capture_recovery"):
        await reconcile_startup(database)
    assert str(bad) in caplog.text and "Unreadable capture attempt" in caplog.text
    assert (await database.get_job("good"))["error_category"] == "server_restart"
    assert json.loads(good.path.read_text())["settled"]
    assert (await database.get_job("missing-record"))["error_category"] == "restart_recovery_needed"
    assert media.read_bytes() == b"irreplaceable" and bad.read_text() == bad_record


@pytest.mark.asyncio
async def test_retry_scans_once_and_skips_unreadable_journal(database, monkeypatch, caplog):
    root = database.db_path.parent
    await database.create_job("retry", "https://example.com")
    await database.update_job_failed("retry", "interrupted")
    good = Attempt(root, "retry")
    unreadable = root / ".nodraw-attempts" / "unreadable.json"
    unreadable.write_text("{}")
    scans = 0
    original_glob, original_read = Path.glob, Path.read_text

    def glob(path, pattern, *args, **kwargs):
        nonlocal scans
        if path == root / ".nodraw-attempts":
            scans += 1
        return original_glob(path, pattern, *args, **kwargs)

    def read(path, *args, **kwargs):
        if path == unreadable:
            raise OSError("unreadable fixture")
        return original_read(path, *args, **kwargs)

    monkeypatch.setattr(Path, "glob", glob)
    monkeypatch.setattr(Path, "read_text", read)
    result = await reconcile_job(database, await database.get_job("retry"))
    assert result["status"] == "failed"
    assert scans == 1 and json.loads(good.path.read_text())["settled"]
    assert unreadable.is_file() and "unreadable fixture" in caplog.text


@pytest.mark.asyncio
async def test_stale_storage_is_reported_once_and_never_removed(database, caplog):
    root = database.db_path.parent
    stages, originals = [], []
    for parent in (root, root / "2026-09"):
        stage = parent / ".nodraw-ingest-stale"
        stage.mkdir(parents=True)
        (stage / ".cookies.txt").write_bytes(b"keep unjournaled credentials")
        stages.append(stage)
        original = parent / ".nodraw-originals" / "hash" / ".media.jpg"
        original.parent.mkdir(parents=True)
        original.write_bytes(b"original")
        originals.append(original)
    settled = Attempt(root, "settled-orphan")
    settled.state["settled"] = True
    settled.save()
    before = {path: path.read_bytes() for path in [settled.path, *originals, *(stage / ".cookies.txt" for stage in stages)]}
    with caplog.at_level(logging.WARNING, logger="capture_recovery"):
        await reconcile_startup(database)
    warnings = [record.getMessage() for record in caplog.records if record.levelno == logging.WARNING]
    assert len(warnings) == 1
    warning = warnings[0]
    assert "report only" in warning and "files=2, bytes=16" in warning
    for path in [*stages, root / ".nodraw-originals", root / "2026-09" / ".nodraw-originals"]:
        assert str(path.relative_to(root)) in warning
        assert path.is_dir()
    assert {path: path.read_bytes() for path in before} == before


@pytest.mark.asyncio
async def test_stale_inventory_does_not_follow_symlinks(database, tmp_path, caplog):
    root = database.db_path.parent
    outside = root.parent / f"{root.name}-outside"
    outside.mkdir()
    original = outside / "precious.jpg"
    original.write_bytes(b"outside original")
    (root / "2026-08").symlink_to(outside, target_is_directory=True)
    (root / ".nodraw-ingest-link").symlink_to(outside, target_is_directory=True)
    (root / ".nodraw-originals").symlink_to(outside, target_is_directory=True)
    private = root / "2026-09" / ".nodraw-originals"
    private.mkdir(parents=True)
    (private / "linked-dir").symlink_to(outside, target_is_directory=True)
    (private / "linked-file").symlink_to(original)
    with caplog.at_level(logging.WARNING, logger="capture_recovery"):
        await reconcile_startup(database)
    assert "files=0, bytes=0" in caplog.text
    assert "2026-09/.nodraw-originals" in caplog.text
    assert ".nodraw-ingest-link" not in caplog.text
    assert original.read_bytes() == b"outside original"
