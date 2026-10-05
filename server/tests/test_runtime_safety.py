"""Deterministic regression tests for staged artifact and child-process safety."""

import asyncio
import errno
from pathlib import Path
from unittest.mock import patch

import pytest

from downloaders.runtime_safety import (
    ArtifactSafetyError,
    preserve_public_artifacts,
    publish_staged_files,
    terminate_and_reap,
)


def test_publish_uses_atomic_copy_fallback_when_hardlinks_are_unavailable(tmp_path):
    stage = tmp_path / ".stage"
    stage.mkdir()
    source = stage / ".portable.mp4"
    source.write_bytes(b"complete media")

    with patch(
        "downloaders.runtime_safety.os.link",
        side_effect=OSError(errno.EXDEV, "cross-device link"),
    ):
        destinations = publish_staged_files([source], tmp_path)

    destination = destinations[source]
    assert destination == tmp_path / "portable.mp4"
    assert destination.read_bytes() == b"complete media"
    assert not source.exists()
    assert not list(tmp_path.glob(".nodraw-publish-*.tmp"))


def test_copy_fallback_never_overwrites_destination_created_by_peer(tmp_path):
    stage = tmp_path / ".stage"
    stage.mkdir()
    source = stage / ".race.mp4"
    source.write_bytes(b"this attempt")
    destination = tmp_path / "race.mp4"

    def peer_wins(_temporary, target):
        Path(target).write_bytes(b"peer attempt")
        raise FileExistsError(errno.EEXIST, "destination exists", target)

    with (
        patch(
            "downloaders.runtime_safety.os.link",
            side_effect=OSError(errno.EXDEV, "cross-device link"),
        ),
        patch(
            "downloaders.runtime_safety._atomic_rename_no_replace",
            side_effect=peer_wins,
        ),
    ):
        with pytest.raises(ArtifactSafetyError, match="Could not publish"):
            publish_staged_files([source], tmp_path)

    assert source.read_bytes() == b"this attempt"
    assert destination.read_bytes() == b"peer attempt"
    assert not list(tmp_path.glob(".nodraw-publish-*.tmp"))


def test_family_collision_reserves_one_ordinal_for_every_member(tmp_path):
    stage = tmp_path / ".stage"
    stage.mkdir()
    media = stage / ".capture.mp4"
    subtitle = stage / ".capture.en.vtt"
    media.write_bytes(b"media")
    subtitle.write_bytes(b"WEBVTT")
    existing = tmp_path / "capture.mp4"
    existing.write_bytes(b"peer")

    destinations = publish_staged_files(
        [media, subtitle],
        tmp_path,
        family_stem="capture",
    )

    assert existing.read_bytes() == b"peer"
    assert destinations[media] == tmp_path / "capture-2.mp4"
    assert destinations[subtitle] == tmp_path / "capture-2.en.vtt"
    assert destinations[media].read_bytes() == b"media"
    assert destinations[subtitle].read_bytes() == b"WEBVTT"


def test_family_publish_failure_restores_every_staged_member(tmp_path):
    stage = tmp_path / ".stage"
    stage.mkdir()
    first = stage / ".family.mp4"
    second = stage / ".family.en.vtt"
    first.write_bytes(b"media")
    second.write_bytes(b"WEBVTT")

    from downloaders import runtime_safety

    real_move = runtime_safety._move_file_no_clobber
    calls = 0

    def fail_second(source, destination):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("injected family failure")
        return real_move(source, destination)

    with patch.object(runtime_safety, "_move_file_no_clobber", side_effect=fail_second):
        with pytest.raises(ArtifactSafetyError, match="injected family failure"):
            publish_staged_files(
                [first, second],
                tmp_path,
                family_stem="family",
            )

    assert first.read_bytes() == b"media"
    assert second.read_bytes() == b"WEBVTT"
    assert not (tmp_path / "family.mp4").exists()
    assert not (tmp_path / "family.en.vtt").exists()


def test_recovery_rejects_symlinked_hidden_ancestor_without_losing_public_file(
    tmp_path,
):
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (tmp_path / ".nodraw-originals").symlink_to(outside, target_is_directory=True)
    public = tmp_path / "attempt.mp4"
    public.write_bytes(b"attempt bytes")

    with pytest.raises(ArtifactSafetyError, match="symbolic-link archive directory"):
        preserve_public_artifacts([public], tmp_path)

    assert public.read_bytes() == b"attempt bytes"
    assert list(outside.iterdir()) == []
    outside.rmdir()


@pytest.mark.asyncio
async def test_child_cleanup_escalates_to_kill_and_reaps_after_deadline():
    class StubbornProcess:
        returncode = None

        def __init__(self):
            self.terminate_calls = 0
            self.kill_calls = 0
            self.wait_calls = 0

        def terminate(self):
            self.terminate_calls += 1

        def kill(self):
            self.kill_calls += 1
            self.returncode = -9

        async def wait(self):
            self.wait_calls += 1
            if self.kill_calls:
                return self.returncode
            await asyncio.Event().wait()

    process = StubbornProcess()
    await terminate_and_reap(process, grace_seconds=0.001)

    assert process.terminate_calls == 1
    assert process.kill_calls == 1
    assert process.wait_calls == 2
