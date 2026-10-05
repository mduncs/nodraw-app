"""
Database module for tracking archives
"""

from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Optional, List, Dict
import aiosqlite
import json
import logging
import hashlib

logger = logging.getLogger(__name__)


class CaptureMutationConflict(ValueError):
    """A durable metadata token was reused for different fields."""

# A finished capture never uses its page screenshot again (only a failed one is
# retried), and the base64 screenshots were most of archive.db (306 of 345 MB).
_HAS_SCREENSHOT = """CASE WHEN json_valid(intent_json)
    THEN coalesce(json_extract(intent_json, '$.options.screenshot'), '') <> '' ELSE 0 END"""
_WITHOUT_SCREENSHOT = f"""CASE WHEN {_HAS_SCREENSHOT}
    THEN json_set(intent_json, '$.options.screenshot', '') ELSE intent_json END"""


class Database:
    """SQLite database for tracking archive jobs and media files"""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = None

    async def initialize(self):
        """Initialize database and create tables"""
        self.conn = await aiosqlite.connect(str(self.db_path))

        # Create archive_jobs table
        await self.conn.execute("""
            CREATE TABLE IF NOT EXISTS archive_jobs (
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
        """)

        # Create media_files table
        await self.conn.execute("""
            CREATE TABLE IF NOT EXISTS media_files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT UNIQUE NOT NULL,
                url TEXT,
                media_type TEXT,
                mime_type TEXT,
                title TEXT,
                description TEXT,
                author TEXT,
                file_size INTEGER,
                duration INTEGER,
                width INTEGER,
                height INTEGER,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                archived_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                accessed_at TIMESTAMP,
                tags TEXT,
                metadata TEXT
            )
        """)

        # Create indexes
        await self.conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_status ON archive_jobs(status)")
        await self.conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_created ON archive_jobs(created_at)")
        # The app polls status-filtered, newest-first job lists. Separate status
        # and date indexes make SQLite sort the matching rows into a temporary
        # B-tree on every poll, causing severe write amplification on large DBs.
        await self.conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_jobs_status_created
            ON archive_jobs(status, created_at DESC)
            """
        )
        await self.conn.execute("CREATE INDEX IF NOT EXISTS idx_jobs_url ON archive_jobs(url)")
        await self.conn.execute("CREATE INDEX IF NOT EXISTS idx_files_url ON media_files(url)")
        await self.conn.execute("CREATE INDEX IF NOT EXISTS idx_files_type ON media_files(media_type)")

        # CaptureIntent columns are appended in place so existing personal
        # archive databases migrate without a separate command.
        async with self.conn.execute("PRAGMA table_info(archive_jobs)") as cursor:
            existing_columns = {row[1] async for row in cursor}
        capture_columns = {
            'capture_id': 'TEXT',
            'fingerprint': 'TEXT',
            'capture_kind': 'TEXT',
            'intent_json': 'TEXT',
            'metadata_revision': 'INTEGER NOT NULL DEFAULT 0',
            'projection_json': 'TEXT',
            'projection_error': 'TEXT',
            'projected_revision': 'INTEGER NOT NULL DEFAULT 0',
        }
        for column, column_type in capture_columns.items():
            if column not in existing_columns:
                await self.conn.execute(
                    f"ALTER TABLE archive_jobs ADD COLUMN {column} {column_type}"
                )
        # Keep receipts for the lifetime of a capture. Pruning a token would
        # authorize a delayed browser replay to apply an obsolete edit again.
        await self.conn.execute("""
            CREATE TABLE IF NOT EXISTS capture_metadata_mutations (
                capture_id TEXT NOT NULL,
                mutation_id TEXT NOT NULL,
                payload_hash TEXT NOT NULL,
                accepted_revision INTEGER NOT NULL,
                PRIMARY KEY (capture_id, mutation_id)
            )
        """)
        await self.conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_capture_id ON archive_jobs(capture_id)"
        )
        # Early CaptureIntent builds used a non-unique fingerprint index. Repair
        # that schema once, but do not drop/rebuild the healthy unique partial
        # index on every boot: doing so rewrites schema pages and reruns a full
        # duplicate scrub even when there is nothing to migrate.
        if not await self._has_healthy_fingerprint_index():
            await self.conn.execute("DROP INDEX IF EXISTS idx_jobs_fingerprint")
            await self.conn.execute(
                """
                UPDATE archive_jobs
                SET fingerprint = NULL
                WHERE fingerprint IS NOT NULL
                  AND rowid NOT IN (
                      SELECT MAX(rowid)
                      FROM archive_jobs
                      WHERE fingerprint IS NOT NULL
                      GROUP BY fingerprint
                  )
                """
            )
            await self.conn.execute(
                """
                CREATE UNIQUE INDEX idx_jobs_fingerprint
                ON archive_jobs(fingerprint)
                WHERE fingerprint IS NOT NULL
                """
            )

        # Builds before 2026-10-03 kept the screenshot after a capture finished.
        # Only VACUUM gives the space back to the disk.
        cursor = await self.conn.execute(
            f"UPDATE archive_jobs SET intent_json = {_WITHOUT_SCREENSHOT} "
            f"WHERE status = 'completed' AND {_HAS_SCREENSHOT}"
        )
        if cursor.rowcount:
            logger.info(f"Dropped screenshots from {cursor.rowcount} finished captures")

        await self.conn.commit()
        logger.info(f"Database initialized at {self.db_path}")

    async def _has_healthy_fingerprint_index(self) -> bool:
        """Return whether the capture fingerprint index already has its final shape."""
        async with self.conn.execute("PRAGMA index_list(archive_jobs)") as cursor:
            index_rows = await cursor.fetchall()
        index_row = next(
            (row for row in index_rows if row[1] == "idx_jobs_fingerprint"),
            None,
        )
        if index_row is None or not bool(index_row[2]) or not bool(index_row[4]):
            return False

        async with self.conn.execute(
            "PRAGMA index_info(idx_jobs_fingerprint)"
        ) as cursor:
            indexed_columns = [row[2] for row in await cursor.fetchall()]
        if indexed_columns != ["fingerprint"]:
            return False

        async with self.conn.execute(
            """
            SELECT sql FROM sqlite_master
            WHERE type = 'index' AND name = 'idx_jobs_fingerprint'
            """
        ) as cursor:
            definition_row = await cursor.fetchone()
        if not definition_row or not definition_row[0]:
            return False
        normalized_sql = " ".join(str(definition_row[0]).lower().split())
        return "where fingerprint is not null" in normalized_sql

    async def close(self):
        """Close database connection"""
        if self.conn:
            await self.conn.close()

    async def create_job(
        self,
        job_id: str,
        url: str,
        page_title: Optional[str] = None,
        page_url: Optional[str] = None,
        timestamp: Optional[datetime] = None,
        capture_id: Optional[str] = None,
        fingerprint: Optional[str] = None,
        capture_kind: Optional[str] = None,
        intent: Optional[Dict] = None,
    ):
        """Create a new archive job"""
        cursor = await self.conn.execute("""
            INSERT OR IGNORE INTO archive_jobs (
                id, url, status, page_title, page_url, created_at,
                capture_id, fingerprint, capture_kind, intent_json
            )
            VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?)
        """, (
            job_id, url, page_title, page_url, timestamp or datetime.now(),
            capture_id, fingerprint, capture_kind,
            json.dumps(intent) if intent is not None else None,
        ))

        await self.conn.commit()
        return cursor.rowcount == 1

    async def update_job_status(self, job_id: str, status: str):
        """Update job status"""
        await self.conn.execute("""
            UPDATE archive_jobs
            SET status = ?
            WHERE id = ?
        """, (status, job_id))

        await self.conn.commit()

    async def update_job_complete(
        self,
        job_id: str,
        file_path: str,
        metadata: Dict
    ):
        """Update job when download completes"""
        from capture_recovery import current_attempt
        attempt = current_attempt.get()
        if attempt is not None:
            attempt.prepare_completion(file_path, metadata)
        await self.conn.execute(f"""
            UPDATE archive_jobs
            SET status = 'completed',
                completed_at = ?,
                file_path = ?,
                metadata = ?,
                intent_json = {_WITHOUT_SCREENSHOT}
            WHERE id = ?
        """, (datetime.now(), file_path, json.dumps(metadata), job_id))

        await self.conn.commit()

        # Also create media_file record
        await self._create_media_file(file_path, metadata)

    async def update_job_failed(self, job_id: str, error: str, error_category: str = 'server_error'):
        """Update job when download fails"""
        await self.conn.execute("""
            UPDATE archive_jobs
            SET status = 'failed',
                completed_at = ?,
                error = ?,
                metadata = ?
            WHERE id = ?
        """, (datetime.now(), error, json.dumps({'error_category': error_category}), job_id))

        await self.conn.commit()

    async def get_job(self, job_id: str) -> Optional[Dict]:
        """Get single job by ID"""
        async with self.conn.execute("""
            SELECT * FROM archive_jobs WHERE id = ?
        """, (job_id,)) as cursor:
            row = await cursor.fetchone()

            if row:
                return self._row_to_job_dict(row)

        return None

    async def get_job_by_capture_id(self, capture_id: str) -> Optional[Dict]:
        """Find the durable receipt for an idempotent capture submission."""
        async with self.conn.execute(
            "SELECT * FROM archive_jobs WHERE capture_id = ? LIMIT 1",
            (capture_id,),
        ) as cursor:
            row = await cursor.fetchone()
        return self._row_to_job_dict(row) if row else None

    async def get_job_by_fingerprint(self, fingerprint: str) -> Optional[Dict]:
        """Find the newest semantically equivalent capture."""
        async with self.conn.execute(
            """
            SELECT * FROM archive_jobs
            WHERE fingerprint = ?
            ORDER BY created_at DESC
            LIMIT 1
            """,
            (fingerprint,),
        ) as cursor:
            row = await cursor.fetchone()
        return self._row_to_job_dict(row) if row else None

    async def update_capture_intent(self, capture_id: str, intent: Dict):
        """Persist tag/note edits made after the initial capture."""
        await self.conn.execute(
            "UPDATE archive_jobs SET intent_json = ? WHERE capture_id = ?",
            (json.dumps(intent), capture_id),
        )
        await self.conn.commit()

    async def record_capture_sidecar(self, job_id: str, sidecar_path: str):
        """Remember a relocated sidecar without replacing other job metadata."""
        await self.conn.execute(
            "UPDATE archive_jobs SET metadata = json_set(coalesce(metadata, '{}'), '$.sidecar_path', ?) WHERE id = ?",
            (sidecar_path, job_id),
        )
        await self.conn.commit()

    async def enqueue_capture_patch(self, capture_id: str, fields: Dict, bases: Dict, mutation_id: Optional[str] = None):
        """Commit intent fields and projection intent together, without lost updates.

        A dedicated transaction avoids unrelated coroutines on the shared read/job
        connection accidentally committing this multi-statement mutation.
        """
        async with aiosqlite.connect(str(self.db_path)) as conn:
            await conn.execute("BEGIN IMMEDIATE")
            payload_hash = hashlib.sha256(json.dumps(fields, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
            if mutation_id:
                async with conn.execute("SELECT payload_hash, accepted_revision FROM capture_metadata_mutations WHERE capture_id = ? AND mutation_id = ?", (capture_id, mutation_id)) as cursor:
                    accepted = await cursor.fetchone()
                if accepted:
                    if accepted[0] != payload_hash:
                        raise CaptureMutationConflict("Metadata mutationId was already used for different fields")
                    await conn.rollback()
                    job = await self.get_job_by_capture_id(capture_id)
                    if job is not None:
                        job["accepted_mutation_revision"] = accepted[1]
                    return job
            async with conn.execute("SELECT intent_json, projection_json, metadata_revision FROM archive_jobs WHERE capture_id = ?", (capture_id,)) as cursor:
                row = await cursor.fetchone()
            if not row:
                return None
            intent = json.loads(row[0]) if row[0] else {}
            pending = json.loads(row[1]) if row[1] else {"fields": {}, "bases": {}}
            for field, value in fields.items():
                intent.setdefault("user", {})["note" if field == "notes" else field] = value
                # An older flush may still commit after this newer edit. Both
                # the observed base and its pending predecessor are legitimate.
                allowed = [bases[field]] if field in bases else []
                if field in pending["fields"]:
                    allowed += pending["bases"].get(field, []) + [pending["fields"][field]]
                pending["bases"][field] = allowed
                pending["fields"][field] = value
            revision = row[2] + 1
            await conn.execute("UPDATE archive_jobs SET intent_json = ?, metadata_revision = ?, projection_json = ?, projection_error = NULL WHERE capture_id = ?", (json.dumps(intent), revision, json.dumps(pending), capture_id))
            if mutation_id:
                await conn.execute("INSERT INTO capture_metadata_mutations VALUES (?, ?, ?, ?)", (capture_id, mutation_id, payload_hash, revision))
            await conn.commit()
        job = await self.get_job_by_capture_id(capture_id)
        if job is not None:
            job["accepted_mutation_revision"] = revision
        return job

    async def finish_capture_projection(self, capture_id: str, revision: int, error: Optional[str] = None):
        if error is None:
            await self.conn.execute("UPDATE archive_jobs SET projection_json = NULL, projection_error = NULL, projected_revision = ? WHERE capture_id = ? AND metadata_revision = ?", (revision, capture_id, revision))
        else:
            await self.conn.execute("UPDATE archive_jobs SET projection_error = ? WHERE capture_id = ? AND metadata_revision = ?", (error, capture_id, revision))
        await self.conn.commit()

    async def pending_capture_projections(self):
        async with self.conn.execute("SELECT * FROM archive_jobs WHERE projection_json IS NOT NULL") as cursor:
            return [self._row_to_job_dict(row) for row in await cursor.fetchall()]

    async def interrupted_jobs(self):
        async with self.conn.execute("SELECT * FROM archive_jobs WHERE status IN ('pending', 'downloading')") as cursor:
            return [self._row_to_job_dict(row) for row in await cursor.fetchall()]

    async def claim_capture_retry(self, capture_id: str) -> bool:
        """Atomically reset a failed capture so exactly one retry can dispatch."""
        cursor = await self.conn.execute(
            """
            UPDATE archive_jobs
            SET status = 'pending',
                completed_at = NULL,
                file_path = NULL,
                file_size = NULL,
                file_hash = NULL,
                metadata = NULL,
                error = NULL
            WHERE capture_id = ? AND status = 'failed'
            """,
            (capture_id,),
        )
        await self.conn.commit()
        return cursor.rowcount == 1

    async def get_jobs(
        self,
        limit: int = 50,
        status: Optional[str] = None
    ) -> List[Dict]:
        """Get list of jobs"""
        query = "SELECT * FROM archive_jobs"
        params = []

        if status:
            query += " WHERE status = ?"
            params.append(status)

        query += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)

        jobs = []
        async with self.conn.execute(query, params) as cursor:
            async for row in cursor:
                jobs.append(self._row_to_job_dict(row))

        return jobs

    async def search(self, query: str, limit: int = 50) -> List[Dict]:
        """Search for archived media"""
        search_term = f"%{query}%"

        results = []
        async with self.conn.execute("""
            SELECT * FROM media_files
            WHERE url LIKE ? OR title LIKE ? OR description LIKE ? OR author LIKE ?
            ORDER BY archived_at DESC
            LIMIT ?
        """, (search_term, search_term, search_term, search_term, limit)) as cursor:
            async for row in cursor:
                results.append(self._row_to_media_dict(row))

        return results

    async def check_url_archived(
        self,
        url: str,
        months: int = 3
    ) -> Optional[Dict]:
        """
        Check if URL has been successfully archived recently.
        Returns the most recent completed archive for this URL, or None.

        Args:
            url: The URL to check
            months: Only check archives from last N months (default: 3)

        Returns:
            Dict with job info and file verification status, or None
        """
        since_date = datetime.now() - timedelta(days=months * 30)

        async with self.conn.execute("""
            SELECT * FROM archive_jobs
            WHERE url = ?
              AND status = 'completed'
              AND created_at >= ?
            ORDER BY created_at DESC
            LIMIT 1
        """, (url, since_date)) as cursor:
            row = await cursor.fetchone()

            if not row:
                return None

            job_dict = self._row_to_job_dict(row)

            # Verify file actually exists on disk
            file_exists = False
            if job_dict.get('file_path'):
                file_path = Path(job_dict['file_path'])
                file_exists = file_path.exists()

            # Calculate age in days
            created_at = job_dict.get('created_at')
            if isinstance(created_at, str):
                created_at = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
            # Intents store an aware UTC createdAt; the create_job fallback is naive local
            # time, which astimezone() also reads as local. Compare in UTC so a fresh save
            # west of Greenwich is not "-1 days ago".
            if created_at and isinstance(created_at, datetime):
                created_at = created_at.astimezone(timezone.utc).replace(tzinfo=None)
            now_utc = datetime.now(timezone.utc).replace(tzinfo=None)
            age_days = max(0, (now_utc - created_at).days) if created_at else 0

            return {
                **job_dict,
                'file_exists': file_exists,
                'verified': file_exists,
                'age_days': age_days
            }

    async def get_stats(self) -> Dict:
        """Get archive statistics"""
        stats = {}

        # Total archives
        async with self.conn.execute("SELECT COUNT(*) FROM archive_jobs WHERE status = 'completed'") as cursor:
            row = await cursor.fetchone()
            stats['total_archives'] = row[0] if row else 0

        # Today's count
        today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        async with self.conn.execute("""
            SELECT COUNT(*) FROM archive_jobs
            WHERE status = 'completed' AND created_at >= ?
        """, (today,)) as cursor:
            row = await cursor.fetchone()
            stats['today_count'] = row[0] if row else 0

        # This week's count
        week_ago = datetime.now() - timedelta(days=7)
        async with self.conn.execute("""
            SELECT COUNT(*) FROM archive_jobs
            WHERE status = 'completed' AND created_at >= ?
        """, (week_ago,)) as cursor:
            row = await cursor.fetchone()
            stats['week_count'] = row[0] if row else 0

        # Total size
        async with self.conn.execute("SELECT SUM(file_size) FROM media_files") as cursor:
            row = await cursor.fetchone()
            stats['total_size'] = row[0] if row and row[0] else 0

        # By type
        async with self.conn.execute("""
            SELECT media_type, COUNT(*), SUM(file_size)
            FROM media_files
            GROUP BY media_type
        """) as cursor:
            type_stats = {}
            async for row in cursor:
                if row[0]:
                    type_stats[row[0]] = {
                        'count': row[1],
                        'size': row[2] or 0
                    }
            stats['by_type'] = type_stats

        return stats

    async def _create_media_file(self, file_path: str, metadata: Dict):
        """Create media file record"""
        path = Path(file_path)

        # Determine media type
        ext = path.suffix.lower()
        if ext in ['.mp4', '.webm', '.mkv', '.avi', '.mov']:
            media_type = 'video'
        elif ext in ['.mp3', '.m4a', '.flac', '.wav', '.ogg']:
            media_type = 'audio'
        elif ext in ['.jpg', '.jpeg', '.png', '.gif', '.webp']:
            media_type = 'images'
        elif ext in ['.pdf', '.txt', '.html', '.epub']:
            media_type = 'documents'
        else:
            media_type = 'other'

        try:
            file_size = path.stat().st_size if path.exists() else 0

            await self.conn.execute("""
                INSERT OR REPLACE INTO media_files
                (path, url, media_type, title, description, author, file_size, duration, width, height, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                str(file_path),
                metadata.get('original_url'),
                media_type,
                metadata.get('title'),
                metadata.get('description'),
                metadata.get('uploader') or metadata.get('author'),
                file_size,
                metadata.get('duration'),
                metadata.get('width'),
                metadata.get('height'),
                json.dumps(metadata)
            ))

            await self.conn.commit()
        except Exception as e:
            logger.error(f"Failed to create media file record: {e}")

    def _row_to_job_dict(self, row) -> Dict:
        """Convert database row to job dictionary"""
        metadata = json.loads(row[10]) if row[10] else {}
        intent = json.loads(row[15]) if len(row) > 15 and row[15] else None
        return {
            'id': row[0],
            'url': row[1],
            'status': row[2],
            'page_title': row[3],
            'page_url': row[4],
            'created_at': row[5],
            'completed_at': row[6],
            'file_path': row[7],
            'file_size': row[8],
            'file_hash': row[9],
            'metadata': metadata,
            'error': row[11],
            'error_category': metadata.get('error_category'),
            'capture_id': row[12] if len(row) > 12 else None,
            'fingerprint': row[13] if len(row) > 13 else None,
            'capture_kind': row[14] if len(row) > 14 else None,
            'intent': intent,
            'metadata_revision': row[16] if len(row) > 16 else 0,
            'metadata_projection': json.loads(row[17]) if len(row) > 17 and row[17] else None,
            'projection_error': row[18] if len(row) > 18 else None,
            'projected_revision': row[19] if len(row) > 19 else 0,
        }

    def _row_to_media_dict(self, row) -> Dict:
        """Convert database row to media dictionary"""
        return {
            'id': row[0],
            'path': row[1],
            'url': row[2],
            'media_type': row[3],
            'mime_type': row[4],
            'title': row[5],
            'description': row[6],
            'author': row[7],
            'file_size': row[8],
            'duration': row[9],
            'width': row[10],
            'height': row[11],
            'created_at': row[12],
            'archived_at': row[13],
            'accessed_at': row[14],
            'tags': json.loads(row[15]) if row[15] else [],
            'metadata': json.loads(row[16]) if row[16] else {}
        }

__all__ = ['Database']
