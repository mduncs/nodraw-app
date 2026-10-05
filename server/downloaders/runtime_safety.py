"""Small safety primitives shared by external downloader handlers."""

from __future__ import annotations

import asyncio
import ctypes
import errno
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import threading
from typing import Iterable, Optional
from uuid import uuid4


class ArtifactSafetyError(RuntimeError):
    """A staged artifact could not be safely validated, published, or recovered."""


_ARTIFACT_LOCK = threading.Lock()


async def terminate_and_reap(process, *, grace_seconds: float = 2.0) -> None:
    """Terminate a child, escalate after a deadline, and always reap it."""
    if process is None:
        return

    if process.returncode is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass

    try:
        await asyncio.wait_for(process.wait(), timeout=grace_seconds)
        return
    except asyncio.TimeoutError:
        pass

    if process.returncode is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    # A killed process must be reaped without another short deadline. The OS has
    # already accepted the terminal signal, and abandoning wait() creates a zombie.
    await process.wait()


def write_private_text(path: Path, content: str) -> None:
    """Create a new UTF-8 text file with mode 0600 from its first visible instant."""
    path = Path(path)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        path.unlink(missing_ok=True)
        raise


def require_regular_nonempty(path: Path, *, root: Path) -> Path:
    """Return a contained regular file without following a symbolic-link input."""
    path = Path(path)
    root = Path(root).resolve()
    if path.is_symlink():
        raise ArtifactSafetyError(f"Refusing symbolic-link artifact: {path.name}")
    resolved = path.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise ArtifactSafetyError(f"Artifact escaped staging: {path}") from error
    if not resolved.is_file() or resolved.stat().st_size <= 0:
        raise ArtifactSafetyError(f"Artifact is missing or empty: {path.name}")
    return resolved


def ensure_contained_directory(directory: Path, *, root: Path) -> Path:
    """Create a directory below root while rejecting every symlink ancestor."""
    root = Path(root).absolute()
    directory = Path(directory).absolute()
    try:
        relative = directory.relative_to(root)
    except ValueError as error:
        raise ArtifactSafetyError(f"Artifact directory escaped archive: {directory}") from error

    root_resolved = root.resolve()
    current = root
    for component in relative.parts:
        current = current / component
        if os.path.lexists(current):
            if current.is_symlink():
                raise ArtifactSafetyError(
                    f"Refusing symbolic-link archive directory: {current}"
                )
            if not current.is_dir():
                raise ArtifactSafetyError(
                    f"Archive directory path is not a directory: {current}"
                )
        else:
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                if current.is_symlink() or not current.is_dir():
                    raise ArtifactSafetyError(
                        f"Archive directory changed during creation: {current}"
                    )
        try:
            current.resolve().relative_to(root_resolved)
        except ValueError as error:
            raise ArtifactSafetyError(
                f"Archive directory escaped configured root: {current}"
            ) from error
    return directory


def _atomic_rename_no_replace(source: Path, destination: Path) -> None:
    """Atomically rename without replacement on supported host platforms."""
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)

    if sys.platform == "darwin" and hasattr(libc, "renamex_np"):
        renamex = libc.renamex_np
        renamex.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        renamex.restype = ctypes.c_int
        if renamex(source_bytes, destination_bytes, 0x00000004) == 0:
            return
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        renameat2 = libc.renameat2
        renameat2.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameat2.restype = ctypes.c_int
        if renameat2(-100, source_bytes, -100, destination_bytes, 1) == 0:
            return
    elif os.name == "nt":
        os.rename(source, destination)
        return
    else:
        raise OSError(errno.ENOTSUP, "atomic no-replace rename is unavailable")

    error_number = ctypes.get_errno() or errno.EIO
    raise OSError(error_number, os.strerror(error_number), destination)


def _copy_then_rename_no_clobber(source: Path, destination: Path) -> None:
    """Copy to a hidden sibling, then atomically expose it without replacement."""
    temporary = destination.parent / f".nodraw-publish-{uuid4().hex}.tmp"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    try:
        with source.open("rb") as source_handle, os.fdopen(descriptor, "wb") as target:
            descriptor = -1
            shutil.copyfileobj(source_handle, target, length=1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
        os.chmod(temporary, stat.S_IMODE(source.stat().st_mode))
        # The copy fallback publishes a different inode from its source. Record
        # that exact inode before exposure so a same-byte collision is not
        # mistaken for an owned publication after a crash.
        from capture_recovery import current_attempt
        attempt = current_attempt.get()
        if attempt is not None and not os.path.lexists(destination):
            attempt.before_move(temporary, destination)
        _atomic_rename_no_replace(temporary, destination)
        try:
            source.unlink()
        except OSError as unlink_error:
            try:
                destination.unlink()
            except OSError as cleanup_error:
                raise ArtifactSafetyError(
                    f"Published {destination} but could not retire {source} "
                    f"({unlink_error}) or undo destination ({cleanup_error})"
                ) from cleanup_error
            raise ArtifactSafetyError(
                f"Could not retire staged artifact {source}: {unlink_error}"
            ) from unlink_error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _move_file_no_clobber(source: Path, destination: Path) -> None:
    """Atomically expose a same-volume file, failing if the target already exists."""
    from capture_recovery import current_attempt
    attempt = current_attempt.get()
    with Path(source).open("rb") as handle:
        os.fsync(handle.fileno())
    if attempt is not None and not os.path.lexists(destination):
        attempt.before_move(source, destination)
    _move_file_no_clobber_impl(source, destination)
    for parent in {source.parent, destination.parent}:
        descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _move_file_no_clobber_impl(source: Path, destination: Path) -> None:
    try:
        os.link(source, destination, follow_symlinks=False)
    except TypeError:
        try:
            os.link(source, destination)
        except OSError as link_error:
            if link_error.errno in {errno.EEXIST, errno.ENOTEMPTY}:
                raise
            _copy_then_rename_no_clobber(source, destination)
            return
    except OSError as link_error:
        if link_error.errno in {errno.EEXIST, errno.ENOTEMPTY}:
            raise
        _copy_then_rename_no_clobber(source, destination)
        return
    try:
        source.unlink()
    except OSError as unlink_error:
        try:
            destination.unlink()
        except OSError as cleanup_error:
            raise ArtifactSafetyError(
                f"Published {destination} but could not retire {source} "
                f"({unlink_error}) or undo destination ({cleanup_error})"
            ) from cleanup_error
        raise ArtifactSafetyError(
            f"Could not retire staged artifact {source}: {unlink_error}"
        ) from unlink_error


def _collision_candidate(destination: Path, ordinal: int) -> Path:
    if ordinal <= 1:
        return destination
    return destination.with_name(f"{destination.stem}-{ordinal}{destination.suffix}")


def _family_collision_candidate(
    destination: Path,
    ordinal: int,
    family_stem: Optional[str],
) -> Path:
    if ordinal <= 1:
        return destination
    if family_stem:
        name = destination.name
        if name.startswith(family_stem):
            remainder = name[len(family_stem):]
            if not remainder or remainder[0] in {'.', '-', '_'}:
                return destination.with_name(
                    f"{family_stem}-{ordinal}{remainder}"
                )
    return _collision_candidate(destination, ordinal)


def publish_staged_files(
    sources: Iterable[Path],
    output_dir: Path,
    *,
    family_stem: Optional[str] = None,
) -> dict[Path, Path]:
    """Publish a staged family with one collision ordinal and rollback.

    If any member collides, every member receives the same ordinal.  This keeps
    media, subtitles, thumbnails, and sidecars visibly associated instead of
    independently choosing unrelated suffixes.
    """
    output_dir = Path(output_dir)
    source_paths = [Path(source) for source in sources]
    if not source_paths:
        return {}

    with _ARTIFACT_LOCK:
        base_destinations: dict[Path, Path] = {}
        for source in source_paths:
            regular = require_regular_nonempty(source, root=source.parent)
            destination = output_dir / regular.name.lstrip(".")
            if destination in base_destinations.values():
                raise ArtifactSafetyError(
                    f"Staged family contains duplicate public name: {destination.name}"
                )
            base_destinations[source] = destination

        normalized_family_stem = (
            Path(family_stem).name.lstrip('.') if family_stem else None
        )
        ordinal = 1
        while True:
            destinations = {
                source: _family_collision_candidate(
                    destination,
                    ordinal,
                    normalized_family_stem,
                )
                for source, destination in base_destinations.items()
            }
            candidates = tuple(destinations.values())
            if (
                len(set(candidates)) == len(candidates)
                and not any(os.path.lexists(candidate) for candidate in candidates)
            ):
                break
            ordinal += 1

        moved: list[tuple[Path, Path]] = []
        try:
            for source, destination in destinations.items():
                ensure_contained_directory(destination.parent, root=output_dir)
                _move_file_no_clobber(source, destination)
                moved.append((source, destination))
        except (OSError, ArtifactSafetyError) as error:
            rollback_errors: list[str] = []
            for source, destination in reversed(moved):
                try:
                    _move_file_no_clobber(destination, source)
                except (OSError, ArtifactSafetyError) as rollback_error:
                    rollback_errors.append(f"{destination}: {rollback_error}")
            detail = (
                f"; rollback failures: {', '.join(rollback_errors)}"
                if rollback_errors
                else ""
            )
            raise ArtifactSafetyError(
                f"Could not publish staged artifact family: {error}{detail}"
            ) from error
        return destinations


def _publish_bytes_sync(
    payload: bytes,
    desired_path: Path,
    output_dir: Path,
) -> Path:
    if not payload:
        raise ArtifactSafetyError(
            f"Refusing to publish empty artifact: {desired_path.name}"
        )
    output_dir = Path(output_dir)
    desired_path = Path(desired_path)
    ensure_contained_directory(desired_path.parent, root=output_dir)
    stage_dir = output_dir / f".nodraw-bytes-{uuid4().hex}"
    from capture_recovery import register_staging
    register_staging(stage_dir)
    stage_dir.mkdir(mode=0o700)
    staged_path = stage_dir / f".{desired_path.name}"
    descriptor = -1
    try:
        descriptor = os.open(
            staged_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        destinations = publish_staged_files([staged_path], desired_path.parent)
        return destinations[staged_path]
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        shutil.rmtree(stage_dir, ignore_errors=True)


async def publish_bytes_no_clobber(
    payload: bytes,
    desired_path: Path,
    *,
    output_dir: Path,
) -> Path:
    """Cancellation-safe async publication for generated sidecars/screenshots."""
    worker = asyncio.create_task(
        asyncio.to_thread(
            _publish_bytes_sync,
            payload,
            desired_path,
            output_dir,
        )
    )
    published: Optional[Path] = None
    try:
        published = await asyncio.shield(worker)
        return published
    except asyncio.CancelledError:
        try:
            published = await asyncio.shield(worker)
        except BaseException:
            pass
        if published is not None:
            recovery = asyncio.create_task(
                asyncio.to_thread(
                    preserve_public_artifacts,
                    [published],
                    output_dir,
                )
            )
            try:
                await asyncio.shield(recovery)
            except BaseException as recovery_error:
                raise ArtifactSafetyError(
                    f"Cancellation published {published} but recovery failed: "
                    f"{recovery_error}"
                ) from recovery_error
        raise


def relocate_public_file(source: Path, desired: Path, *, root: Path) -> Path:
    """Rename one known attempt artifact without replacing an existing archive file."""
    source = require_regular_nonempty(source, root=root)
    desired = Path(desired)
    ensure_contained_directory(desired.parent, root=root)
    with _ARTIFACT_LOCK:
        ordinal = 1
        destination = desired
        while os.path.lexists(destination):
            ordinal += 1
            destination = _collision_candidate(desired, ordinal)
        _move_file_no_clobber(source, destination)
    return destination


def preserve_public_artifacts(
    paths: Iterable[Path],
    output_dir: Path,
) -> tuple[Path, ...]:
    """Retract public artifacts into hidden content-addressed recovery storage."""
    output_dir = Path(output_dir).resolve()
    candidates: list[Path] = []
    seen: set[Path] = set()
    for raw_path in paths:
        path = Path(raw_path)
        if not path.is_absolute():
            path = output_dir / path
        if path.is_symlink():
            raise ArtifactSafetyError(f"Refusing public symbolic link: {path}")
        resolved = path.resolve()
        try:
            resolved.relative_to(output_dir)
        except ValueError as error:
            raise ArtifactSafetyError(f"Public artifact escaped archive: {path}") from error
        if resolved in seen or not resolved.exists():
            continue
        require_regular_nonempty(resolved, root=output_dir)
        seen.add(resolved)
        candidates.append(resolved)

    if not candidates:
        return ()

    with _ARTIFACT_LOCK:
        destinations: dict[Path, Path] = {}
        reserved: set[Path] = set()
        for source in candidates:
            digest = hashlib.sha256()
            with source.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            recovery_name = source.name if source.name.startswith(".") else f".{source.name}"
            base = output_dir / ".nodraw-originals" / digest.hexdigest() / recovery_name
            destination = base
            ordinal = 1
            while os.path.lexists(destination) or destination in reserved:
                ordinal += 1
                destination = base.with_name(f"{base.name}.{ordinal}")
            destinations[source] = destination
            reserved.add(destination)

        moved: list[tuple[Path, Path]] = []
        try:
            for source, destination in destinations.items():
                ensure_contained_directory(destination.parent, root=output_dir)
                _move_file_no_clobber(source, destination)
                moved.append((source, destination))
        except (OSError, ArtifactSafetyError) as error:
            rollback_errors: list[str] = []
            for source, destination in reversed(moved):
                try:
                    _move_file_no_clobber(destination, source)
                except (OSError, ArtifactSafetyError) as rollback_error:
                    rollback_errors.append(f"{destination}: {rollback_error}")
            detail = (
                f"; rollback failures: {', '.join(rollback_errors)}"
                if rollback_errors
                else ""
            )
            raise ArtifactSafetyError(
                f"Could not retract public artifact family: {error}{detail}"
            ) from error
        return tuple(destinations.values())
