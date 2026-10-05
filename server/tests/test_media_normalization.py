"""Focused tests for conditional Mac-playback media normalization."""

from __future__ import annotations

import asyncio
from concurrent.futures import Future, ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
from unittest.mock import patch

import pytest

from downloaders.base import DownloadResult
from media_normalization import (
    MediaNormalizationError,
    MediaNormalizer,
    MediaProbe,
    NormalizationAction,
    StreamProbe,
    classify_media,
)


FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
HAS_MEDIA_TOOLS = bool(FFMPEG and FFPROBE)


def _probe(
    *,
    suffix: str = ".mp4",
    container: tuple[str, ...] = ("mov", "mp4"),
    video_codec: str = "h264",
    video_tag: str = "avc1",
    audio_codec: str | None = None,
    gif_payload: bool = False,
    webm_payload: bool = False,
    extra_stream: bool = False,
) -> MediaProbe:
    streams = [
        StreamProbe(
            index=0,
            codec_type="video",
            codec_name=video_codec,
            codec_tag=video_tag,
            width=16,
            height=16,
        )
    ]
    if audio_codec:
        streams.append(StreamProbe(index=1, codec_type="audio", codec_name=audio_codec))
    if extra_stream:
        streams.append(StreamProbe(index=2, codec_type="subtitle", codec_name="mov_text"))
    return MediaProbe(
        path_suffix=suffix,
        format_names=frozenset(container),
        streams=tuple(streams),
        duration=1.0,
        size=123,
        gif_payload=gif_payload,
        webm_payload=webm_payload,
    )


@pytest.mark.parametrize(
    ("probe", "action", "operation", "lossy", "audio_codec"),
    [
        (_probe(), NormalizationAction.KEEP, "keep_mp4", False, "copy"),
        (
            _probe(video_codec="av1", video_tag="av01"),
            NormalizationAction.KEEP,
            "keep_mp4",
            False,
            "copy",
        ),
        (
            _probe(video_codec="vp8", video_tag="vp08"),
            NormalizationAction.REMUX,
            "remux_vp_video_to_webm",
            False,
            "copy",
        ),
        (
            _probe(video_codec="vp9", video_tag="vp09", audio_codec="aac"),
            NormalizationAction.REMUX,
            "remux_vp_video_to_webm",
            True,
            "libopus",
        ),
        (
            _probe(
                suffix=".webm",
                container=("matroska", "webm"),
                video_codec="vp9",
                video_tag="[0][0][0][0]",
                audio_codec="opus",
                webm_payload=True,
            ),
            NormalizationAction.KEEP,
            "keep_webm",
            False,
            "copy",
        ),
        (
            _probe(video_codec="hevc", video_tag="hev1"),
            NormalizationAction.REMUX,
            "repair_hevc_hvc1_tag",
            False,
            "copy",
        ),
        (
            _probe(video_codec="hevc", video_tag="hvc1"),
            NormalizationAction.KEEP,
            "keep_hvc1_mp4",
            False,
            "copy",
        ),
        (
            _probe(video_codec="theora", video_tag="theo"),
            NormalizationAction.TRANSCODE,
            "fallback_to_h264_aac_mp4",
            True,
            "copy",
        ),
        (
            _probe(video_codec="theora", video_tag="theo", audio_codec="opus"),
            NormalizationAction.TRANSCODE,
            "fallback_to_h264_aac_mp4",
            True,
            "aac",
        ),
        (
            _probe(gif_payload=True, video_codec="gif", video_tag="[0][0][0][0]"),
            NormalizationAction.TRANSCODE,
            "gif_to_h264_mp4",
            True,
            "none",
        ),
    ],
)
def test_compatibility_policy_chooses_least_lossy_path(
    probe,
    action,
    operation,
    lossy,
    audio_codec,
):
    plan = classify_media(probe)

    assert plan.action == action
    assert plan.operation == operation
    assert plan.lossy is lossy
    assert plan.audio_codec == audio_codec


def test_true_webm_with_misleading_suffix_is_byte_identical_rename():
    plan = classify_media(
        _probe(
            suffix=".mp4",
            container=("matroska", "webm"),
            video_codec="vp9",
            video_tag="[0][0][0][0]",
            audio_codec="opus",
            webm_payload=True,
        )
    )

    assert plan.action == NormalizationAction.RENAME
    assert plan.output_suffix == ".webm"
    assert plan.lossy is False


def test_matroska_doctype_is_not_assumed_to_be_true_webm():
    plan = classify_media(
        _probe(
            suffix=".webm",
            container=("matroska", "webm"),
            video_codec="vp9",
            video_tag="[0][0][0][0]",
            audio_codec="opus",
            webm_payload=False,
        )
    )

    assert plan.action == NormalizationAction.REMUX
    assert plan.operation == "remux_vp_video_to_webm"


def test_native_iso_payload_with_misleading_suffix_is_renamed_for_player_routing():
    plan = classify_media(_probe(suffix=".webm"))

    assert plan.action == NormalizationAction.RENAME
    assert plan.output_suffix == ".mp4"


def test_hev1_remux_preserves_source_when_unmapped_streams_would_be_dropped():
    plan = classify_media(
        _probe(video_codec="hevc", video_tag="hev1", extra_stream=True)
    )

    assert plan.action == NormalizationAction.REMUX
    assert plan.video_tag == "hvc1"
    assert plan.lossy is True


def test_hev1_transform_stream_copies_video_and_retags_hvc1(temp_storage_dir):
    source = temp_storage_dir / ".hev1.mp4"
    destination = temp_storage_dir / ".normalized.mp4"
    source.write_bytes(b"fixture")
    plan = classify_media(_probe(video_codec="hevc", video_tag="hev1"))

    with (
        patch("media_normalization.shutil.which", return_value="/fake/ffmpeg"),
        patch.object(MediaNormalizer, "_run_ffmpeg") as run_ffmpeg,
    ):
        MediaNormalizer()._transform(source, destination, plan)

    command = run_ffmpeg.call_args.args[0]
    assert command[command.index("-c:v") + 1] == "copy"
    assert command[command.index("-tag:v") + 1] == "hvc1"
    assert "libx264" not in command


def test_missing_video_stream_is_rejected():
    probe = MediaProbe(
        path_suffix=".mp4",
        format_names=frozenset({"mov", "mp4"}),
        streams=(StreamProbe(index=0, codec_type="audio", codec_name="aac"),),
    )

    with pytest.raises(MediaNormalizationError, match="video stream"):
        classify_media(probe)


def _run_ffmpeg(*arguments: str) -> None:
    if not FFMPEG:
        pytest.skip("ffmpeg is required for media fixture generation")
    completed = subprocess.run(
        [FFMPEG, "-nostdin", "-v", "error", "-y", *arguments],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stderr


def _make_h264_mp4(path: Path) -> bytes:
    _run_ffmpeg(
        "-f", "lavfi",
        "-i", "color=c=red:s=16x16:r=5:d=0.4",
        "-an",
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-f", "mp4",
        str(path),
    )
    return path.read_bytes()


def _make_vp9_aac_mp4(path: Path) -> bytes:
    _run_ffmpeg(
        "-f", "lavfi",
        "-i", "testsrc=size=16x16:rate=5:duration=0.4",
        "-f", "lavfi",
        "-i", "sine=frequency=1000:duration=0.4",
        "-shortest",
        "-c:v", "libvpx-vp9",
        "-deadline", "realtime",
        "-cpu-used", "8",
        "-b:v", "100k",
        "-c:a", "aac",
        "-f", "mp4",
        str(path),
    )
    return path.read_bytes()


def _make_odd_gif(path: Path) -> bytes:
    _run_ffmpeg(
        "-f", "lavfi",
        "-i", "testsrc=size=15x17:rate=5:duration=0.4",
        "-an",
        "-f", "gif",
        str(path),
    )
    return path.read_bytes()


def _make_opus_webm(path: Path) -> bytes:
    _run_ffmpeg(
        "-f", "lavfi",
        "-i", "sine=frequency=880:duration=0.25",
        "-vn",
        "-c:a", "libopus",
        "-f", "webm",
        str(path),
    )
    return path.read_bytes()


def _make_pcm_wav(path: Path) -> bytes:
    _run_ffmpeg(
        "-f", "lavfi",
        "-i", "sine=frequency=440:duration=0.25",
        "-vn",
        "-c:a", "pcm_s16le",
        str(path),
    )
    return path.read_bytes()


@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
def test_native_mp4_noop_is_byte_identical_and_integrity_checked(temp_storage_dir):
    path = temp_storage_dir / ".native.mp4"
    original = _make_h264_mp4(path)

    result = MediaNormalizer().normalize_staged(path)

    assert result.plan.action == NormalizationAction.KEEP
    assert result.media_path == path
    assert result.preserved_source is None
    assert path.read_bytes() == original


@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
def test_vp9_mp4_copies_video_transcodes_only_audio_and_preserves_source(temp_storage_dir):
    path = temp_storage_dir / ".vp9-with-aac.mp4"
    original = _make_vp9_aac_mp4(path)
    original_sha256 = hashlib.sha256(original).hexdigest()

    result = MediaNormalizer().normalize_staged(path)

    assert result.media_path.suffix == ".webm"
    assert result.after.video.codec_name == "vp9"
    assert result.after.audio_codecs == ("opus",)
    assert result.preserved_source is not None
    assert result.preserved_source.read_bytes() == original
    provenance = result.provenance(preserved_source=".nodraw-originals/source")
    assert provenance["source_sha256"] == original_sha256
    assert provenance["output_sha256"] == hashlib.sha256(
        result.media_path.read_bytes()
    ).hexdigest()
    assert provenance["preserved_source"] == ".nodraw-originals/source"

    normalized_bytes = result.media_path.read_bytes()
    second_result = MediaNormalizer().normalize_staged(result.media_path)
    assert second_result.plan.action == NormalizationAction.KEEP
    assert second_result.media_path.read_bytes() == normalized_bytes


@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
def test_odd_dimension_gif_payload_becomes_even_h264_and_retains_exact_source(temp_storage_dir):
    path = temp_storage_dir / ".odd-animation.mp4"
    original = _make_odd_gif(path)
    assert original.startswith(b"GIF")

    result = MediaNormalizer().normalize_staged(path)

    assert result.after.video.codec_name == "h264"
    assert result.after.video.width == 16
    assert result.after.video.height == 18
    assert result.preserved_source is not None
    assert result.preserved_source.read_bytes() == original


def test_probe_tool_failure_leaves_staged_source_untouched(temp_storage_dir):
    path = temp_storage_dir / ".source.mp4"
    original = b"source bytes"
    path.write_bytes(original)

    with patch("media_normalization.shutil.which", return_value=None):
        with pytest.raises(MediaNormalizationError, match="ffprobe is required"):
            MediaNormalizer().normalize_staged(path)

    assert path.read_bytes() == original
    assert list(temp_storage_dir.iterdir()) == [path]


def test_media_subprocess_cancellation_terminates_and_reaps_child():
    cancellation = threading.Event()
    timer = threading.Timer(0.1, cancellation.set)
    timer.start()
    try:
        with pytest.raises(MediaNormalizationError, match="cancelled"):
            MediaNormalizer._run_process(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                timeout=10,
                description="cancellation fixture",
                cancellation_event=cancellation,
            )
    finally:
        timer.cancel()


@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
def test_recovery_accepts_valid_audio_only_opus_webm(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    path = temp_storage_dir / "audio-only.webm"
    _make_opus_webm(path)

    assert YtDlpHandler()._probe_recovered_media(path) is True


@pytest.mark.asyncio
@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
async def test_successful_audio_download_requires_real_demux_integrity(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    handler = YtDlpHandler()

    def fake_download(url, opts):
        staged = Path(opts["outtmpl"]).parent / ".verified.wav"
        _make_pcm_wav(staged)
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with patch.object(handler, "_download_sync", side_effect=fake_download):
        result = await handler.download(
            "https://example.com/audio/verified",
            cookies={},
            output_dir=temp_storage_dir,
            options={"save_mode": "quick"},
        )

    assert result.success is True
    assert result.file_path == temp_storage_dir / "verified.wav"


def test_ffmpeg_transform_failure_removes_partial_output_and_keeps_source(temp_storage_dir):
    path = temp_storage_dir / ".vp9.mp4"
    original = b"complete staged source"
    path.write_bytes(original)

    class FailingTransformNormalizer(MediaNormalizer):
        def probe(self, probe_path):
            return _probe(video_codec="vp9", video_tag="vp09", audio_codec="aac")

        def _transform(self, source, destination, plan):
            destination.write_bytes(b"partial output")
            raise MediaNormalizationError("injected ffmpeg failure")

    with pytest.raises(MediaNormalizationError, match="injected ffmpeg failure"):
        FailingTransformNormalizer().normalize_staged(path)

    assert path.read_bytes() == original
    assert list(temp_storage_dir.iterdir()) == [path]


@pytest.mark.asyncio
@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
async def test_ytdlp_ingest_uses_dot_prefixed_stage_and_publishes_verified_name(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    seen: dict[str, Path] = {}
    handler = YtDlpHandler()

    def fake_download(url, opts):
        template = Path(opts["outtmpl"])
        seen["template"] = template
        staged = template.parent / ".native.mp4"
        original = _make_h264_mp4(staged)
        seen["original"] = original
        return DownloadResult(
            file_path=staged,
            metadata={"title": "native", "files": [staged.name]},
            success=True,
        )

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(handler, "_probe_recovered_media", return_value=True),
    ):
        result = await handler.download(
            "https://example.com/video",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is True
    assert seen["template"].name.startswith(".")
    assert seen["template"].parent.name.startswith(".nodraw-ingest-")
    assert result.file_path == temp_storage_dir / "native.mp4"
    assert result.file_path.read_bytes() == seen["original"]
    assert result.metadata["files"] == ["native.mp4"]
    assert result.metadata["media_normalization"]["items"][0]["action"] == "keep"
    assert not list(temp_storage_dir.glob(".nodraw-ingest-*"))


@pytest.mark.asyncio
@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
async def test_exception_recovered_vp9_is_normalized_before_success(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    fixture_path = temp_storage_dir / ".fixture-vp9.mp4"
    fixture_bytes = _make_vp9_aac_mp4(fixture_path)
    fixture_path.unlink()

    class FakeYoutubeDL:
        def __init__(self, opts):
            self.opts = opts

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract_info(self, url, download=True):
            stage_dir = Path(self.opts["outtmpl"]).parent
            (stage_dir / ".recovered.mp4").write_bytes(fixture_bytes)
            raise RuntimeError("post-processing failed after complete download")

    handler = YtDlpHandler()
    with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
        result = await handler.download(
            "https://x.com/example/status/42",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is True
    assert result.file_path == temp_storage_dir / "recovered.webm"
    assert result.file_path.exists()
    assert result.metadata["files"] == ["recovered.webm"]
    item = result.metadata["media_normalization"]["items"][0]
    assert item["operation"] == "remux_vp_video_to_webm"
    assert (temp_storage_dir / item["preserved_source"]).read_bytes() == fixture_bytes
    assert not (temp_storage_dir / "recovered.mp4").exists()


@pytest.mark.asyncio
@pytest.mark.skipif(not HAS_MEDIA_TOOLS, reason="ffmpeg/ffprobe are runtime requirements")
async def test_exception_recovered_gif_with_mp4_suffix_reaches_normalizer(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    fixture_path = temp_storage_dir / ".fixture.gif"
    fixture_bytes = _make_odd_gif(fixture_path)
    fixture_path.unlink()

    class FakeYoutubeDL:
        def __init__(self, opts):
            self.opts = opts

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract_info(self, url, download=True):
            stage_dir = Path(self.opts["outtmpl"]).parent
            (stage_dir / ".recovered-gif.mp4").write_bytes(fixture_bytes)
            raise RuntimeError("GIF post-processing failed after complete download")

    handler = YtDlpHandler()
    with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
        result = await handler.download(
            "https://x.com/example/status/43",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is True
    assert result.file_path == temp_storage_dir / "recovered-gif.mp4"
    assert MediaNormalizer().probe(result.file_path).video.codec_name == "h264"
    item = result.metadata["media_normalization"]["items"][0]
    assert item["operation"] == "gif_to_h264_mp4"
    assert (temp_storage_dir / item["preserved_source"]).read_bytes() == fixture_bytes


@pytest.mark.asyncio
async def test_normalization_failure_leaves_no_visible_media_or_stage(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    class FailingNormalizer:
        def normalize_staged(self, path):
            raise MediaNormalizationError("injected normalization failure")

    source_bytes = b"complete good source bytes"
    handler = YtDlpHandler(media_normalizer=FailingNormalizer())

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".bad.mp4"
        staged.write_bytes(source_bytes)
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with patch.object(handler, "_download_sync", side_effect=fake_download):
        result = await handler.download(
            "https://example.com/video",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is False
    assert "injected normalization failure" in result.error
    preserved_sources = list(
        (temp_storage_dir / ".nodraw-originals").glob("*/.bad.mp4")
    )
    assert len(preserved_sources) == 1
    assert preserved_sources[0].read_bytes() == source_bytes
    assert str(preserved_sources[0]) in result.error
    assert not (temp_storage_dir / "bad.mp4").exists()
    assert not list(temp_storage_dir.glob(".nodraw-ingest-*"))
    assert all(
        path.name.startswith('.')
        for path in (temp_storage_dir / ".nodraw-originals").rglob('*')
        if path.is_file()
    )


@pytest.mark.asyncio
async def test_publication_collision_uses_one_suffix_for_the_artifact_family(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    existing = temp_storage_dir / "native.mp3"
    existing_bytes = b"pre-existing archive media"
    existing.write_bytes(existing_bytes)
    handler = YtDlpHandler()
    attempts = 0

    def fake_download(url, opts):
        nonlocal attempts
        attempts += 1
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".native.mp3"
        staged.write_bytes(f"ID3 download {attempts}".encode())
        (stage_dir / ".native.en.vtt").write_text("WEBVTT")
        (stage_dir / ".native.webp").write_bytes(b"webp thumbnail")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(handler, "_probe_recovered_media", return_value=True),
    ):
        first = await handler.download(
            "https://example.com/video",
            cookies={},
            output_dir=temp_storage_dir,
        )
        second = await handler.download(
            "https://example.com/video",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert existing.read_bytes() == existing_bytes
    assert first.success is True
    assert first.file_path == temp_storage_dir / "native-2.mp3"
    assert first.file_path.read_bytes() == b"ID3 download 1"
    assert first.metadata["files"] == ["native-2.mp3"]
    assert (temp_storage_dir / "native-2.en.vtt").read_text() == "WEBVTT"
    assert (temp_storage_dir / "native-2.webp").read_bytes() == b"webp thumbnail"
    assert second.success is True
    assert second.file_path == temp_storage_dir / "native-3.mp3"
    assert second.file_path.read_bytes() == b"ID3 download 2"
    assert (temp_storage_dir / "native-3.en.vtt").exists()
    assert (temp_storage_dir / "native-3.webp").exists()
    assert not (temp_storage_dir / ".nodraw-originals").exists()
    assert not list(temp_storage_dir.glob(".nodraw-ingest-*"))


@pytest.mark.asyncio
async def test_snapshot_falls_back_to_hidden_copy_when_hard_links_are_unavailable(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    handler = YtDlpHandler()

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".portable.mp3"
        staged.write_bytes(b"ID3 portable snapshot")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    real_link = os.link

    def reject_snapshot_link(source, destination, *args, **kwargs):
        if Path(destination).name.startswith(".nodraw-source-snapshot-"):
            raise OSError("hard links unsupported for snapshots")
        return real_link(source, destination, *args, **kwargs)

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(handler, "_probe_recovered_media", return_value=True),
        patch(
            "downloaders.ytdlp_handler.os.link",
            side_effect=reject_snapshot_link,
        ),
    ):
        result = await handler.download(
            "https://example.com/audio",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is True
    assert result.file_path == temp_storage_dir / "portable.mp3"
    assert result.file_path.read_bytes() == b"ID3 portable snapshot"
    assert not list(temp_storage_dir.glob(".nodraw-ingest-*"))


@pytest.mark.asyncio
async def test_normalization_executor_bounds_parallel_collision_publication(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    executor = ThreadPoolExecutor(max_workers=2)
    handler = YtDlpHandler(normalization_executor=executor)
    original_normalize_and_publish = handler._normalize_and_publish
    state_lock = threading.Lock()
    both_workers_started = threading.Event()
    release_workers = threading.Event()
    active = 0
    peak_active = 0

    def fake_download(url, opts):
        label = url.rsplit("/", 1)[-1]
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".shared.mp3"
        staged.write_bytes(f"ID3 {label}".encode())
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    def tracked_normalize_and_publish(*args):
        nonlocal active, peak_active
        with state_lock:
            active += 1
            peak_active = max(peak_active, active)
            if active == 2:
                both_workers_started.set()
        try:
            assert release_workers.wait(timeout=5)
            return original_normalize_and_publish(*args)
        finally:
            with state_lock:
                active -= 1

    try:
        with (
            patch.object(handler, "_download_sync", side_effect=fake_download),
            patch.object(
                handler,
                "_normalize_and_publish",
                side_effect=tracked_normalize_and_publish,
            ),
            patch.object(handler, "_probe_recovered_media", return_value=True),
        ):
            tasks = [
                asyncio.create_task(handler.download(
                    f"https://example.com/audio/{index}",
                    cookies={},
                    output_dir=temp_storage_dir,
                ))
                for index in range(6)
            ]
            assert await asyncio.to_thread(both_workers_started.wait, 5)
            release_workers.set()
            results = await asyncio.gather(*tasks)
    finally:
        release_workers.set()
        executor.shutdown(wait=True)

    assert peak_active == 2
    assert all(result.success for result in results)
    assert {result.file_path.name for result in results} == {
        "shared.mp3", "shared-2.mp3", "shared-3.mp3",
        "shared-4.mp3", "shared-5.mp3", "shared-6.mp3",
    }


@pytest.mark.asyncio
async def test_cancellation_does_not_delete_staging_under_an_active_normalizer(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    executor = ThreadPoolExecutor(max_workers=1)
    handler = YtDlpHandler(normalization_executor=executor)
    original_normalize_and_publish = handler._normalize_and_publish
    worker_started = threading.Event()
    release_worker = threading.Event()
    seen: dict[str, Path] = {}

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        seen["stage"] = stage_dir
        staged = stage_dir / ".cancelled.mp3"
        staged.write_bytes(b"ID3 cancellation fixture")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    def blocked_normalize_and_publish(*args):
        worker_started.set()
        assert release_worker.wait(timeout=5)
        return original_normalize_and_publish(*args)

    try:
        with (
            patch.object(handler, "_download_sync", side_effect=fake_download),
            patch.object(
                handler,
                "_normalize_and_publish",
                side_effect=blocked_normalize_and_publish,
            ),
        ):
            task = asyncio.create_task(handler.download(
                "https://example.com/audio/cancelled",
                cookies={},
                output_dir=temp_storage_dir,
            ))
            assert await asyncio.to_thread(worker_started.wait, 5)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task

            # Cancellation must not race the worker by deleting its inputs.
            assert seen["stage"].is_dir()
            assert (seen["stage"] / ".cancelled.mp3").exists()
            release_worker.set()

            preserved: list[Path] = []
            for _ in range(200):
                preserved = list(
                    (temp_storage_dir / ".nodraw-originals").glob(
                        "*/.cancelled.mp3"
                    )
                )
                if (
                    preserved
                    and not seen["stage"].exists()
                ):
                    break
                await asyncio.sleep(0.01)
    finally:
        release_worker.set()
        executor.shutdown(wait=True)

    assert len(preserved) == 1
    assert preserved[0].read_bytes() == b"ID3 cancellation fixture"
    assert not (temp_storage_dir / "cancelled.mp3").exists()
    assert not seen["stage"].exists()


@pytest.mark.asyncio
async def test_download_cancellation_defers_cookie_and_stage_cleanup_until_worker_exit(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    recovery_executor = ThreadPoolExecutor(max_workers=1)
    handler = YtDlpHandler(normalization_executor=recovery_executor)
    worker_started = threading.Event()
    release_worker = threading.Event()
    seen: dict[str, object] = {}

    def blocked_download(url, opts):
        cookie_file = Path(opts["cookiefile"])
        stage_dir = Path(opts["outtmpl"]).parent
        seen["cookie"] = cookie_file
        seen["stage"] = stage_dir
        assert cookie_file.parent == stage_dir
        assert cookie_file.exists()
        worker_started.set()
        assert release_worker.wait(timeout=5)
        # The cancelled coroutine must not unlink credentials while yt-dlp could
        # still be consuming them.
        seen["cookie_at_worker_exit"] = cookie_file.read_text()
        staged = stage_dir / ".cancelled-download.mp3"
        staged.write_bytes(b"ID3 completed after cancellation")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    try:
        with (
            patch.object(handler, "_download_sync", side_effect=blocked_download),
            patch.object(handler, "_probe_recovered_media", return_value=True),
        ):
            task = asyncio.create_task(handler.download(
                "https://x.com/example/status/789",
                cookies={"auth_token": "secret-fixture"},
                output_dir=temp_storage_dir,
            ))
            assert await asyncio.to_thread(worker_started.wait, 5)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task

            cookie_file = seen["cookie"]
            stage_dir = seen["stage"]
            assert isinstance(cookie_file, Path)
            assert isinstance(stage_dir, Path)
            assert cookie_file.exists()
            assert stage_dir.exists()
            release_worker.set()

            preserved: list[Path] = []
            for _ in range(200):
                preserved = list(
                    (temp_storage_dir / ".nodraw-originals").glob(
                        "*/.cancelled-download.mp3"
                    )
                )
                if preserved and not stage_dir.exists():
                    break
                await asyncio.sleep(0.01)
    finally:
        release_worker.set()
        recovery_executor.shutdown(wait=True)

    assert "secret-fixture" in str(seen["cookie_at_worker_exit"])
    assert len(preserved) == 1
    assert preserved[0].read_bytes() == b"ID3 completed after cancellation"
    assert not (temp_storage_dir / "cancelled-download.mp3").exists()
    assert not list(temp_storage_dir.rglob("*.cookies.txt"))


@pytest.mark.asyncio
async def test_parallel_downloads_never_share_cookie_files(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    handler = YtDlpHandler()
    state_lock = threading.Lock()
    both_started = threading.Event()
    release_workers = threading.Event()
    observed: dict[str, tuple[Path, str]] = {}

    def blocked_download(url, opts):
        label = url.rsplit("/", 1)[-1]
        cookie_file = Path(opts["cookiefile"])
        with state_lock:
            observed[label] = (cookie_file, cookie_file.read_text())
            if len(observed) == 2:
                both_started.set()
        assert release_workers.wait(timeout=5)
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / f".{label}.mp3"
        staged.write_bytes(f"ID3 {label}".encode())
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    try:
        with (
            patch.object(handler, "_download_sync", side_effect=blocked_download),
            patch.object(handler, "_probe_recovered_media", return_value=True),
        ):
            tasks = [
                asyncio.create_task(handler.download(
                    f"https://x.com/example/status/{label}",
                    cookies={"auth_token": f"token-{label}"},
                    output_dir=temp_storage_dir,
                ))
                for label in ("one", "two")
            ]
            assert await asyncio.to_thread(both_started.wait, 5)
            first_cookie = observed["one"][0]
            second_cookie = observed["two"][0]
            assert first_cookie != second_cookie
            assert first_cookie.parent != second_cookie.parent
            assert first_cookie.exists() and second_cookie.exists()
            release_workers.set()
            results = await asyncio.gather(*tasks)
    finally:
        release_workers.set()

    assert "token-one" in observed["one"][1]
    assert "token-two" in observed["two"][1]
    assert all(result.success for result in results)
    assert not first_cookie.exists()
    assert not second_cookie.exists()


def test_mid_family_publish_failure_rolls_every_published_artifact_back(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import MediaPublishError, YtDlpHandler

    stage_dir = temp_storage_dir / ".nodraw-ingest-rollback"
    stage_dir.mkdir()
    subtitle = stage_dir / ".family.en.vtt"
    media = stage_dir / ".family.mp3"
    subtitle.write_bytes(b"WEBVTT")
    media.write_bytes(b"ID3 media")
    destinations = {
        subtitle: temp_storage_dir / "family.en.vtt",
        media: temp_storage_dir / "family.mp3",
    }
    real_move = YtDlpHandler._move_file_no_clobber
    calls = 0

    def fail_second_move(source, destination):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("injected mid-family failure")
        return real_move(source, destination)

    with patch.object(
        YtDlpHandler,
        "_move_file_no_clobber",
        side_effect=fail_second_move,
    ):
        with pytest.raises(MediaPublishError, match="injected mid-family failure"):
            YtDlpHandler._publish_staged_files(
                destinations,
                media_paths={media},
            )

    assert subtitle.read_bytes() == b"WEBVTT"
    assert media.read_bytes() == b"ID3 media"
    assert not destinations[subtitle].exists()
    assert not destinations[media].exists()


def test_atomic_publication_does_not_overwrite_racing_destination(temp_storage_dir):
    from downloaders.ytdlp_handler import MediaPublishError, YtDlpHandler

    stage_dir = temp_storage_dir / ".nodraw-ingest-race"
    stage_dir.mkdir()
    source = stage_dir / ".race.mp3"
    source.write_bytes(b"new media")
    destination = temp_storage_dir / "race.mp3"
    real_link = os.link

    def create_peer_then_link(link_source, link_destination, *args, **kwargs):
        Path(link_destination).write_bytes(b"peer media")
        return real_link(link_source, link_destination, *args, **kwargs)

    with patch(
        "downloaders.ytdlp_handler.os.link",
        side_effect=create_peer_then_link,
    ):
        with pytest.raises(MediaPublishError, match="Could not publish"):
            YtDlpHandler._publish_staged_files(
                {source: destination},
                media_paths={source},
            )

    assert source.read_bytes() == b"new media"
    assert destination.read_bytes() == b"peer media"


def test_cancellation_mid_family_rolls_back_before_publication_returns(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import (
        IngestCancellationRequested,
        YtDlpHandler,
    )

    stage_dir = temp_storage_dir / ".nodraw-ingest-cancel-family"
    stage_dir.mkdir()
    auxiliary = stage_dir / ".cancel-family.en.vtt"
    media = stage_dir / ".cancel-family.mp3"
    auxiliary.write_bytes(b"WEBVTT")
    media.write_bytes(b"ID3 family")
    destinations = {
        auxiliary: temp_storage_dir / "cancel-family.en.vtt",
        media: temp_storage_dir / "cancel-family.mp3",
    }
    cancellation_event = threading.Event()
    real_move = YtDlpHandler._move_file_no_clobber
    moves = 0

    def cancel_after_first_move(source, destination):
        nonlocal moves
        real_move(source, destination)
        moves += 1
        if moves == 1:
            cancellation_event.set()

    with patch.object(
        YtDlpHandler,
        "_move_file_no_clobber",
        side_effect=cancel_after_first_move,
    ):
        with pytest.raises(IngestCancellationRequested):
            YtDlpHandler._publish_staged_files(
                destinations,
                media_paths={media},
                cancellation_event=cancellation_event,
            )

    assert auxiliary.read_bytes() == b"WEBVTT"
    assert media.read_bytes() == b"ID3 family"
    assert not destinations[auxiliary].exists()
    assert not destinations[media].exists()


def test_post_publication_cancellation_race_retracts_exact_manifest(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    recovery_executor = ThreadPoolExecutor(max_workers=1)
    handler = YtDlpHandler(normalization_executor=recovery_executor)
    stage_dir = temp_storage_dir / ".nodraw-ingest-post-publish"
    stage_dir.mkdir()
    public_media = temp_storage_dir / "raced.mp3"
    public_auxiliary = temp_storage_dir / "raced.en.vtt"
    public_media.write_bytes(b"ID3 raced")
    public_auxiliary.write_bytes(b"WEBVTT")
    completed: Future = Future()
    completed.set_result(DownloadResult(
        file_path=public_media,
        metadata={"files": [public_media.name]},
        success=True,
        published_paths=(public_media, public_auxiliary),
    ))

    handler._finish_cancelled_normalization(
        completed,
        stage_dir,
        temp_storage_dir,
    )
    recovery_executor.shutdown(wait=True)

    assert not public_media.exists()
    assert not public_auxiliary.exists()
    preserved_media = list(
        (temp_storage_dir / ".nodraw-originals").glob("*/.raced.mp3")
    )
    preserved_auxiliary = list(
        (temp_storage_dir / ".nodraw-originals").glob("*/.raced.en.vtt")
    )
    assert len(preserved_media) == 1
    assert len(preserved_auxiliary) == 1
    assert not stage_dir.exists()


@pytest.mark.asyncio
async def test_failure_recovery_runs_off_the_event_loop(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    class FailingNormalizer:
        def normalize_staged(self, path):
            raise MediaNormalizationError("injected offload check")

    executor = ThreadPoolExecutor(max_workers=1)
    handler = YtDlpHandler(
        media_normalizer=FailingNormalizer(),
        normalization_executor=executor,
    )
    original_preserve = handler._preserve_completed_stage
    event_loop_thread = threading.get_ident()
    recovery_threads: list[int] = []

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".offload.mp4"
        staged.write_bytes(b"complete staged media")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    def tracked_preserve(stage_dir, output_dir):
        recovery_threads.append(threading.get_ident())
        return original_preserve(stage_dir, output_dir)

    try:
        with (
            patch.object(handler, "_download_sync", side_effect=fake_download),
            patch.object(
                handler,
                "_preserve_completed_stage",
                side_effect=tracked_preserve,
            ),
        ):
            result = await handler.download(
                "https://example.com/video/offload",
                cookies={},
                output_dir=temp_storage_dir,
            )
    finally:
        executor.shutdown(wait=True)

    assert result.success is False
    assert recovery_threads and recovery_threads[0] != event_loop_thread


@pytest.mark.asyncio
async def test_auxiliary_symlink_escape_is_rejected_before_publication(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    outside = temp_storage_dir / "outside-secret.txt"
    outside.write_bytes(b"do not publish through symlink")
    handler = YtDlpHandler()

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".safe.mp3"
        staged.write_bytes(b"ID3 safe media")
        (stage_dir / ".safe.info.json").symlink_to(outside)
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(handler, "_probe_recovered_media", return_value=True),
    ):
        result = await handler.download(
            "https://example.com/audio/symlink",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is False
    assert "symbolic-link artifact" in result.error
    assert outside.read_bytes() == b"do not publish through symlink"
    assert not (temp_storage_dir / "safe.mp3").exists()
    assert not (temp_storage_dir / "safe.info.json").exists()


@pytest.mark.asyncio
async def test_invalid_word_inside_legitimate_title_is_not_quarantine_suffix(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    handler = YtDlpHandler()

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".perfectly.invalid-title.mp3"
        staged.write_bytes(b"ID3 legitimate title")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(handler, "_probe_recovered_media", return_value=True),
    ):
        result = await handler.download(
            "https://example.com/audio/invalid-title",
            cookies={},
            output_dir=temp_storage_dir,
        )

    assert result.success is True
    assert result.file_path == temp_storage_dir / "perfectly.invalid-title.mp3"
    assert YtDlpHandler._is_quarantined_name(Path(".media.mp3.invalid"))
    assert YtDlpHandler._is_quarantined_name(Path(".media.mp3.invalid-2"))
    assert not YtDlpHandler._is_quarantined_name(result.file_path)


@pytest.mark.asyncio
async def test_failed_rescue_retains_hidden_stage_and_reports_it(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    class FailingNormalizer:
        def normalize_staged(self, path):
            raise MediaNormalizationError("normalization unavailable")

    handler = YtDlpHandler(media_normalizer=FailingNormalizer())

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".source.mp4"
        staged.write_bytes(b"recover me")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(
            handler,
            "_preserve_completed_stage",
            side_effect=OSError("recovery destination unavailable"),
        ),
    ):
        result = await handler.download(
            "https://example.com/video",
            cookies={},
            output_dir=temp_storage_dir,
        )

    retained_stages = list(temp_storage_dir.glob(".nodraw-ingest-*"))
    assert result.success is False
    assert len(retained_stages) == 1
    assert str(retained_stages[0]) in result.error
    assert (retained_stages[0] / ".source.mp4").read_bytes() == b"recover me"


@pytest.mark.asyncio
async def test_rejected_exception_recovery_is_preserved_outside_media_indexing(
    temp_storage_dir,
):
    from downloaders.ytdlp_handler import YtDlpHandler

    rejected_bytes = b"not a media container"

    class FakeYoutubeDL:
        def __init__(self, opts):
            self.opts = opts

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def extract_info(self, url, download=True):
            stage_dir = Path(self.opts["outtmpl"]).parent
            (stage_dir / ".rejected.mp4").write_bytes(rejected_bytes)
            raise RuntimeError("download post-processing failed")

    handler = YtDlpHandler()
    with patch("downloaders.ytdlp_handler.yt_dlp.YoutubeDL", FakeYoutubeDL):
        result = await handler.download(
            "https://x.com/example/status/44",
            cookies={},
            output_dir=temp_storage_dir,
        )

    preserved = list(
        (temp_storage_dir / ".nodraw-originals").glob(
            "*/.rejected.mp4.invalid"
        )
    )
    assert result.success is False
    assert len(preserved) == 1
    assert preserved[0].read_bytes() == rejected_bytes
    assert not (temp_storage_dir / "rejected.mp4").exists()
    assert not list(temp_storage_dir.glob(".nodraw-ingest-*"))


@pytest.mark.asyncio
async def test_audio_only_download_skips_video_normalizer(temp_storage_dir):
    from downloaders.ytdlp_handler import YtDlpHandler

    class UnexpectedNormalizer:
        def normalize_staged(self, path):
            raise AssertionError("audio-only ingest must not invoke video normalizer")

    handler = YtDlpHandler(media_normalizer=UnexpectedNormalizer())

    def fake_download(url, opts):
        stage_dir = Path(opts["outtmpl"]).parent
        staged = stage_dir / ".audio.mp3"
        staged.write_bytes(b"ID3 audio fixture")
        return DownloadResult(
            file_path=staged,
            metadata={"files": [staged.name]},
            success=True,
        )

    with (
        patch.object(handler, "_download_sync", side_effect=fake_download),
        patch.object(handler, "_probe_recovered_media", return_value=True),
    ):
        result = await handler.download(
            "https://youtube.com/watch?v=audio",
            cookies={},
            output_dir=temp_storage_dir,
            options={"save_mode": "quick"},
        )

    assert result.success is True
    assert result.file_path == temp_storage_dir / "audio.mp3"
    assert "media_normalization" not in result.metadata
