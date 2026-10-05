"""Production DB/filesystem boundaries, including abrupt process death."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from unittest.mock import AsyncMock

from fastapi import BackgroundTasks
import pytest
import pytest_asyncio
import yaml

from capture_service import CapturePatch, CaptureRetry, CaptureRetryError, CaptureService
from capture_recovery import Attempt, current_attempt, reconcile_startup
from database import Database, CaptureMutationConflict
from sidecar_projection import project, read_base


@pytest_asyncio.fixture
async def durable(tmp_path):
    database = Database(tmp_path / "archive.db")
    await database.initialize()
    media = tmp_path / "capture.jpg"
    media.write_bytes(b"original media")
    sidecar = media.with_suffix(".md")
    sidecar.write_text('---\ntags: [old]\nnotes: old note\n---\nBody\n')
    intent = {"schemaVersion": 1, "captureId": "capture", "fingerprint": "v1-test", "kind": "page", "targetUrl": "https://example.com/post", "sourcePageUrl": "https://example.com/post", "createdAt": "2026-01-01T00:00:00Z", "user": {"tags": ["old"], "note": "old note"}}
    await database.create_job("job", intent["targetUrl"], capture_id="capture", fingerprint="v1-test", intent=intent)
    await database.update_job_complete("job", str(media), {"sidecar_path": str(sidecar)})
    service = CaptureService(database, AsyncMock(), AsyncMock())
    try:
        yield database, service, media, sidecar
    finally:
        await database.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("bom", ["", "\ufeff"])
async def test_partial_structural_patch_preserves_multiline_unknown_crlf_body_and_finder_metadata(durable, bom):
    database, service, _, sidecar = durable
    body = "\r\nBody 雪\r\n---\r\nunchanged\r\n"
    sidecar.write_bytes((bom + '---\r\ntags:\r\n  - old\r\n  - 雪\r\nnotes: |\r\n  external note\r\n  second line\r\nunknown:\r\n  nested: [one, two]\r\n---\r\n' + body).encode())
    attribute = "com.apple.metadata:kMDItemDateAdded" if sys.platform == "darwin" else "user.nodraw-test"
    if sys.platform == "darwin":
        subprocess.run(["xattr", "-w", attribute, "finder-date-added-fixture", str(sidecar)], check=True)
    else:
        os.setxattr(sidecar, attribute, b"finder-date-added-fixture")
    sidecar.chmod(0o640)
    receipt = await service.patch("capture", CapturePatch(tags=["new", "new", " λ "]))
    assert receipt.status == "saved" and receipt.metadataProjection == "applied"
    result = sidecar.read_bytes().decode()
    assert result.startswith(bom + "---\r\n")
    assert result.endswith(body)
    assert "notes: |\r\n  external note\r\n  second line\r\n" in result
    assert "unknown:\r\n  nested: [one, two]\r\n" in result
    assert yaml.safe_load(result.split("---\r\n")[1])["tags"] == ["new", "λ"]
    if sys.platform == "darwin":
        assert subprocess.check_output(["xattr", "-p", attribute, str(sidecar)]).strip() == b"finder-date-added-fixture"
    else:
        assert os.getxattr(sidecar, attribute) == b"finder-date-added-fixture"
    assert sidecar.stat().st_mode & 0o777 == 0o640
    lock = sidecar.with_name(f".{sidecar.name}.nodraw-lock")
    inode = lock.stat().st_ino
    await service.patch("capture", CapturePatch(note="new note"))
    assert lock.stat().st_ino == inode
    assert "second line" not in sidecar.read_text()
    assert (await database.get_job("job"))["intent"]["user"] == {"tags": ["new", "λ"], "note": "new note"}


@pytest.mark.asyncio
async def test_metadata_mutation_receipts_survive_restart_and_late_replay(durable):
    database, service, _, sidecar = durable
    first = await service.patch("capture", CapturePatch(note="A", mutationId="mutation-A"))
    assert first.metadataMutationRevision == 1
    second = await service.patch("capture", CapturePatch(note="B", mutationId="mutation-B"))
    assert second.metadataMutationRevision == 2
    await database.close()
    await database.initialize()
    restarted = CaptureService(database, AsyncMock(), AsyncMock())
    replay = await restarted.patch("capture", CapturePatch(note="A", mutationId="mutation-A"))
    assert replay.metadataMutationId == "mutation-A"
    assert replay.metadataMutationRevision == 1
    assert replay.metadataRevision == 2
    assert read_base(sidecar)["notes"] == "B"
    with pytest.raises(CaptureMutationConflict, match="different fields"):
        await restarted.patch("capture", CapturePatch(tags=["other"], mutationId="mutation-A"))
    assert (await database.get_job("job"))["intent"]["user"]["note"] == "B"
    legacy = await restarted.patch("capture", CapturePatch(note="legacy"))
    assert legacy.metadataMutationId is None
    assert legacy.metadataRevision == 3
    assert (await restarted.patch("capture", CapturePatch())).metadataRevision == 3


@pytest.mark.asyncio
async def test_mutation_replay_does_not_rebase_a_retained_projection_conflict(durable, monkeypatch):
    database, service, _, sidecar = durable
    import capture_service
    original_project = capture_service.project
    monkeypatch.setattr(capture_service, "project", lambda *args: (_ for _ in ()).throw(OSError("read only")))
    first = await service.patch("capture", CapturePatch(note="wanted", mutationId="retained"))
    assert first.metadataProjection == "failed"
    monkeypatch.setattr(capture_service, "project", original_project)
    sidecar.write_text('---\ntags: [old]\nnotes: external\n---\nBody\n')
    await database.close()
    await database.initialize()
    replay = await CaptureService(database, AsyncMock(), AsyncMock()).patch("capture", CapturePatch(note="wanted", mutationId="retained"))
    assert replay.metadataProjection == "failed"
    assert replay.metadataRevision == first.metadataRevision
    assert read_base(sidecar)["notes"] == "external"


@pytest.mark.asyncio
async def test_mutation_receipt_failure_rolls_back_metadata_acceptance(durable):
    database, service, _, sidecar = durable
    await database.conn.execute("CREATE TRIGGER fail_mutation BEFORE INSERT ON capture_metadata_mutations BEGIN SELECT RAISE(FAIL, 'receipt unavailable'); END")
    await database.conn.commit()
    with pytest.raises(Exception, match="receipt unavailable"):
        await service.patch("capture", CapturePatch(note="not accepted", mutationId="atomic"))
    job = await database.get_job("job")
    assert job["metadata_revision"] == 0
    assert job["intent"]["user"]["note"] == "old note"
    assert read_base(sidecar)["notes"] == "old note"


@pytest.mark.asyncio
async def test_failed_atomic_publish_retains_db_intent_original_and_retry_after_restart(durable, monkeypatch):
    database, service, media, sidecar = durable
    original = sidecar.read_bytes()
    import sidecar_projection
    replace = sidecar_projection.os.replace
    monkeypatch.setattr(sidecar_projection.os, "replace", lambda *args: (_ for _ in ()).throw(OSError("disk unavailable")))
    receipt = await service.patch("capture", CapturePatch(note="durable edit"))
    assert receipt.status == "saved" and receipt.metadataProjection == "failed"
    assert "disk unavailable" in receipt.metadataError
    assert sidecar.read_bytes() == original
    assert (await database.get_job("job"))["intent"]["user"]["note"] == "durable edit"
    monkeypatch.setattr(sidecar_projection.os, "replace", replace)
    await database.close()
    await database.initialize()
    restarted = CaptureService(database, AsyncMock(), AsyncMock())
    await restarted.reconcile_projections()
    assert (await restarted.get("capture")).metadataProjection == "applied"
    assert "durable edit" in sidecar.read_text()
    assert media.read_bytes() == b"original media"
    restarted.archive_processor.assert_not_called()


@pytest.mark.asyncio
async def test_missing_sidecar_is_not_success_and_existing_retry_never_redownloads(durable):
    database, service, _, sidecar = durable
    original = sidecar.read_bytes()
    sidecar.unlink()
    receipt = await service.patch("capture", CapturePatch(note="later"))
    assert receipt.status == "saved" and receipt.metadataProjection == "failed"
    assert "missing" in receipt.metadataError
    sidecar.write_bytes(original)
    tasks = BackgroundTasks()
    receipt = await service.retry("capture", CaptureRetry(), tasks)
    assert receipt.metadataProjection == "applied" and tasks.tasks == []
    assert "later" in sidecar.read_text()


@pytest.mark.asyncio
async def test_same_field_conflict_is_durable_and_disjoint_external_edit_merges(durable):
    database, service, _, sidecar = durable
    job = await database.enqueue_capture_patch("capture", {"notes": "proposed"}, read_base(sidecar))
    project(sidecar, {"notes": "external", "tags": ["external-tag"]}, {"notes": ["old note"], "tags": [["old"]]})
    receipt = await service.flush_projection(job)
    assert receipt.metadataProjection == "failed"
    assert json.loads(receipt.metadataError)["current"] == "external"
    assert (await database.get_job("job"))["metadata_projection"]["fields"]["notes"] == "proposed"
    # A deliberate fresh edit resolves this field against the current sidecar.
    receipt = await service.patch("capture", CapturePatch(note="resolved"))
    assert receipt.metadataProjection == "applied"
    assert read_base(sidecar) == {"notes": "resolved", "tags": ["external-tag"]}


@pytest.mark.asyncio
async def test_patch_captures_description_and_comma_tags_as_parser_base(durable, monkeypatch):
    database, service, _, sidecar = durable
    sidecar.write_text('---\ndescription: captured description\ntags: " art, reference "\n---\nBody\n')
    import capture_service
    monkeypatch.setattr(capture_service, "project", lambda *args: (_ for _ in ()).throw(OSError("read only")))
    receipt = await service.patch("capture", CapturePatch(note="edited note", tags=["new"]))
    assert receipt.metadataProjection == "failed"
    pending = (await database.get_job("job"))["metadata_projection"]
    assert pending["bases"] == {"notes": ["captured description"], "tags": [["art", "reference"]]}


@pytest.mark.asyncio
async def test_newer_edit_during_flush_survives_older_acknowledgement(durable, monkeypatch):
    database, service, _, sidecar = durable
    first = await database.enqueue_capture_patch("capture", {"notes": "first"}, read_base(sidecar))
    entered, release = threading.Event(), threading.Event()
    import capture_service
    def delayed(*args):
        entered.set()
        assert release.wait(5)
        project(*args)
    monkeypatch.setattr(capture_service, "project", delayed)
    task = asyncio.create_task(service.flush_projection(first))
    await asyncio.to_thread(entered.wait, 5)
    await database.enqueue_capture_patch("capture", {"notes": "second"}, read_base(sidecar))
    release.set()
    await task
    current = await database.get_job("job")
    assert current["metadata_revision"] == 2 and current["metadata_projection"]
    monkeypatch.setattr(capture_service, "project", project)
    await service.flush_projection(current)
    assert read_base(sidecar)["notes"] == "second"


@pytest.mark.asyncio
@pytest.mark.parametrize("boundary", ["before_move", "after_move", "after_copy", "prepared", "committed"])
async def test_hard_process_death_reconciles_owned_publication_without_redownload(tmp_path, boundary):
    database = Database(tmp_path / "archive.db")
    await database.initialize()
    await database.create_job("job", "https://example.com", capture_id="capture")
    # No finally/rollback can execute in this process: the durable evidence is
    # all startup has to distinguish published artifacts from unrelated files.
    script = '''
import asyncio, errno, os, sys
from pathlib import Path
from capture_recovery import Attempt, current_attempt, register_staging
from downloaders import runtime_safety
from database import Database
root, boundary = Path(sys.argv[1]), sys.argv[2]
attempt = Attempt(root, "job")
current_attempt.set(attempt)
stage = root / ".owned-stage"
register_staging(stage)
stage.mkdir()
(stage / ".cookies.txt").write_text("ephemeral-secret")
source = stage / ".media.jpg"
source.write_bytes(b"owned original")
target = root / "media.jpg"
if boundary == "before_move":
    runtime_safety._move_file_no_clobber_impl = lambda *args: os._exit(71)
if boundary == "after_copy":
    def fail_link(*args, **kwargs): raise OSError(errno.EXDEV, "cross-device fixture")
    os.link = fail_link
runtime_safety._move_file_no_clobber(source, target)
if boundary in ("after_move", "after_copy"): os._exit(72)
attempt.prepare_completion(str(target), {"title": "recovered", "files": ["media.jpg"]})
if boundary == "prepared": os._exit(73)
async def commit():
    database = Database(root / "archive.db")
    await database.initialize()
    await database.update_job_complete("job", str(target), {"title": "recovered"})
asyncio.run(commit())
os._exit(74)
'''
    environment = {**os.environ, "PYTHONPATH": str(Path(__file__).parents[1])}
    process = await asyncio.to_thread(subprocess.run, [sys.executable, "-c", script, str(tmp_path), boundary], env=environment, capture_output=True, text=True)
    assert process.returncode in (71, 72, 73, 74), process.stderr
    unrelated = tmp_path / "unrelated.jpg"
    unrelated.write_bytes(b"untouched")
    try:
        await reconcile_startup(database)
        job = await database.get_job("job")
        assert job["status"] == ("completed" if boundary in ("prepared", "committed") else "failed")
        assert unrelated.read_bytes() == b"untouched"
        if boundary in ("prepared", "committed"):
            assert (tmp_path / "media.jpg").read_bytes() == b"owned original"
        elif boundary in ("after_move", "after_copy"):
            assert not (tmp_path / "media.jpg").exists()
            assert any(path.read_bytes() == b"owned original" for path in (tmp_path / ".nodraw-originals").rglob(".media.jpg"))
        assert not (tmp_path / ".owned-stage" / ".cookies.txt").exists()
        journals = list((tmp_path / ".nodraw-attempts").glob("*.json"))
        assert all("ephemeral-secret" not in path.read_text() for path in journals)
    finally:
        await database.close()


@pytest.mark.asyncio
async def test_restart_without_attempt_is_truthfully_failed_and_changed_artifact_blocks_retry(durable):
    database, service, media, _ = durable
    await database.update_job_status("job", "downloading")
    await reconcile_startup(database)
    assert (await database.get_job("job"))["error_category"] == "restart_recovery_needed"
    attempt = Attempt(database.db_path.parent, "job")
    source = media.parent / ".staged.jpg"
    source.write_bytes(b"attempt")
    attempt.before_move(source, media)
    with pytest.raises(CaptureRetryError, match="changed"):
        await service.retry("capture", CaptureRetry(), BackgroundTasks())
    assert media.read_bytes() == b"original media"
    service.archive_processor.assert_not_called()


@pytest.mark.asyncio
async def test_same_bytes_from_unrelated_collision_are_not_attempt_ownership(durable):
    database, _, media, _ = durable
    await database.update_job_status("job", "downloading")
    attempt = Attempt(database.db_path.parent, "job")
    staged = media.parent / ".staged-collision.jpg"
    staged.write_bytes(media.read_bytes())
    attempt.before_move(staged, media)
    await reconcile_startup(database)
    assert media.read_bytes() == b"original media"
    assert (await database.get_job("job"))["error_category"] == "restart_recovery_needed"


@pytest.mark.asyncio
async def test_real_text_processor_tracks_publication_and_flushes_precompletion_patch(durable, monkeypatch):
    import main
    from storage import StorageManager
    database, _, _, _ = durable
    monkeypatch.setattr(main, "db", database)
    monkeypatch.setattr(main, "storage", StorageManager(database.db_path.parent))
    await database.update_job_status("job", "pending")
    await main.get_capture_service().patch("capture", CapturePatch(note="edited while queued"))
    await main.process_download(job_id="job", url="https://example.com/post", cookies=[], options={"capture_intent": {"captureId": "capture", "kind": "selection"}, "user_tags": ["old"], "user_note": "old note"}, save_mode="text", page_title="Text fixture", screenshot="data:image/png;base64,c2NyZWVuc2hvdA==")
    job = await database.get_job("job")
    assert job["status"] == "completed" and not job["metadata_projection"]
    assert read_base(Path(job["metadata"]["sidecar_path"]))["notes"] == "edited while queued"
    state = json.loads(next((database.db_path.parent / ".nodraw-attempts").glob("*.json")).read_text())
    assert state["job_id"] == "job" and state["moves"] and state["completion"]
    assert state["settled"]


@pytest.mark.asyncio
async def test_attempt_storage_failure_is_terminal_before_processor_writes(durable, monkeypatch):
    import main
    database, _, media, _ = durable
    monkeypatch.setattr(main, "db", database)
    monkeypatch.setattr(Attempt, "save", lambda self: (_ for _ in ()).throw(OSError("disk full")))
    await main.process_download(job_id="job", url="https://example.com/post", cookies=[], options={}, save_mode="text")
    job = await database.get_job("job")
    assert job["status"] == "failed" and job["error_category"] == "capture_storage_failed"
    assert "disk full" in job["error"] and media.read_bytes() == b"original media"


@pytest.mark.asyncio
async def test_fresh_archive_is_zero_days_old_in_any_timezone(tmp_path, monkeypatch):
    import time as _time
    monkeypatch.setenv("TZ", "America/Chicago")
    _time.tzset()
    database = Database(tmp_path / "archive.db")
    await database.initialize()
    try:
        from datetime import datetime, timezone
        url = "https://x.com/a/status/1"
        await database.create_job("utc", url, timestamp=datetime.now(timezone.utc))
        await database.update_job_complete("utc", str(tmp_path / "a.md"), {})
        assert (await database.check_url_archived(url))["age_days"] == 0
        await database.create_job("local", url + "0")
        await database.update_job_complete("local", str(tmp_path / "b.md"), {})
        assert (await database.check_url_archived(url + "0"))["age_days"] == 0
    finally:
        await database.close()
        monkeypatch.delenv("TZ")
        _time.tzset()
