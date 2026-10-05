"""Conditional media normalization for NoDraw's intended macOS playback paths.

The normalizer deliberately operates on a staged file.  It never publishes into the
archive and never updates database or sidecar state; callers own that transaction.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
from typing import Any, Optional, Sequence
from uuid import uuid4


ISO_BMFF_FORMATS = frozenset({"mov", "mp4", "m4a", "3gp", "3g2", "mj2"})
WEBM_FORMATS = frozenset({"matroska", "webm"})
WEBM_VIDEO_CODECS = frozenset({"vp8", "vp9", "av1"})
WEBM_AUDIO_CODECS = frozenset({"opus", "vorbis"})
MAC_MP4_AUDIO_CODECS = frozenset({"aac", "alac", "mp3", "ac3", "eac3"})


class MediaNormalizationError(RuntimeError):
    """A staged media file could not be proven compatible and safe to publish."""


class MediaNormalizationCancelledError(MediaNormalizationError):
    """A cancellable media subprocess was terminated before publication."""


_RUNTIME_CANCELLED = threading.Event()
_ACTIVE_PROCESS_LOCK = threading.Lock()
_ACTIVE_PROCESSES: set[subprocess.Popen] = set()


def start_media_runtime() -> None:
    """Allow media subprocesses for a newly started application lifecycle."""
    _RUNTIME_CANCELLED.clear()


def shutdown_media_runtime() -> None:
    """Request cancellation and promptly signal active normalization children."""
    _RUNTIME_CANCELLED.set()
    with _ACTIVE_PROCESS_LOCK:
        processes = tuple(_ACTIVE_PROCESSES)
    for process in processes:
        if process.poll() is None:
            try:
                process.terminate()
            except OSError:
                pass

    # The flag closes the race in which a subprocess is registered while the
    # shutdown snapshot is being taken.  Once all registered children have
    # observed termination and reaped themselves, reset it so this module is
    # safe to reuse in a later application/test lifecycle.
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        with _ACTIVE_PROCESS_LOCK:
            if not _ACTIVE_PROCESSES:
                _RUNTIME_CANCELLED.clear()
                break
        time.sleep(0.01)


class NormalizationAction(str, Enum):
    KEEP = "keep"
    RENAME = "rename"
    REMUX = "remux"
    TRANSCODE = "transcode"


@dataclass(frozen=True)
class StreamProbe:
    index: int
    codec_type: str
    codec_name: str
    codec_tag: str = ""
    attached_pic: bool = False
    width: Optional[int] = None
    height: Optional[int] = None

    def as_metadata(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "type": self.codec_type,
            "codec": self.codec_name,
            "tag": self.codec_tag or None,
            "width": self.width,
            "height": self.height,
        }


@dataclass(frozen=True)
class MediaProbe:
    path_suffix: str
    format_names: frozenset[str]
    streams: tuple[StreamProbe, ...]
    duration: Optional[float] = None
    size: Optional[int] = None
    gif_payload: bool = False
    webm_payload: bool = False

    @property
    def video(self) -> Optional[StreamProbe]:
        for stream in self.streams:
            if stream.codec_type == "video" and not stream.attached_pic:
                return stream
        return None

    @property
    def audio_codecs(self) -> tuple[str, ...]:
        return tuple(
            stream.codec_name
            for stream in self.streams
            if stream.codec_type == "audio"
        )

    @property
    def omitted_stream_count(self) -> int:
        primary_video_index = self.video.index if self.video else None
        return sum(
            1
            for stream in self.streams
            if stream.codec_type not in {"audio", "video"}
            or (stream.codec_type == "video" and stream.index != primary_video_index)
        )

    def as_metadata(self) -> dict[str, Any]:
        return {
            "container": sorted(self.format_names),
            "duration_seconds": self.duration,
            "size_bytes": self.size,
            "webm_payload": self.webm_payload,
            "streams": [stream.as_metadata() for stream in self.streams],
        }


@dataclass(frozen=True)
class NormalizationPlan:
    action: NormalizationAction
    operation: str
    reason: str
    output_suffix: str
    video_codec: str = "copy"
    audio_codec: str = "copy"
    video_tag: Optional[str] = None
    lossy: bool = False


@dataclass(frozen=True)
class MediaNormalizationResult:
    source_path: Path
    media_path: Path
    preserved_source: Optional[Path]
    plan: NormalizationPlan
    before: MediaProbe
    after: MediaProbe
    source_sha256: Optional[str] = None
    output_sha256: Optional[str] = None

    def provenance(
        self,
        *,
        media_path: Optional[str] = None,
        preserved_source: Optional[str] = None,
    ) -> dict[str, Any]:
        """Return JSON-ready provenance without leaking temporary absolute paths."""
        payload: dict[str, Any] = {
            "schema_version": 1,
            "path": media_path or self.media_path.name.lstrip("."),
            "source_filename": self.source_path.name.lstrip("."),
            "output_filename": self.media_path.name.lstrip("."),
            "action": self.plan.action.value,
            "operation": self.plan.operation,
            "reason": self.plan.reason,
            "lossy": self.plan.lossy,
            "source": self.before.as_metadata(),
            "output": self.after.as_metadata(),
        }
        if self.preserved_source is not None:
            payload["preserved_source"] = (
                preserved_source or self.preserved_source.name.lstrip(".")
            )
            payload["source_sha256"] = self.source_sha256
            payload["output_sha256"] = self.output_sha256
        return payload


def _all_audio_in(probe: MediaProbe, allowed: frozenset[str]) -> bool:
    return all(codec in allowed for codec in probe.audio_codecs)


def classify_media(probe: MediaProbe) -> NormalizationPlan:
    """Choose the least-lossy representation supported by NoDraw's Mac player path."""
    suffix = probe.path_suffix.lower()
    if probe.gif_payload:
        return NormalizationPlan(
            action=NormalizationAction.TRANSCODE,
            operation="gif_to_h264_mp4",
            reason="gif_payload_requires_animated_video_path",
            output_suffix=".mp4",
            video_codec="libx264",
            audio_codec="none",
            lossy=True,
        )

    video = probe.video
    if video is None:
        raise MediaNormalizationError("Media probe did not find a playable video stream")

    codec = video.codec_name.lower()
    tag = video.codec_tag.lower()
    is_iso_bmff = bool(probe.format_names & ISO_BMFF_FORMATS)
    is_webm_family = bool(probe.format_names & WEBM_FORMATS) and probe.webm_payload
    webm_compatible = (
        codec in WEBM_VIDEO_CODECS
        and _all_audio_in(probe, WEBM_AUDIO_CODECS)
    )

    if is_webm_family and webm_compatible:
        if suffix == ".webm":
            return NormalizationPlan(
                action=NormalizationAction.KEEP,
                operation="keep_webm",
                reason="native_webkit_webm",
                output_suffix=".webm",
            )
        return NormalizationPlan(
            action=NormalizationAction.RENAME,
            operation="rename_webm",
            reason="webm_payload_requires_webm_extension",
            output_suffix=".webm",
        )

    audio_is_mp4_compatible = _all_audio_in(probe, MAC_MP4_AUDIO_CODECS)
    has_omitted_streams = probe.omitted_stream_count > 0

    if is_iso_bmff and codec in {"h264", "av1"} and audio_is_mp4_compatible:
        if suffix not in {".mp4", ".mov"}:
            return NormalizationPlan(
                action=NormalizationAction.RENAME,
                operation="rename_iso_bmff",
                reason="iso_bmff_payload_requires_native_video_extension",
                output_suffix=".mp4",
            )
        return NormalizationPlan(
            action=NormalizationAction.KEEP,
            operation="keep_mp4",
            reason=f"native_avfoundation_{codec}",
            output_suffix=suffix or ".mp4",
        )

    if is_iso_bmff and codec in {"hevc", "h265"}:
        if tag == "hvc1" and audio_is_mp4_compatible:
            if suffix not in {".mp4", ".mov"}:
                return NormalizationPlan(
                    action=NormalizationAction.RENAME,
                    operation="rename_iso_bmff",
                    reason="iso_bmff_payload_requires_native_video_extension",
                    output_suffix=".mp4",
                )
            return NormalizationPlan(
                action=NormalizationAction.KEEP,
                operation="keep_hvc1_mp4",
                reason="native_avfoundation_hevc_hvc1",
                output_suffix=suffix or ".mp4",
            )
        audio_codec = "copy" if audio_is_mp4_compatible else "aac"
        lossy = audio_codec != "copy" or has_omitted_streams
        return NormalizationPlan(
            action=NormalizationAction.REMUX,
            operation="repair_hevc_hvc1_tag",
            reason="hevc_sample_entry_not_hvc1" if tag != "hvc1" else "incompatible_mp4_audio",
            output_suffix=".mp4",
            video_codec="copy",
            audio_codec=audio_codec,
            video_tag="hvc1",
            lossy=lossy,
        )

    if codec in {"vp8", "vp9"}:
        audio_codec = "copy" if _all_audio_in(probe, WEBM_AUDIO_CODECS) else "libopus"
        lossy = audio_codec != "copy" or has_omitted_streams
        return NormalizationPlan(
            action=NormalizationAction.REMUX,
            operation="remux_vp_video_to_webm",
            reason=f"{codec}_requires_webkit_container",
            output_suffix=".webm",
            video_codec="copy",
            audio_codec=audio_codec,
            lossy=lossy,
        )

    if codec in {"h264", "av1", "hevc", "h265"}:
        audio_codec = "copy" if audio_is_mp4_compatible else "aac"
        lossy = audio_codec != "copy" or has_omitted_streams
        return NormalizationPlan(
            action=NormalizationAction.REMUX,
            operation="remux_native_video_to_mp4",
            reason="native_video_in_incompatible_container_or_audio",
            output_suffix=".mp4",
            video_codec="copy",
            audio_codec=audio_codec,
            video_tag="hvc1" if codec in {"hevc", "h265"} else None,
            lossy=lossy,
        )

    fallback_audio_codec = "copy" if audio_is_mp4_compatible else "aac"
    return NormalizationPlan(
        action=NormalizationAction.TRANSCODE,
        operation="fallback_to_h264_aac_mp4",
        reason=f"unsupported_video_codec:{codec or 'unknown'}",
        output_suffix=".mp4",
        video_codec="libx264",
        audio_codec=fallback_audio_codec,
        lossy=True,
    )


class MediaNormalizer:
    """Probe, normalize, and verify one safely staged media file."""

    def __init__(
        self,
        *,
        probe_timeout: int = 20,
        integrity_timeout: int = 300,
        transform_timeout: int = 3600,
    ) -> None:
        self.probe_timeout = probe_timeout
        self.integrity_timeout = integrity_timeout
        self.transform_timeout = transform_timeout

    def probe(
        self,
        path: Path,
        cancellation_event: Optional[threading.Event] = None,
    ) -> MediaProbe:
        path = Path(path)
        ffprobe = shutil.which("ffprobe")
        if not ffprobe:
            raise MediaNormalizationError("ffprobe is required for media normalization")

        completed = self._run_process(
            [
                ffprobe,
                "-v", "error",
                "-show_entries",
                "format=format_name,duration,size:stream=index,codec_type,codec_name,codec_tag_string,width,height:stream_disposition=attached_pic",
                "-of", "json",
                str(path),
            ],
            timeout=self.probe_timeout,
            description=f"ffprobe for {path.name}",
            cancellation_event=cancellation_event,
        )

        if completed.returncode != 0:
            detail = completed.stderr.strip()[:500]
            raise MediaNormalizationError(
                f"ffprobe rejected {path.name}" + (f": {detail}" if detail else "")
            )

        try:
            payload = json.loads(completed.stdout)
        except (TypeError, json.JSONDecodeError) as error:
            raise MediaNormalizationError(
                f"ffprobe returned invalid JSON for {path.name}"
            ) from error
        if not isinstance(payload, dict):
            raise MediaNormalizationError(f"ffprobe returned invalid data for {path.name}")

        format_payload = payload.get("format")
        if not isinstance(format_payload, dict):
            format_payload = {}
        format_names = frozenset(
            name.strip().lower()
            for name in str(format_payload.get("format_name", "")).split(",")
            if name.strip()
        )

        streams_payload = payload.get("streams")
        if not isinstance(streams_payload, list):
            streams_payload = []
        streams: list[StreamProbe] = []
        for raw_stream in streams_payload:
            if not isinstance(raw_stream, dict):
                continue
            disposition = raw_stream.get("disposition")
            if not isinstance(disposition, dict):
                disposition = {}
            try:
                index = int(raw_stream.get("index", len(streams)))
            except (TypeError, ValueError):
                index = len(streams)
            streams.append(
                StreamProbe(
                    index=index,
                    codec_type=str(raw_stream.get("codec_type", "")).lower(),
                    codec_name=str(raw_stream.get("codec_name", "")).lower(),
                    codec_tag=str(raw_stream.get("codec_tag_string", "")).lower(),
                    attached_pic=bool(disposition.get("attached_pic", 0)),
                    width=self._optional_int(raw_stream.get("width")),
                    height=self._optional_int(raw_stream.get("height")),
                )
            )

        return MediaProbe(
            path_suffix=path.suffix.lower(),
            format_names=format_names,
            streams=tuple(streams),
            duration=self._optional_float(format_payload.get("duration")),
            size=self._optional_int(format_payload.get("size")),
            gif_payload=self._has_gif_magic(path),
            webm_payload=self._ebml_doc_type(path) == "webm",
        )

    def normalize_staged(
        self,
        path: Path,
        cancellation_event: Optional[threading.Event] = None,
    ) -> MediaNormalizationResult:
        """Normalize a staged file in place and return its publishable artifacts."""
        source_path = Path(path)
        if not source_path.is_file() or source_path.stat().st_size <= 0:
            raise MediaNormalizationError(f"Staged media is missing or empty: {source_path}")

        before = (
            self.probe(source_path, cancellation_event)
            if cancellation_event is not None
            else self.probe(source_path)
        )
        plan = classify_media(before)

        if plan.action == NormalizationAction.KEEP:
            if cancellation_event is not None:
                self.verify_integrity(source_path, cancellation_event)
            else:
                self.verify_integrity(source_path)
            return MediaNormalizationResult(
                source_path=source_path,
                media_path=source_path,
                preserved_source=None,
                plan=plan,
                before=before,
                after=before,
            )

        if plan.action == NormalizationAction.RENAME:
            target = source_path.with_suffix(plan.output_suffix)
            if target.exists() and target != source_path:
                raise MediaNormalizationError(
                    f"Normalization target already exists in staging: {target.name}"
                )
            if cancellation_event is not None:
                self.verify_integrity(source_path, cancellation_event)
            else:
                self.verify_integrity(source_path)
            if target != source_path:
                source_path.rename(target)
            after = (
                self.probe(target, cancellation_event)
                if cancellation_event is not None
                else self.probe(target)
            )
            self._require_publishable_output(target, after)
            return MediaNormalizationResult(
                source_path=source_path,
                media_path=target,
                preserved_source=None,
                plan=plan,
                before=before,
                after=after,
            )

        target = source_path.with_suffix(plan.output_suffix)
        if target != source_path and target.exists():
            raise MediaNormalizationError(
                f"Normalization target already exists in staging: {target.name}"
            )
        temporary = source_path.parent / f".nodraw-work-{uuid4().hex}{plan.output_suffix}"
        preserved_source: Optional[Path] = None
        source_sha256: Optional[str] = None
        output_sha256: Optional[str] = None

        try:
            if cancellation_event is not None:
                self._transform(source_path, temporary, plan, cancellation_event)
                after = self.probe(temporary, cancellation_event)
            else:
                self._transform(source_path, temporary, plan)
                after = self.probe(temporary)
            self._require_publishable_output(temporary, after)
            if cancellation_event is not None:
                self.verify_integrity(temporary, cancellation_event)
            else:
                self.verify_integrity(temporary)

            if plan.lossy:
                source_sha256 = self._sha256(source_path)
                output_sha256 = self._sha256(temporary)
                preserved_source = self._available_preserved_path(source_path)
                source_path.rename(preserved_source)
                try:
                    os.replace(temporary, target)
                except OSError:
                    preserved_source.rename(source_path)
                    raise
            else:
                os.replace(temporary, target)
                if target != source_path:
                    try:
                        source_path.unlink()
                    except OSError as error:
                        target.unlink(missing_ok=True)
                        raise MediaNormalizationError(
                            f"Could not retire staged source {source_path.name}: {error}"
                        ) from error
        except MediaNormalizationError:
            temporary.unlink(missing_ok=True)
            raise
        except OSError as error:
            temporary.unlink(missing_ok=True)
            raise MediaNormalizationError(
                f"Could not commit normalized media for {source_path.name}: {error}"
            ) from error

        return MediaNormalizationResult(
            source_path=source_path,
            media_path=target,
            preserved_source=preserved_source,
            plan=plan,
            before=before,
            after=after,
            source_sha256=source_sha256,
            output_sha256=output_sha256,
        )

    def verify_integrity(
        self,
        path: Path,
        cancellation_event: Optional[threading.Event] = None,
    ) -> None:
        """Read the complete primary video stream without decoding or rewriting it."""
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise MediaNormalizationError("ffmpeg is required for media integrity checks")
        self._run_ffmpeg(
            [
                ffmpeg,
                "-nostdin",
                "-v", "error",
                "-xerror",
                "-i", str(path),
                "-map", "0:v:0",
                "-c", "copy",
                "-f", "null",
                "-",
            ],
            timeout=self.integrity_timeout,
            description=f"integrity check for {Path(path).name}",
            cancellation_event=cancellation_event,
        )

    def _transform(
        self,
        source: Path,
        destination: Path,
        plan: NormalizationPlan,
        cancellation_event: Optional[threading.Event] = None,
    ) -> None:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise MediaNormalizationError("ffmpeg is required for media normalization")

        command = [
            ffmpeg,
            "-nostdin",
            "-v", "error",
            "-xerror",
            "-y",
            "-i", str(source),
            "-map", "0:v:0",
        ]
        if plan.audio_codec != "none":
            command.extend(["-map", "0:a?"])
        command.extend(["-map_metadata", "0", "-c:v", plan.video_codec])

        if plan.video_codec == "libx264":
            command.extend([
                "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                "-preset", "medium",
                "-crf", "20",
                "-pix_fmt", "yuv420p",
            ])
        if plan.video_tag:
            command.extend(["-tag:v", plan.video_tag])
        if plan.audio_codec != "none":
            command.extend(["-c:a", plan.audio_codec])
            if plan.audio_codec == "aac":
                command.extend(["-b:a", "192k"])
            elif plan.audio_codec == "libopus":
                command.extend(["-b:a", "128k"])
        else:
            command.append("-an")

        if plan.output_suffix == ".mp4":
            command.extend(["-movflags", "+faststart", "-f", "mp4"])
        elif plan.output_suffix == ".webm":
            command.extend(["-f", "webm"])
        command.append(str(destination))

        self._run_ffmpeg(
            command,
            timeout=self.transform_timeout,
            description=f"{plan.operation} for {source.name}",
            cancellation_event=cancellation_event,
        )

    def _require_publishable_output(self, path: Path, probe: MediaProbe) -> None:
        follow_up = classify_media(probe)
        if follow_up.action != NormalizationAction.KEEP:
            raise MediaNormalizationError(
                f"Normalized output {path.name} still requires {follow_up.operation}"
            )

    @staticmethod
    def _run_ffmpeg(
        command: Sequence[str],
        *,
        timeout: int,
        description: str,
        cancellation_event: Optional[threading.Event] = None,
    ) -> None:
        completed = MediaNormalizer._run_process(
            command,
            timeout=timeout,
            description=f"ffmpeg {description}",
            cancellation_event=cancellation_event,
        )
        if completed.returncode != 0:
            detail = completed.stderr.strip()[:500]
            raise MediaNormalizationError(
                f"ffmpeg {description} failed"
                + (f": {detail}" if detail else "")
            )

    @staticmethod
    def _run_process(
        command: Sequence[str],
        *,
        timeout: int,
        description: str,
        cancellation_event: Optional[threading.Event] = None,
    ) -> subprocess.CompletedProcess:
        """Run a child with cooperative cancellation and guaranteed reaping."""
        try:
            process = subprocess.Popen(
                list(command),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as error:
            raise MediaNormalizationError(f"{description} failed: {error}") from error

        with _ACTIVE_PROCESS_LOCK:
            _ACTIVE_PROCESSES.add(process)
        started = time.monotonic()
        try:
            while True:
                cancelled = _RUNTIME_CANCELLED.is_set() or (
                    cancellation_event is not None and cancellation_event.is_set()
                )
                if cancelled:
                    MediaNormalizer._terminate_and_reap(process)
                    raise MediaNormalizationCancelledError(
                        f"{description} cancelled"
                    )

                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    MediaNormalizer._terminate_and_reap(process)
                    raise MediaNormalizationError(
                        f"{description} timed out after {timeout} seconds"
                    )
                try:
                    stdout, stderr = process.communicate(timeout=min(0.2, remaining))
                except subprocess.TimeoutExpired:
                    continue

                if _RUNTIME_CANCELLED.is_set() or (
                    cancellation_event is not None and cancellation_event.is_set()
                ):
                    raise MediaNormalizationCancelledError(
                        f"{description} cancelled"
                    )
                return subprocess.CompletedProcess(
                    args=list(command),
                    returncode=process.returncode,
                    stdout=stdout,
                    stderr=stderr,
                )
        finally:
            with _ACTIVE_PROCESS_LOCK:
                _ACTIVE_PROCESSES.discard(process)

    @staticmethod
    def _terminate_and_reap(process: subprocess.Popen) -> None:
        if process.poll() is None:
            try:
                process.terminate()
            except OSError:
                pass
        try:
            process.communicate(timeout=2)
            return
        except subprocess.TimeoutExpired:
            pass
        if process.poll() is None:
            try:
                process.kill()
            except OSError:
                pass
        process.communicate()

    @staticmethod
    def _has_gif_magic(path: Path) -> bool:
        try:
            with path.open("rb") as handle:
                return handle.read(6) in {b"GIF87a", b"GIF89a"}
        except OSError as error:
            raise MediaNormalizationError(f"Could not inspect {path.name}: {error}") from error

    @staticmethod
    def _ebml_doc_type(path: Path) -> Optional[str]:
        """Read the EBML DocType so Matroska is not mistaken for genuine WebM."""
        try:
            with path.open("rb") as handle:
                header = handle.read(4096)
        except OSError as error:
            raise MediaNormalizationError(f"Could not inspect {path.name}: {error}") from error

        marker = b"\x42\x82"
        offset = header.find(marker)
        while offset >= 0:
            length_offset = offset + len(marker)
            if length_offset >= len(header):
                return None
            first = header[length_offset]
            mask = 0x80
            width = 1
            while width <= 8 and not first & mask:
                mask >>= 1
                width += 1
            if width > 8 or length_offset + width > len(header):
                return None
            length = first & (mask - 1)
            for byte in header[length_offset + 1:length_offset + width]:
                length = (length << 8) | byte
            value_offset = length_offset + width
            value = header[value_offset:value_offset + length]
            if len(value) == length:
                try:
                    doc_type = value.decode("ascii").lower()
                except UnicodeDecodeError:
                    pass
                else:
                    if doc_type in {"webm", "matroska"}:
                        return doc_type
            offset = header.find(marker, offset + 1)
        return None

    @staticmethod
    def _available_preserved_path(source: Path) -> Path:
        candidate = source.with_name(f"{source.name}.nodraw-source")
        counter = 1
        while candidate.exists():
            candidate = source.with_name(f"{source.name}.{counter}.nodraw-source")
            counter += 1
        return candidate

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        try:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        except OSError as error:
            raise MediaNormalizationError(
                f"Could not hash staged media {path.name}: {error}"
            ) from error
        return digest.hexdigest()

    @staticmethod
    def _optional_float(value: Any) -> Optional[float]:
        try:
            return float(value) if value is not None else None
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _optional_int(value: Any) -> Optional[int]:
        try:
            return int(value) if value is not None else None
        except (TypeError, ValueError):
            return None
