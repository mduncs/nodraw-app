"""Temp-fixture coverage for the recoverable media compatibility backfill."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import sqlite3

import pytest

from tools.media_compat_backfill import (
    BackfillEngine,
    BackfillError,
    SafeProcessGuard,
)


VP9_ID = "11111111-1111-4111-8111-111111111111"
HEVC_ID = "22222222-2222-4222-8222-222222222222"
CACHE_ONLY_ID = "44444444-4444-4444-8444-444444444444"
ALIAS_ID = "33333333-3333-4333-8333-333333333333"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@dataclass(frozen=True)
class FakeProbe:
    kind: str
    duration_seconds: float
    streams: tuple[dict[str, object], ...]


@dataclass(frozen=True)
class FakePlan:
    action: str
    operation: str
    output_suffix: str
    video_codec: str = "copy"
    audio_codec: str = "copy"
    lossy: bool = False


@dataclass
class FakeResult:
    media_path: Path
    preserved_source: Path | None
    plan: FakePlan
    payload: dict[str, object]

    def provenance(self) -> dict[str, object]:
        return self.payload


class FakeNormalizer:
    def __init__(
        self,
        *,
        operation: str,
        output_suffix: str,
        codec: str,
        changed_duration: bool = False,
        action: str = "remux",
        video_codec: str = "copy",
        audio_codec: str = "copy",
        lossy: bool = False,
    ) -> None:
        self.operation = operation
        self.output_suffix = output_suffix
        self.codec = codec
        self.changed_duration = changed_duration
        self.action = action
        self.video_codec = video_codec
        self.audio_codec = audio_codec
        self.lossy = lossy
        self.normalize_calls = 0

    def probe(self, path: Path) -> FakeProbe:
        kind = "normalized" if path.read_bytes().startswith(b"normalized:") else "source"
        return FakeProbe(
            kind=kind,
            duration_seconds=3.0,
            streams=(
                {
                    "type": "video",
                    "codec": self.codec,
                    "tag": "hvc1" if kind == "normalized" and self.codec == "hevc" else "hev1",
                    "width": 32,
                    "height": 18,
                },
                {"type": "audio", "codec": "opus", "width": None, "height": None},
            ),
        )
    def classify(self, probe: FakeProbe) -> FakePlan:
        # This assertion catches the concrete-probe-before-serialization regression.
        assert isinstance(probe, FakeProbe)
        if probe.kind == "normalized":
            return FakePlan("keep", f"keep{self.output_suffix}", self.output_suffix)
        return FakePlan(
            self.action,
            self.operation,
            self.output_suffix,
            video_codec=self.video_codec,
            audio_codec=self.audio_codec,
            lossy=self.lossy,
        )

    def normalize_staged(self, path: Path) -> FakeResult:
        self.normalize_calls += 1
        before = self.probe(path)
        target = path.parent / f"output{self.output_suffix}"
        target.write_bytes(b"normalized:" + path.read_bytes())
        preserved = None
        if self.lossy:
            preserved = path.parent / "preserved-source.bin"
            preserved.write_bytes(path.read_bytes())
        after = self.probe(target)
        output_duration = 3.25 if self.changed_duration else after.duration_seconds
        plan = self.classify(before)
        return FakeResult(
            media_path=target,
            preserved_source=preserved,
            plan=plan,
            payload={
                "schema_version": 1,
                "action": self.action,
                "operation": self.operation,
                "lossy": self.lossy,
                "source": {
                    "duration_seconds": before.duration_seconds,
                    "streams": list(before.streams),
                },
                "output": {
                    "duration_seconds": output_duration,
                    "streams": list(after.streams),
                },
            },
        )


class BlockingGuard:
    def __init__(self, expected: set[Path]) -> None:
        self.expected = expected

    def assert_offline(self, database_paths) -> None:
        assert {Path(path) for path in database_paths} == self.expected
        raise BackfillError("offline precondition failed: fixture writer is active")


def _create_media_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        PRAGMA journal_mode=WAL;
        PRAGMA user_version=32;
        CREATE TABLE media_items (
          id TEXT PRIMARY KEY, mediaFilesJSON TEXT NOT NULL, metadataFileString TEXT NOT NULL,
          deletedAt TEXT, sourceURL TEXT,
          ocrText TEXT, ocrBoundingBoxesJSON TEXT, dominantColorsJSON TEXT,
          perceptualHash TEXT, saliencyRectJSON TEXT,
          pipeline_status TEXT, pipeline_version INTEGER, generatedCaption TEXT,
          pipeline_retry_count INTEGER, pipeline_last_error TEXT, pipeline_failed_at TEXT,
          video_understanding_status TEXT, video_understanding_version INTEGER,
          video_understanding_retry_count INTEGER, video_understanding_last_error TEXT,
          video_understanding_failed_at TEXT,
          transcription_status TEXT, transcription_version INTEGER,
          transcription_retry_count INTEGER, transcription_last_error TEXT,
          transcription_failed_at TEXT
        );
        CREATE TABLE archive_scan_cache (
          metadataFileString TEXT PRIMARY KEY, itemId TEXT,
          metadataFileModifiedAt REAL, metadataFileSize INTEGER,
          mediaFilesJSON TEXT, contextImageString TEXT
        );
        CREATE TABLE transcript_segments (
          item_id TEXT, segment_index INTEGER, start_time REAL, end_time REAL,
          text TEXT, source_path TEXT
        );
        CREATE TABLE video_segments (
          item_id TEXT, media_file_index INTEGER, segment_index INTEGER,
          text TEXT, source_path TEXT
        );
        CREATE TABLE media_attributes (item_id TEXT, attribute TEXT, value TEXT);
        CREATE TABLE clip_vectors (itemId TEXT, vector BLOB);
        CREATE TABLE media_file_ocr (
          item_id TEXT, file_index INTEGER, text TEXT, file_url TEXT
        );
        CREATE TABLE media_colors (item_id TEXT, color TEXT);
        """
    )
    connection.commit()
    connection.close()


def _create_archive_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        CREATE TABLE archive_jobs (
          id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT, page_title TEXT,
          page_url TEXT, created_at TEXT, completed_at TEXT, file_path TEXT,
          file_size INTEGER, file_hash TEXT, metadata TEXT, error TEXT,
          capture_id TEXT, fingerprint TEXT, capture_kind TEXT, intent_json TEXT
        );
        CREATE TABLE media_files (
          id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, url TEXT,
          media_type TEXT, mime_type TEXT, title TEXT, description TEXT,
          author TEXT, file_size INTEGER, duration INTEGER, width INTEGER,
          height INTEGER, created_at TEXT, archived_at TEXT, accessed_at TEXT,
          tags TEXT, metadata TEXT
        );
        """
    )
    connection.commit()
    connection.close()


def _add_item(
    database: Path,
    *,
    item_id: str,
    media: Path,
    sidecar: Path,
    derived: bool = True,
) -> None:
    connection = sqlite3.connect(database)
    connection.execute(
        """
        INSERT INTO media_items VALUES (
          ?, ?, ?, NULL, ?,
          'ocr words', '[1]', '["#fff"]', 'phash', '[0,0,1,1]',
          'failed', 7, 'generated caption', 2, 'pipeline error', '2026-01-01',
          'failed', 5, 3, 'video error', '2026-01-02',
          'complete', 4, 0, NULL, NULL
        )
        """,
        (item_id, json.dumps([str(media)]), str(sidecar), media.resolve().as_uri()),
    )
    if derived:
        connection.executemany(
            "INSERT INTO transcript_segments VALUES (?, ?, ?, ?, ?, ?)",
            [
                (item_id, 0, 0.0, 1.0, "first words", str(media)),
                (item_id, 1, 1.0, 2.0, "second words", str(media)),
            ],
        )
        connection.execute(
            "INSERT INTO video_segments VALUES (?, 0, 0, 'visual words', ?)",
            (item_id, str(media)),
        )
        connection.execute("INSERT INTO media_attributes VALUES (?, 'mood', 'quiet')", (item_id,))
        connection.execute("INSERT INTO clip_vectors VALUES (?, ?)", (item_id, b"vector"))
        connection.execute(
            "INSERT INTO media_file_ocr VALUES (?, 1, 'context text', '/context.png')",
            (item_id,),
        )
        connection.execute("INSERT INTO media_colors VALUES (?, '#fff')", (item_id,))
        info = sidecar.stat()
        connection.execute(
            "INSERT INTO archive_scan_cache VALUES (?, ?, ?, ?, ?, ?)",
            (
                str(sidecar),
                item_id,
                info.st_mtime,
                info.st_size,
                json.dumps([str(media)]),
                "/context.png",
            ),
        )
    connection.commit()
    connection.close()


def _sidecar(path: Path, media: Path) -> bytes:
    content = (
        "---\n"
        "title: Keep  Spacing # user comment\n"
        f"source: {media.resolve().as_uri()}\n"
        f"file_size: {media.stat().st_size} # exact bytes\n"
        "custom: [a,  b]\n"
        "---\n"
        f"before ![[{media.name}|clip]] after\n"
    ).encode()
    path.write_bytes(content)
    return content


def _candidate(
    *,
    item_id: str,
    source: Path,
    operation: str,
    suffix: str,
    policy: str,
    archive_job_ids: list[str] | None = None,
    media_file_ids: list[int] | None = None,
    action: str = "remux",
    video_codec: str = "copy",
    audio_codec: str = "copy",
    lossy: bool = False,
) -> dict[str, object]:
    return {
        "item_id": item_id,
        "file_index": 0,
        "source_sha256": _sha256(source),
        "target_suffix": suffix,
        "derived_policy": policy,
        "required_plan": {
            "action": action,
            "operation": operation,
            "output_suffix": suffix,
            "video_codec": video_codec,
            "audio_codec": audio_codec,
            "lossy": lossy,
        },
        "required_provenance": {"operation": operation, "lossy": lossy},
        "required_post_probe": {"kind": "normalized"},
        "required_post_plan": {"action": "keep", "output_suffix": suffix},
        "server_references": {
            "archive_jobs": archive_job_ids or [],
            "media_files": media_file_ids or [],
        },
    }


def _write_allowlist(path: Path, candidates: list[dict[str, object]], cache_actions=()) -> None:
    path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "archive_database_required": True,
                "candidates": candidates,
                "cache_only_actions": list(cache_actions),
            }
        )
    )


def _fixture_roots(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    archive = tmp_path / "archive"
    app_support = tmp_path / "app-support"
    archive.mkdir()
    (app_support / "thumbnails").mkdir(parents=True)
    (app_support / "pipeline-store").mkdir()
    media_db = app_support / "media.sqlite"
    archive_db = archive / "archive.db"
    _create_media_database(media_db)
    _create_archive_database(archive_db)
    return archive, app_support, media_db, archive_db


def test_vp9_apply_preserves_derived_state_updates_scan_cache_and_handles_cache_only(tmp_path):
    archive, app_support, media_db, archive_db = _fixture_roots(tmp_path)
    source = archive / "vp9 clip.mp4"
    source.write_bytes(b"vp9-source")
    sidecar = archive / "vp9 clip.md"
    original_sidecar = _sidecar(sidecar, source)
    _add_item(media_db, item_id=VP9_ID, media=source, sidecar=sidecar)

    vp9_thumb = app_support / "thumbnails" / f"{VP9_ID}-sm.jpg"
    vp9_thumb.write_bytes(b"old-vp9-thumbnail")
    pipeline_cache = app_support / "pipeline-store" / f"{VP9_ID}.json"
    pipeline_cache.write_bytes(b"preserve-partial-pipeline")

    healthy = archive / "healthy.mp4"
    healthy.write_bytes(b"healthy-source")
    healthy_sidecar = archive / "healthy.md"
    healthy_sidecar_bytes = _sidecar(healthy_sidecar, healthy)
    _add_item(
        media_db,
        item_id=CACHE_ONLY_ID,
        media=healthy,
        sidecar=healthy_sidecar,
        derived=False,
    )
    reviewed_cache = []
    for name in ("sm", "md", *(f"preview-{index}" for index in range(10))):
        path = app_support / "thumbnails" / f"{CACHE_ONLY_ID}-{name}.jpg"
        path.write_bytes(f"cache:{name}".encode())
        reviewed_cache.append({"name": path.name, "sha256": _sha256(path)})

    allowlist = tmp_path / "allowlist.json"
    manifest = tmp_path / "manifest.json"
    _write_allowlist(
        allowlist,
        [
            _candidate(
                item_id=VP9_ID,
                source=source,
                operation="remux_vp_video_to_webm",
                suffix=".webm",
                policy="vp9_webm_stream_equivalent",
            )
        ],
        [
            {
                "item_id": CACHE_ONLY_ID,
                "action": "invalidate_thumbnails",
                "expected_files": reviewed_cache,
            }
        ],
    )
    normalizer = FakeNormalizer(
        operation="remux_vp_video_to_webm", output_suffix=".webm", codec="vp9"
    )
    engine = BackfillEngine(normalizer=normalizer, process_guard=SafeProcessGuard())

    planned = engine.plan(
        database_path=media_db,
        archive_database_path=archive_db,
        archive_root=archive,
        allowlist_path=allowlist,
        manifest_path=manifest,
        recovery_root=archive / ".recovery",
    )
    assert planned["groups"][0]["references"][0]["derived_policy_expanded"][
        "reset_general_pipeline"
    ] is False
    assert planned["groups"][0]["references"][0]["derived_policy_expanded"][
        "reset_vision"
    ] is False
    assert planned["cache_only_actions"][0]["item_id"] == CACHE_ONLY_ID
    assert os.stat(manifest).st_mode & 0o777 == 0o444

    result = engine.apply(manifest)
    assert result["phase"] == "complete"
    assert normalizer.normalize_calls == 1
    target = source.with_suffix(".webm")
    assert not source.exists()
    assert target.read_bytes() == b"normalized:vp9-source"
    assert not vp9_thumb.exists()
    assert pipeline_cache.read_bytes() == b"preserve-partial-pipeline"
    assert not any((app_support / "thumbnails" / entry["name"]).exists() for entry in reviewed_cache)
    assert healthy.read_bytes() == b"healthy-source"
    assert healthy_sidecar.read_bytes() == healthy_sidecar_bytes

    connection = sqlite3.connect(media_db)
    connection.row_factory = sqlite3.Row
    row = connection.execute("SELECT * FROM media_items WHERE id=?", (VP9_ID,)).fetchone()
    assert json.loads(row["mediaFilesJSON"]) == [str(target)]
    assert row["pipeline_status"] == "failed"
    assert row["video_understanding_status"] == "failed"
    assert row["transcription_status"] == "complete"
    assert row["generatedCaption"] == "generated caption"
    assert row["ocrText"] == "ocr words"
    assert [
        tuple(segment)
        for segment in connection.execute(
            "SELECT text, source_path FROM transcript_segments WHERE item_id=? ORDER BY segment_index",
            (VP9_ID,),
        ).fetchall()
    ] == [("first words", str(target)), ("second words", str(target))]
    assert connection.execute(
        "SELECT count(*) FROM media_attributes WHERE item_id=?", (VP9_ID,)
    ).fetchone()[0] == 1
    scan = connection.execute(
        "SELECT * FROM archive_scan_cache WHERE itemId=?", (VP9_ID,)
    ).fetchone()
    sidecar_info = sidecar.stat()
    assert scan["mediaFilesJSON"] == json.dumps([str(target)], separators=(",", ":"))
    assert scan["metadataFileModifiedAt"] == sidecar_info.st_mtime
    assert scan["metadataFileSize"] == sidecar_info.st_size
    assert scan["contextImageString"] == "/context.png"
    connection.close()

    updated_sidecar = sidecar.read_text()
    assert "title: Keep  Spacing # user comment" in updated_sidecar
    assert "custom: [a,  b]" in updated_sidecar
    assert f"![[{target.name}|clip]]" in updated_sidecar
    assert "nodraw_media_compat_backfill:" in updated_sidecar
    assert engine.verify(manifest)["ok"] is True
    assert engine.apply(manifest)["phase"] == "complete"
    assert normalizer.normalize_calls == 1

    rolled_back = engine.rollback(manifest)
    assert rolled_back["phase"] == "rolled_back"
    assert source.read_bytes() == b"vp9-source"
    assert not target.exists()
    assert sidecar.read_bytes() == original_sidecar
    assert vp9_thumb.read_bytes() == b"old-vp9-thumbnail"
    assert pipeline_cache.read_bytes() == b"preserve-partial-pipeline"
    assert healthy_sidecar.read_bytes() == healthy_sidecar_bytes
    assert all((app_support / "thumbnails" / entry["name"]).is_file() for entry in reviewed_cache)


def test_hevc_updates_and_rolls_back_archive_database_without_touching_transcripts(tmp_path):
    archive, app_support, media_db, archive_db = _fixture_roots(tmp_path)
    source = archive / "hevc.mp4"
    source.write_bytes(b"hevc-source")
    sidecar = archive / "hevc.md"
    original_sidecar = _sidecar(sidecar, source)
    _add_item(media_db, item_id=HEVC_ID, media=source, sidecar=sidecar)
    job_id = "archive-job-hevc"
    metadata = {"files": [source.name], "duration": 3.0, "vcodec": "hev1"}
    archive_connection = sqlite3.connect(archive_db)
    archive_connection.execute(
        "INSERT INTO archive_jobs (id,url,status,file_path,file_size,file_hash,metadata) VALUES (?,?,?,?,?,?,?)",
        (
            job_id,
            "https://example.invalid/video",
            "completed",
            str(source),
            source.stat().st_size,
            None,
            json.dumps(metadata),
        ),
    )
    archive_connection.execute(
        """
        INSERT INTO media_files
          (id,path,media_type,mime_type,file_size,duration,width,height,tags,metadata)
        VALUES (2377,?,'video',NULL,?,3,32,18,'[]',?)
        """,
        (str(source), source.stat().st_size, json.dumps(metadata)),
    )
    archive_connection.commit()
    original_job = archive_connection.execute(
        "SELECT file_path,file_size,file_hash,metadata FROM archive_jobs WHERE id=?", (job_id,)
    ).fetchone()
    original_media = archive_connection.execute(
        "SELECT path,mime_type,file_size,metadata FROM media_files WHERE id=2377"
    ).fetchone()
    archive_connection.close()

    allowlist = tmp_path / "allowlist.json"
    manifest = tmp_path / "manifest.json"
    _write_allowlist(
        allowlist,
        [
            _candidate(
                item_id=HEVC_ID,
                source=source,
                operation="repair_hevc_hvc1_tag",
                suffix=".mp4",
                policy="hevc_tag_repair_stream_equivalent",
                archive_job_ids=[job_id],
                media_file_ids=[2377],
            )
        ],
    )
    normalizer = FakeNormalizer(
        operation="repair_hevc_hvc1_tag", output_suffix=".mp4", codec="hevc"
    )
    engine = BackfillEngine(normalizer=normalizer, process_guard=SafeProcessGuard())
    engine.plan(
        database_path=media_db,
        archive_database_path=archive_db,
        archive_root=archive,
        allowlist_path=allowlist,
        manifest_path=manifest,
        recovery_root=archive / ".recovery",
    )
    engine.apply(manifest)

    connection = sqlite3.connect(media_db)
    row = connection.execute(
        """
        SELECT pipeline_status, video_understanding_status, transcription_status,
               generatedCaption, ocrText FROM media_items WHERE id=?
        """,
        (HEVC_ID,),
    ).fetchone()
    assert row == ("failed", "none", "complete", "generated caption", "ocr words")
    assert connection.execute(
        "SELECT count(*) FROM video_segments WHERE item_id=?", (HEVC_ID,)
    ).fetchone()[0] == 0
    assert connection.execute(
        "SELECT group_concat(text,'|') FROM transcript_segments WHERE item_id=? ORDER BY segment_index",
        (HEVC_ID,),
    ).fetchone()[0] == "first words|second words"
    connection.close()

    archive_connection = sqlite3.connect(archive_db)
    job = archive_connection.execute(
        "SELECT file_path,file_size,file_hash,metadata FROM archive_jobs WHERE id=?", (job_id,)
    ).fetchone()
    media = archive_connection.execute(
        "SELECT path,mime_type,file_size,metadata FROM media_files WHERE id=2377"
    ).fetchone()
    assert job[0] == str(source)
    assert job[1] == source.stat().st_size
    assert job[2] == _sha256(source)
    assert json.loads(job[3])["files"] == [source.name]
    assert json.loads(job[3])["nodraw_media_normalizations"][0]["item_id"] == HEVC_ID
    assert media[:3] == (str(source), "video/mp4", source.stat().st_size)
    assert json.loads(media[3])["nodraw_media_normalizations"][0]["item_id"] == HEVC_ID
    archive_connection.close()
    assert engine.verify(manifest)["ok"] is True

    engine.rollback(manifest)
    archive_connection = sqlite3.connect(archive_db)
    assert archive_connection.execute(
        "SELECT file_path,file_size,file_hash,metadata FROM archive_jobs WHERE id=?", (job_id,)
    ).fetchone() == original_job
    assert archive_connection.execute(
        "SELECT path,mime_type,file_size,metadata FROM media_files WHERE id=2377"
    ).fetchone() == original_media
    archive_connection.close()
    assert source.read_bytes() == b"hevc-source"
    assert sidecar.read_bytes() == original_sidecar


def test_stream_equivalence_policy_fails_closed_before_publish_on_timeline_change(tmp_path):
    archive, _app_support, media_db, archive_db = _fixture_roots(tmp_path)
    source = archive / "vp9.mp4"
    source.write_bytes(b"vp9-source")
    sidecar = archive / "vp9.md"
    original_sidecar = _sidecar(sidecar, source)
    _add_item(media_db, item_id=VP9_ID, media=source, sidecar=sidecar)
    allowlist = tmp_path / "allowlist.json"
    manifest = tmp_path / "manifest.json"
    _write_allowlist(
        allowlist,
        [
            _candidate(
                item_id=VP9_ID,
                source=source,
                operation="remux_vp_video_to_webm",
                suffix=".webm",
                policy="vp9_webm_stream_equivalent",
            )
        ],
    )
    engine = BackfillEngine(
        normalizer=FakeNormalizer(
            operation="remux_vp_video_to_webm",
            output_suffix=".webm",
            codec="vp9",
            changed_duration=True,
        ),
        process_guard=SafeProcessGuard(),
    )
    engine.plan(
        database_path=media_db,
        archive_database_path=archive_db,
        archive_root=archive,
        allowlist_path=allowlist,
        manifest_path=manifest,
        recovery_root=archive / ".recovery",
    )

    with pytest.raises(BackfillError, match="changed the media timeline"):
        engine.apply(manifest)

    assert source.read_bytes() == b"vp9-source"
    assert not source.with_suffix(".webm").exists()
    assert sidecar.read_bytes() == original_sidecar


def test_hard_link_group_requires_every_alias_and_normalizes_once(tmp_path):
    archive, _app_support, media_db, archive_db = _fixture_roots(tmp_path)
    first = archive / "first.mp4"
    second = archive / "second.mp4"
    first.write_bytes(b"shared-vp9")
    os.link(first, second)
    first_sidecar = archive / "first.md"
    second_sidecar = archive / "second.md"
    _sidecar(first_sidecar, first)
    _sidecar(second_sidecar, second)
    _add_item(media_db, item_id=VP9_ID, media=first, sidecar=first_sidecar)
    _add_item(media_db, item_id=ALIAS_ID, media=second, sidecar=second_sidecar)
    first_candidate = _candidate(
        item_id=VP9_ID,
        source=first,
        operation="remux_vp_video_to_webm",
        suffix=".webm",
        policy="vp9_webm_stream_equivalent",
    )
    second_candidate = _candidate(
        item_id=ALIAS_ID,
        source=second,
        operation="remux_vp_video_to_webm",
        suffix=".webm",
        policy="vp9_webm_stream_equivalent",
    )
    allowlist = tmp_path / "allowlist.json"
    manifest = tmp_path / "manifest.json"
    _write_allowlist(allowlist, [first_candidate])
    normalizer = FakeNormalizer(
        operation="remux_vp_video_to_webm", output_suffix=".webm", codec="vp9"
    )
    engine = BackfillEngine(normalizer=normalizer, process_guard=SafeProcessGuard())

    with pytest.raises(BackfillError, match="unreviewed DB references"):
        engine.plan(
            database_path=media_db,
            archive_database_path=archive_db,
            archive_root=archive,
            allowlist_path=allowlist,
            manifest_path=manifest,
            recovery_root=archive / ".recovery",
        )

    _write_allowlist(allowlist, [first_candidate, second_candidate])
    planned = engine.plan(
        database_path=media_db,
        archive_database_path=archive_db,
        archive_root=archive,
        allowlist_path=allowlist,
        manifest_path=manifest,
        recovery_root=archive / ".recovery",
    )
    assert planned["candidate_reference_count"] == 2
    assert planned["candidate_inode_group_count"] == 1
    engine.apply(manifest)
    first_target = first.with_suffix(".webm")
    second_target = second.with_suffix(".webm")
    assert normalizer.normalize_calls == 1
    assert (first_target.stat().st_dev, first_target.stat().st_ino) == (
        second_target.stat().st_dev,
        second_target.stat().st_ino,
    )
    assert first_target.stat().st_nlink == 2
    engine.rollback(manifest)
    assert (first.stat().st_dev, first.stat().st_ino) == (
        second.stat().st_dev,
        second.stat().st_ino,
    )
    assert first.stat().st_nlink == 2


def test_gif_policy_invalidates_visual_derivatives_but_preserves_transcript(tmp_path):
    archive, app_support, media_db, archive_db = _fixture_roots(tmp_path)
    source = archive / "misnamed-gif.mp4"
    source.write_bytes(b"GIF89a-source")
    sidecar = archive / "misnamed-gif.md"
    _sidecar(sidecar, source)
    _add_item(media_db, item_id=VP9_ID, media=source, sidecar=sidecar)
    thumb = app_support / "thumbnails" / f"{VP9_ID}-md.jpg"
    pipeline_cache = app_support / "pipeline-store" / f"{VP9_ID}.json"
    thumb.write_bytes(b"gif-thumb")
    pipeline_cache.write_bytes(b"gif-pipeline")
    allowlist = tmp_path / "allowlist.json"
    manifest = tmp_path / "manifest.json"
    _write_allowlist(
        allowlist,
        [
            _candidate(
                item_id=VP9_ID,
                source=source,
                operation="gif_to_h264_mp4",
                suffix=".mp4",
                policy="gif_visual_conversion",
                action="transcode",
                video_codec="libx264",
                audio_codec="none",
                lossy=True,
            )
        ],
    )
    normalizer = FakeNormalizer(
        operation="gif_to_h264_mp4",
        output_suffix=".mp4",
        codec="gif",
        action="transcode",
        video_codec="libx264",
        audio_codec="none",
        lossy=True,
    )
    engine = BackfillEngine(normalizer=normalizer, process_guard=SafeProcessGuard())
    planned = engine.plan(
        database_path=media_db,
        archive_database_path=archive_db,
        archive_root=archive,
        allowlist_path=allowlist,
        manifest_path=manifest,
        recovery_root=archive / ".recovery",
    )
    policy = planned["groups"][0]["references"][0]["derived_policy_expanded"]
    assert policy["reset_general_pipeline"] is True
    assert policy["reset_vision"] is True
    assert policy["reset_video_understanding"] is True
    assert policy["preserve_transcription"] is True
    assert policy["invalidate_thumbnails"] is True
    assert policy["invalidate_pipeline_store"] is True

    engine.apply(manifest)
    connection = sqlite3.connect(media_db)
    row = connection.execute(
        """
        SELECT pipeline_status, video_understanding_status, transcription_status,
               generatedCaption, ocrText FROM media_items WHERE id=?
        """,
        (VP9_ID,),
    ).fetchone()
    assert row == ("none", "none", "complete", "generated caption", None)
    assert connection.execute(
        "SELECT group_concat(text,'|') FROM transcript_segments WHERE item_id=? ORDER BY segment_index",
        (VP9_ID,),
    ).fetchone()[0] == "first words|second words"
    assert connection.execute(
        "SELECT count(*) FROM media_file_ocr WHERE item_id=?", (VP9_ID,)
    ).fetchone()[0] == 0
    connection.close()
    assert not thumb.exists()
    assert not pipeline_cache.exists()


def test_apply_checks_both_database_writers_before_creating_recovery_state(tmp_path):
    archive, _app_support, media_db, archive_db = _fixture_roots(tmp_path)
    source = archive / "guarded.mp4"
    source.write_bytes(b"vp9-source")
    sidecar = archive / "guarded.md"
    original_sidecar = _sidecar(sidecar, source)
    _add_item(media_db, item_id=VP9_ID, media=source, sidecar=sidecar)
    allowlist = tmp_path / "allowlist.json"
    manifest = tmp_path / "manifest.json"
    _write_allowlist(
        allowlist,
        [
            _candidate(
                item_id=VP9_ID,
                source=source,
                operation="remux_vp_video_to_webm",
                suffix=".webm",
                policy="vp9_webm_stream_equivalent",
            )
        ],
    )
    normalizer = FakeNormalizer(
        operation="remux_vp_video_to_webm", output_suffix=".webm", codec="vp9"
    )
    planning_engine = BackfillEngine(
        normalizer=normalizer, process_guard=SafeProcessGuard()
    )
    planned = planning_engine.plan(
        database_path=media_db,
        archive_database_path=archive_db,
        archive_root=archive,
        allowlist_path=allowlist,
        manifest_path=manifest,
        recovery_root=archive / ".recovery",
    )
    applying_engine = BackfillEngine(
        normalizer=normalizer,
        process_guard=BlockingGuard({media_db.resolve(), archive_db.resolve()}),
    )

    with pytest.raises(BackfillError, match="offline precondition failed"):
        applying_engine.apply(manifest)

    assert source.read_bytes() == b"vp9-source"
    assert sidecar.read_bytes() == original_sidecar
    assert not (archive / ".recovery" / planned["run_id"]).exists()
