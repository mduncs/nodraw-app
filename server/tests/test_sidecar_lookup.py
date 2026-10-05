"""Metadata edits follow renamed sidecars without guessing between captures."""
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio

from capture_service import CapturePatch, CaptureService
from database import Database
from sidecar_projection import read_base
from sidecar_writer import render_sidecar


URL = "https://example.com/post"
MISSING = "Saved media is intact, but its Markdown sidecar is missing. Restore the sidecar and retry metadata."


@pytest_asyncio.fixture
async def archive(tmp_path):
    database = Database(tmp_path / "archive.db")
    await database.initialize()
    media = tmp_path / "original.jpg"
    media.write_bytes(b"saved media")
    await database.create_job("job", URL, capture_id="capture", intent={"user": {"tags": [], "note": ""}})
    await database.update_job_complete("job", str(media), {"sidecar_path": str(media.with_suffix(".md")), "keep": "metadata"})
    try:
        yield database, CaptureService(database, AsyncMock(), AsyncMock()), tmp_path
    finally:
        await database.close()


def write_sidecar(root, name, **fields):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(render_sidecar({"source": URL, "tags": ["app tag"], "notes": "app note", **fields}, ["", "Body stays."]))
    return path


@pytest.mark.asyncio
@pytest.mark.parametrize("fields", [{"capture_id": "capture", "source": "https://example.com/changed"}, {}], ids=["capture-id", "legacy-source"])
async def test_patch_finds_moved_sidecar_and_reads_its_current_base(archive, fields):
    database, service, root = archive
    renamed = write_sidecar(root, "moved/app-renamed.md", **fields)
    receipt = await service.patch("capture", CapturePatch(tags=["edited"], note="edited note"))
    assert receipt.metadataProjection == "applied", receipt.metadataError
    assert read_base(renamed) == {"tags": ["edited"], "notes": "edited note"}
    assert renamed.read_text().endswith("Body stays.")
    job = await database.get_job("job")
    assert job["metadata"] == {"sidecar_path": str(renamed), "keep": "metadata"}
    # A new service must use the persisted path, even when fallback is unavailable.
    with patch("capture_service.os.walk", side_effect=AssertionError("should be direct")):
        receipt = await CaptureService(database, AsyncMock(), AsyncMock()).patch("capture", CapturePatch(note="next"))
    assert receipt.metadataProjection == "applied"


@pytest.mark.asyncio
async def test_pending_flush_uses_the_same_renamed_sidecar_resolver(archive):
    database, service, root = archive
    renamed = write_sidecar(root, "moved.md", capture_id="capture", tags=[], notes="")
    job = await database.enqueue_capture_patch("capture", {"notes": "queued"}, {"notes": ""})
    receipt = await service.flush_projection(job)
    assert receipt.metadataProjection == "applied", receipt.metadataError
    assert read_base(renamed)["notes"] == "queued"
    assert (await database.get_job("job"))["metadata"]["sidecar_path"] == str(renamed)


@pytest.mark.asyncio
async def test_capture_id_match_takes_priority_over_legacy_source_matches(archive):
    _, service, root = archive
    chosen = write_sidecar(root, "chosen.md", capture_id="capture")
    older = write_sidecar(root, "older.md")
    other_capture = write_sidecar(root, "other.md", capture_id="other")
    originals = [path.read_bytes() for path in [older, other_capture]]
    receipt = await service.patch("capture", CapturePatch(note="chosen"))
    assert receipt.metadataProjection == "applied", receipt.metadataError
    assert read_base(chosen)["notes"] == "chosen"
    assert [path.read_bytes() for path in [older, other_capture]] == originals


@pytest.mark.asyncio
@pytest.mark.parametrize("fields", [{"capture_id": "capture"}, {}], ids=["capture-id", "legacy-source"])
async def test_several_matches_refuse_projection_and_keep_pending_edit(archive, fields):
    database, service, root = archive
    paths = [write_sidecar(root, name, **fields) for name in ["one.md", "nested/two.md"]]
    originals = [path.read_bytes() for path in paths]
    receipt = await service.patch("capture", CapturePatch(note="pending"))
    assert receipt.metadataProjection == "failed"
    assert "several" in receipt.metadataError
    job = await database.get_job("job")
    assert job["metadata_projection"]["fields"] == {"notes": "pending"}
    assert job["metadata"]["sidecar_path"] == str(root / "original.md")
    assert [path.read_bytes() for path in paths] == originals


@pytest.mark.asyncio
async def test_no_match_keeps_existing_error_and_pending_state(archive):
    database, service, _ = archive
    receipt = await service.patch("capture", CapturePatch(note="pending"))
    assert receipt.metadataProjection == "failed"
    assert receipt.metadataError == MISSING
    job = await database.get_job("job")
    assert job["metadata_projection"]["fields"] == {"notes": "pending"}
    assert job["intent"]["user"]["note"] == "pending"


@pytest.mark.asyncio
async def test_fallback_skips_hidden_conflicting_malformed_and_oversized_headers(archive):
    _, service, root = archive
    write_sidecar(root, ".hidden.md", capture_id="capture")
    write_sidecar(root, ".hidden/nested.md", capture_id="capture")
    write_sidecar(root, "other.md", capture_id="other")
    (root / "malformed.md").write_text('---\nsource: [broken\n---\n')
    (root / "oversized.md").write_text('---\nsource: "' + URL + '"\nnotes: "' + "x" * (128 * 1024) + '"\n---\n')
    (root / "body-only.md").write_text('No front matter\n---\ncapture_id: capture\n---\n')
    receipt = await service.patch("capture", CapturePatch(note="pending"))
    assert receipt.metadataError == MISSING


@pytest.mark.asyncio
async def test_fallback_does_not_read_large_body_as_front_matter(archive):
    _, service, root = archive
    chosen = write_sidecar(root, "large-body.md", capture_id="capture")
    with chosen.open("ab") as stream:
        stream.write(b"\n" + b"x" * (128 * 1024) + b"\n---\ncapture_id: other\n---\n")
    receipt = await service.patch("capture", CapturePatch(note="found"))
    assert receipt.metadataProjection == "applied", receipt.metadataError
    assert read_base(chosen)["notes"] == "found"


@pytest.mark.asyncio
async def test_fallback_uses_storage_root_instead_of_database_directory(archive):
    database, _, root = archive
    storage_root = root / "storage"
    chosen = write_sidecar(storage_root, "moved.md", capture_id="capture")
    outside = write_sidecar(root, "outside-storage.md", capture_id="capture")
    original = outside.read_bytes()
    service = CaptureService(database, AsyncMock(), AsyncMock(), archive_root=storage_root)
    receipt = await service.patch("capture", CapturePatch(note="inside"))
    assert receipt.metadataProjection == "applied", receipt.metadataError
    assert read_base(chosen)["notes"] == "inside"
    assert outside.read_bytes() == original


@pytest.mark.asyncio
async def test_fallback_skips_symlinked_files_and_directories(archive):
    _, service, root = archive
    original = write_sidecar(root, ".originals/owned.md", capture_id="capture")
    (root / "linked.md").symlink_to(original)
    (root / "linked-directory").symlink_to(original.parent, target_is_directory=True)
    receipt = await service.patch("capture", CapturePatch(note="pending"))
    assert receipt.metadataError == MISSING
    assert read_base(original)["notes"] == "app note"


@pytest.mark.asyncio
async def test_edit_during_download_does_not_adopt_an_older_capture_of_the_same_url(tmp_path):
    database = Database(tmp_path / "archive.db")
    await database.initialize()
    try:
        await database.create_job("job", URL, capture_id="capture", intent={"user": {"tags": [], "note": ""}})
        older = write_sidecar(tmp_path, "2026-09/older-capture.md")
        original = older.read_bytes()
        receipt = await CaptureService(database, AsyncMock(), AsyncMock()).patch("capture", CapturePatch(note="pending"))
        job = await database.get_job("job")
        assert job["metadata_projection"]["bases"] == {"notes": [""]}
        assert "sidecar_path" not in (job.get("metadata") or {})
        assert older.read_bytes() == original
        assert receipt.metadataProjection != "applied"
    finally:
        await database.close()
