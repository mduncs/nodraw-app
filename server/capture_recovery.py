"""Crash evidence around the existing no-clobber publication machinery.

The journal contains paths/hashes and completion metadata, never intent/cookies.
Pre-move records close the hard-crash gap that in-process rollback cannot cover.
"""
from __future__ import annotations

from contextvars import ContextVar
from functools import wraps
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import threading
from uuid import uuid4


current_attempt = ContextVar("nodraw_capture_attempt", default=None)
logger = logging.getLogger(__name__)


def register_staging(path: Path):
    attempt = current_attempt.get()
    if attempt is not None:
        with attempt.lock:
            attempt.state.setdefault("staging", []).append(str(path.parent.resolve() / path.name))
            attempt.save()


def digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


class Attempt:
    def __init__(self, root: Path, job_id: str):
        self.root = root.resolve()
        directory = self.root / ".nodraw-attempts"
        directory.mkdir(mode=0o700, exist_ok=True)
        self.path = directory / f"{uuid4().hex}.json"
        self.state = {"version": 1, "job_id": job_id, "root": str(self.root), "moves": [], "completion": None, "settled": False}
        self.lock = threading.RLock()
        self.save()

    def save(self):
        temporary = self.path.with_suffix(".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(self.state, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.path)
        fd = os.open(self.path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def before_move(self, source: Path, destination: Path):
        with self.lock:
            stat = source.stat()
            self.state["moves"].append({"source": str(source.resolve()), "destination": str(destination.parent.resolve() / destination.name), "sha256": digest(source), "device": stat.st_dev, "inode": stat.st_ino})
            self.save()

    def prepare_completion(self, file_path: str, metadata: dict):
        with self.lock:
            # Gallery metadata deliberately uses output-relative file names;
            # publication records, not process cwd, identify the complete family.
            required = {file_path, *(str(path) for path in _public_candidates(self.state, self.root))}
            if metadata.get("sidecar_path"):
                required.add(metadata["sidecar_path"])
            self.state["completion"] = {"file_path": file_path, "metadata": metadata, "required": {str(path): digest(Path(path)) for path in required}}
            self.save()


def track_capture(database_provider, service_provider):
    def decorate(function):
        @wraps(function)
        async def tracked(*args, **kwargs):
            database = database_provider()
            # Unit processor fakes have no filesystem authority.
            from database import Database
            if not isinstance(database, Database):
                return await function(*args, **kwargs)
            job_id = kwargs.get("job_id") or args[0]
            try:
                attempt = Attempt(database.db_path.parent, job_id)
            except Exception as exc:
                await database.update_job_failed(job_id, f"Could not prepare durable capture storage: {exc}", "capture_storage_failed")
                return None
            token = current_attempt.set(attempt)
            try:
                result = await function(*args, **kwargs)
                job = await database.get_job(job_id)
                if job and job["status"] == "completed":
                    await service_provider().flush_projection(job)
                    # The capture already succeeded; an unsettled journal is only
                    # settled again by the next startup pass.
                    try:
                        with attempt.lock:
                            _cleanup_staging(attempt.state, attempt.root)
                            _settle_journal(attempt.path, attempt.state)
                    except Exception:
                        logger.exception("Could not settle capture attempt: %s", attempt.path)
                return result
            finally:
                current_attempt.reset(token)
        return tracked
    return decorate


def _public_candidates(state: dict, root: Path):
    """Verify every surviving public destination; changed files are never moved."""
    expected = {}
    for move in state["moves"]:
        source = Path(move["source"])
        destination = Path(move["destination"])
        expected[source] = move
        expected[destination] = move
    paths = []
    for path, move in expected.items():
        try:
            relative = path.relative_to(root)
        except ValueError:
            # Downloader-owned temporary staging can live outside the archive;
            # it is evidence only, never an authorized recovery mutation target.
            continue
        if any(part.startswith(".") for part in relative.parts):
            continue
        if not os.path.lexists(path):
            continue
        path.resolve().relative_to(root)
        stat = path.stat()
        if path.is_symlink() or not path.is_file() or stat.st_dev != move["device"] or stat.st_ino != move["inode"] or digest(path) != move["sha256"]:
            raise RuntimeError(f"Interrupted capture artifact changed; preserve and review before retry: {path}")
        paths.append(path)
    return paths


def _read_unsettled_journals(root: Path):
    """Read each journal once; a damaged record cannot poison other jobs."""
    directory = root / ".nodraw-attempts"
    journals = {}
    for path in directory.glob("*.json"):
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(state, dict):
                raise ValueError("Capture attempt must be a JSON object")
            if state.get("settled"):
                continue
            job_id = state.get("job_id")
            if not isinstance(job_id, str) or not job_id or not isinstance(state.get("moves"), list):
                raise ValueError("Capture attempt has invalid job_id or moves")
            journals.setdefault(job_id, []).append((path, state))
        except Exception:
            logger.exception("Unreadable capture attempt requires review: %s", path)
    return journals


def _cleanup_staging(state: dict, root: Path):
    for raw_stage in state.get("staging", []):
        stage = Path(raw_stage)
        stage.resolve().relative_to(root)
        if stage.is_symlink():
            raise RuntimeError(f"Interrupted staging was replaced by a symlink: {stage}")
        # Exact private control files contain only transient credentials.
        for name in (".cookies.txt", ".gallery-dl.conf"):
            credential = stage / name
            if credential.is_file() and not credential.is_symlink():
                credential.unlink()


def _settle_journal(path: Path, state: dict):
    state["settled"] = True
    record = object.__new__(Attempt)
    record.path, record.state = path, state
    record.save()


async def reconcile_job(database, job: dict, journals=None):
    """Recover one job, using a startup snapshot or one fresh scan for retry."""
    root = database.db_path.parent.resolve()
    if journals is None:
        journals = _read_unsettled_journals(root).get(job["id"], [])
    if not journals and job["status"] != "completed" and job.get("file_path") and os.path.lexists(job["file_path"]):
        raise RuntimeError(f"Existing capture output has no recoverable attempt record; preserve and review before retry: {job['file_path']}")
    from downloaders.runtime_safety import preserve_public_artifacts
    for path, state in journals:
        _cleanup_staging(state, root)
        if job["status"] == "completed":
            _settle_journal(path, state)
            continue
        candidates = _public_candidates(state, root)
        completion = state.get("completion")
        if completion and all(Path(file).is_file() and not Path(file).is_symlink() and digest(Path(file)) == expected for file, expected in completion["required"].items()):
            await database.update_job_complete(job["id"], completion["file_path"], completion["metadata"])
            job = await database.get_job(job["id"])
            _settle_journal(path, state)
            continue
        # No validated completion intent: keep originals in existing recovery
        # storage before replay. This never deletes or overwrites unrelated data.
        recovery_paths = preserve_public_artifacts(candidates, root)
        state["recovery_paths"] = [str(p) for p in recovery_paths]
        _settle_journal(path, state)
    if job["status"] in {"pending", "downloading"}:
        await database.update_job_failed(job["id"], "Server restarted before capture completion. Any verified partial publication was preserved for recovery; retry with fresh browser credentials.", "server_restart")
    return await database.get_job(job["id"])


def _report_stale_storage(root: Path):
    """Inventory private leftovers without following links or changing files."""
    staging, originals, errors = [], [], []
    parents = [root]
    count = size = 0
    # Handlers use either the archive root or its immediate YYYY-MM folders.
    for parent in parents:
        try:
            with os.scandir(parent) as entries:
                for entry in entries:
                    if not entry.is_dir(follow_symlinks=False):
                        continue
                    path = Path(entry.path)
                    if parent == root and re.fullmatch(r"\d{4}-\d{2}", entry.name):
                        parents.append(path)
                    elif entry.name.startswith(".nodraw-ingest-"):
                        staging.append(str(path.relative_to(root)))
                    elif entry.name == ".nodraw-originals":
                        originals.append(path)
        except OSError as exc:
            errors.append(f"{parent}: {exc}")
    pending = list(originals)
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(Path(entry.path))
                    elif entry.is_file(follow_symlinks=False):
                        size += entry.stat(follow_symlinks=False).st_size
                        count += 1
        except OSError as exc:
            errors.append(f"{directory}: {exc}")
    if staging or originals or errors:
        logger.warning(
            "Stale capture storage requires review (report only): .nodraw-ingest-* dirs=%s; "
            ".nodraw-originals dirs=%s, files=%d, bytes=%d; inspection errors=%s",
            sorted(staging), sorted(str(path.relative_to(root)) for path in originals), count, size, errors,
        )


async def reconcile_startup(database):
    root = database.db_path.parent.resolve()
    _report_stale_storage(root)
    journals = _read_unsettled_journals(root)
    jobs = {job["id"]: job for job in await database.interrupted_jobs()}
    # A crash may occur after a terminal DB commit but before credential cleanup.
    for job_id, records in journals.items():
        if job_id not in jobs:
            job = await database.get_job(job_id)
            if job:
                jobs[job_id] = job
            else:
                for path, _ in records:
                    logger.error("Orphan capture attempt requires review: %s", path)
    for job in jobs.values():
        try:
            await reconcile_job(database, job, journals.get(job["id"], []))
        except Exception as exc:
            if job["status"] != "completed":
                await database.update_job_failed(job["id"], str(exc), "restart_recovery_needed")
            else:
                logger.exception("Completed capture recovery cleanup requires review: %s", job["id"])
