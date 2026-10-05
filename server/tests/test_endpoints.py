"""
Tests for FastAPI endpoints
"""
import asyncio
from io import BytesIO
from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from unittest.mock import patch, AsyncMock, MagicMock


@pytest.fixture
def client(tmp_path):
    """Test client for FastAPI app"""
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent.parent))

    import main
    from database import Database

    test_db = Database(tmp_path / "archive.db")
    with (
        patch.object(main, "db", test_db),
        patch.object(main, "storage", MagicMock()),
        patch.object(main, "write_port_file"),
        patch.object(main, "remove_port_file"),
        patch.object(main, "register_cleanup"),
        TestClient(main.app, base_url="http://127.0.0.1:8847") as test_client,
    ):
        yield test_client


class TestLocalClientsOnly:
    """Only NoDraw's own clients may drive the server; any web page can reach the port."""

    CHROME = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
    FIREFOX = "moz-extension://0b3c2a4e-8f1d-4c7a-9e2b-5d6f7a8b9c0d"

    @pytest.mark.parametrize("host", ["127.0.0.1:8847", "localhost:8847", "[::1]:8847", "LOCALHOST"])
    def test_loopback_hosts_are_served(self, client, host):
        assert client.get("/health", headers={"host": host}).status_code == 200

    @pytest.mark.parametrize("host", ["evil.example:8847", "127.0.0.1.evil.example", ""])
    def test_other_hosts_are_refused(self, client, host):
        response = client.get("/health", headers={"host": host})
        assert response.status_code == 403
        assert "localhost" in response.json()["detail"]

    def test_malformed_host_is_refused(self):
        from main import _local_request_refusal
        assert _local_request_refusal("GET", "[::1", None)

    @pytest.mark.parametrize("origin", ["https://evil.example", "null", "http://localhost:3000", "chrome-extension://"])
    def test_writes_from_web_pages_are_refused(self, client, origin):
        response = client.post("/captures", headers={"origin": origin}, json={})
        assert response.status_code == 403

    @pytest.mark.parametrize("origin", [CHROME, FIREFOX, "http://127.0.0.1:8847", None])
    def test_writes_from_own_clients_reach_the_route(self, client, origin):
        headers = {"origin": origin} if origin else {}
        # An empty body fails validation inside the route, past the middleware.
        assert client.post("/captures", headers=headers, json={}).status_code == 422

    def test_reads_ignore_origin(self, client):
        assert client.get("/health", headers={"origin": "https://evil.example"}).status_code == 200

    @pytest.mark.parametrize("origin", [CHROME, FIREFOX])
    def test_cors_answers_extension_origins(self, client, origin):
        response = client.options("/captures", headers={
            "origin": origin, "access-control-request-method": "POST",
        })
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == origin

    def test_cors_ignores_web_origins(self, client):
        response = client.get("/health", headers={"origin": "https://evil.example"})
        assert "access-control-allow-origin" not in response.headers


class TestHealthEndpoint:
    """Tests for /health endpoint"""

    def test_health_returns_ok(self, client):
        """Health check returns success"""
        response = client.get("/health")

        assert response.status_code == 200
        data = response.json()
        assert data["status"] in ["ok", "healthy"]

    def test_health_lists_handlers(self, client):
        """Health check includes available handlers"""
        response = client.get("/health")
        data = response.json()

        # API uses "downloaders" key
        assert "handlers" in data or "downloaders" in data
        handlers = data.get("handlers") or data.get("downloaders", [])
        assert any("yt-dlp" in h for h in handlers)
        assert any("gallery" in h.lower() for h in handlers)


class TestCaptureEndpoint:
    """Tests for the single versioned capture boundary."""

    def test_capture_accepts_versioned_intent(self, client):
        service = MagicMock()
        service.submit = AsyncMock(return_value={
            "schemaVersion": 1,
            "captureId": "capture-1",
            "jobId": "job-1",
            "disposition": "accepted",
            "status": "accepted",
            "message": "Capture accepted",
        })
        with patch("main.get_capture_service", return_value=service):
            response = client.post("/captures", json={
                "intent": {
                    "schemaVersion": 1,
                    "captureId": "capture-1",
                    "fingerprint": "v1-deadbeef",
                    "kind": "page",
                    "targetUrl": "https://example.com/post",
                    "sourcePageUrl": "https://example.com/post",
                    "createdAt": "2026-01-01T12:00:00Z",
                    "page": {"title": "A post"},
                }
            })

        assert response.status_code == 200
        assert response.json()["captureId"] == "capture-1"
        service.submit.assert_awaited_once()

    def test_capture_rejects_collection_target_without_dispatch(self, client):
        from capture_service import CaptureTargetRejectedError

        service = MagicMock()
        service.submit = AsyncMock(side_effect=CaptureTargetRejectedError(
            "Open a specific post before archiving from X."
        ))
        with patch("main.get_capture_service", return_value=service):
            response = client.post("/captures", json={
                "intent": {
                    "schemaVersion": 1,
                    "captureId": "capture-feed",
                    "fingerprint": "v1-feed",
                    "kind": "page",
                    "targetUrl": "https://x.com/home",
                    "sourcePageUrl": "https://x.com/home",
                    "createdAt": "2026-01-01T12:00:00Z",
                }
            })

        assert response.status_code == 400
        assert "specific post" in response.json()["detail"]
        service.submit.assert_awaited_once()

    @pytest.mark.parametrize("path", ["/archive", "/archive-image"])
    def test_removed_compatibility_routes_are_not_found(self, client, path):
        response = client.post(path, json={})

        assert response.status_code == 404


@pytest.mark.asyncio
async def test_image_processor_forwards_capture_download_options():
    from capture_service import CaptureIntent
    from main import process_image_capture

    intent = CaptureIntent(
        captureId="capture-image",
        fingerprint="v1-image",
        kind="media",
        targetUrl="https://example.com/image.jpg",
        sourcePageUrl="https://example.com/artwork",
        createdAt="2026-01-01T12:00:00Z",
        media={"url": "https://example.com/image.jpg", "type": "image"},
        options={
            "download": {"max_width": 8192, "full_resolution": True},
            "siteData": {"dateTaken": "1889", "assetId": "museum-123"},
        },
    )
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_failed = AsyncMock()
    archive_impl = AsyncMock(return_value={"success": False, "message": "expected"})

    with patch("main.db", database), patch("main._archive_image_impl", archive_impl):
        await process_image_capture("job-image", intent, [])

    request = archive_impl.await_args.args[0]
    assert archive_impl.await_args.kwargs["capture_id"] == intent.captureId
    # Only keys the extension sends pass; nothing reads full_resolution.
    assert request.options == {"max_width": 8192}
    assert request.metadata.dateTaken == "1889"
    assert request.metadata.assetId == "museum-123"


def _image_intent():
    from capture_service import CaptureIntent

    return CaptureIntent(
        captureId="capture-image-safety",
        fingerprint="v1-image-safety",
        kind="media",
        targetUrl="https://example.com/image.jpg",
        sourcePageUrl="https://example.com/artwork",
        createdAt="2026-01-01T12:00:00Z",
        media={"url": "https://example.com/image.jpg", "type": "image"},
    )


@pytest.mark.asyncio
async def test_image_processor_rejects_success_without_real_file(tmp_path):
    from main import process_image_capture

    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()
    archive_impl = AsyncMock(return_value={
        "success": True,
        "file_path": str(tmp_path / "missing.jpg"),
        "published_paths": [],
        "output_dir": str(tmp_path),
    })

    with patch("main.db", database), patch("main._archive_image_impl", archive_impl):
        await process_image_capture("job-image-missing", _image_intent(), [])

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once()


@pytest.mark.asyncio
async def test_image_processor_cancellation_records_durable_failure():
    from main import process_image_capture

    started = asyncio.Event()

    async def blocked_archive(_request, *, capture_id):
        started.set()
        await asyncio.Event().wait()

    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()

    with (
        patch("main.db", database),
        patch("main._archive_image_impl", side_effect=blocked_archive),
    ):
        task = asyncio.create_task(process_image_capture(
            "job-image-cancelled",
            _image_intent(),
            [],
        ))
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

    database.update_job_complete.assert_not_awaited()
    database.update_job_failed.assert_awaited_once_with(
        "job-image-cancelled",
        "Image capture cancelled",
        "cancelled",
    )


@pytest.mark.asyncio
async def test_image_processor_db_failure_retracts_exact_published_file(tmp_path):
    from main import process_image_capture

    media = tmp_path / "image-attempt.jpg"
    media.write_bytes(b"image bytes")
    sidecar = tmp_path / "image-attempt.md"
    sidecar.write_text("sidecar")
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock(side_effect=OSError("db unavailable"))
    database.update_job_failed = AsyncMock()
    archive_impl = AsyncMock(return_value={
        "success": True,
        "file_path": str(media),
        "published_paths": [str(media), str(sidecar)],
        "output_dir": str(tmp_path),
    })

    with patch("main.db", database), patch("main._archive_image_impl", archive_impl):
        await process_image_capture("job-image-db-failure", _image_intent(), [])

    assert not media.exists()
    assert not sidecar.exists()
    assert list((tmp_path / ".nodraw-originals").glob("*/.image-attempt.jpg"))
    assert list((tmp_path / ".nodraw-originals").glob("*/.image-attempt.md"))
    database.update_job_failed.assert_awaited_once()


@pytest.mark.asyncio
async def test_direct_image_sidecar_collision_returns_exact_manifest(tmp_path):
    import main
    from PIL import Image
    from main import ImageArchiveRequest, ImageMetadata

    image_buffer = BytesIO()
    Image.new("RGB", (2, 2), color="blue").save(image_buffer, format="PNG")

    class Response:
        content = image_buffer.getvalue()
        headers = {"content-type": "image/png"}

        def raise_for_status(self):
            return None

    class Client:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def get(self, *args, **kwargs):
            return Response()

    existing_sidecar = tmp_path / "capture.md"
    existing_sidecar.write_text("pre-existing")
    archive_storage = MagicMock()
    archive_storage.get_dated_path.return_value = tmp_path
    archive_storage.generate_base_name.return_value = "capture"
    archive_downloader = MagicMock()
    archive_downloader.get_handler.return_value = None

    with (
        patch.object(main, "storage", archive_storage),
        patch.object(main, "downloader", archive_downloader),
        patch("httpx.AsyncClient", Client),
    ):
        result = await main._archive_image_impl(ImageArchiveRequest(
            image_url="https://example.com/image.png",
            metadata=ImageMetadata(title="Image"),
        ))

    assert result["success"] is True
    assert existing_sidecar.read_text() == "pre-existing"
    published = {Path(path) for path in result["published_paths"]}
    assert tmp_path / "capture.png" in published
    assert tmp_path / "capture-2.md" in published
    assert (tmp_path / "capture-2.md").is_file()
    assert result["sidecar_path"] == str(tmp_path / "capture-2.md")


@pytest.mark.asyncio
async def test_flickr_fallback_rejects_invalid_bytes_before_publication(tmp_path):
    import main
    from downloaders.base import DownloadFailureKind, DownloadResult
    from main import ImageArchiveRequest, ImageMetadata

    class InvalidResponse:
        status_code = 200
        content = b"not an image"
        headers = {"content-type": "image/jpeg"}
        text = ""

    class Client:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return False

        async def get(self, *args, **kwargs):
            return InvalidResponse()

    handler = MagicMock()
    handler.name = "gallery-dl"
    handler.download = AsyncMock(return_value=DownloadResult(
        file_path=None,
        metadata={},
        success=False,
        error="no gallery result",
        failure_kind=DownloadFailureKind.NO_MEDIA,
    ))
    archive_storage = MagicMock()
    archive_storage.get_dated_path.return_value = tmp_path
    archive_storage.generate_base_name.return_value = "flickr-capture"
    archive_downloader = MagicMock()
    archive_downloader.get_handler.return_value = handler

    with (
        patch.object(main, "storage", archive_storage),
        patch.object(main, "downloader", archive_downloader),
        patch("httpx.AsyncClient", Client),
    ):
        result = await main._archive_image_impl(ImageArchiveRequest(
            image_url="https://live.staticflickr.com/1/123_secret_b.jpg",
            page_url="https://www.flickr.com/photos/user/123",
            metadata=ImageMetadata(platform="flickr", title="Image"),
        ))

    handler.download.assert_awaited_once()
    assert result["success"] is False
    assert not list(tmp_path.glob("*.jpg"))


class TestJobsEndpoint:
    """Tests for /jobs endpoints"""

    def test_jobs_list(self, client):
        """Jobs endpoint returns list"""
        with patch('main.db') as mock_db:
            mock_db.get_jobs = AsyncMock(return_value=[
                {
                    "id": 1,
                    "url": "https://twitter.com/test",
                    "status": "completed",
                    "created_at": "2024-01-01T12:00:00",
                    "file_path": "/path/to/file.mp4"
                }
            ])

            response = client.get("/jobs")

            assert response.status_code == 200
            data = response.json()
            # API wraps jobs in object
            assert "jobs" in data or isinstance(data, list)

    def test_jobs_with_limit(self, client):
        """Jobs endpoint respects limit parameter"""
        with patch('main.db') as mock_db:
            mock_db.get_jobs = AsyncMock(return_value=[])

            response = client.get("/jobs?limit=5")

            assert response.status_code == 200
            mock_db.get_jobs.assert_called_once()

    def test_job_by_id(self, client):
        """Single job endpoint returns job details"""
        with patch('main.db') as mock_db:
            mock_db.get_job = AsyncMock(return_value={
                "id": 1,
                "url": "https://twitter.com/test",
                "status": "completed"
            })

            response = client.get("/jobs/1")

            assert response.status_code == 200
            data = response.json()
            assert data["id"] == 1

    def test_job_responses_leave_out_the_stored_capture_request(self, client):
        """The stored intent carries the page screenshot; job reads must not ship it"""
        job = {"id": "j1", "status": "processing", "intent": {"options": {"screenshot": "data:image/png;base64," + "A" * 1000}}}
        with patch('main.db') as mock_db:
            mock_db.get_jobs = AsyncMock(return_value=[dict(job)])
            mock_db.get_job = AsyncMock(return_value=dict(job))

            listed = client.get("/jobs").json()["jobs"][0]
            single = client.get("/jobs/j1").json()

            assert "intent" not in listed and "intent" not in single
            assert listed["status"] == single["status"] == "processing"

    def test_job_not_found(self, client):
        """Missing job returns 404"""
        with patch('main.db') as mock_db:
            mock_db.get_job = AsyncMock(return_value=None)

            response = client.get("/jobs/99999")

            assert response.status_code == 404


class TestSearchEndpoint:
    """Tests for /search endpoint"""

    def test_search_requires_query(self, client):
        """Search requires q parameter"""
        response = client.get("/search")

        assert response.status_code == 422

    def test_search_returns_results(self, client):
        """Search returns matching results"""
        with patch('main.db') as mock_db:
            mock_db.search = AsyncMock(return_value=[
                {"id": 1, "title": "Test Video", "url": "https://example.com"}
            ])

            response = client.get("/search?q=test")

            assert response.status_code == 200
            data = response.json()
            # API may wrap results in object
            assert "results" in data or isinstance(data, list)


class TestStatsEndpoint:
    """Tests for /stats endpoint"""

    def test_stats_returns_counts(self, client):
        """Stats endpoint returns archive statistics"""
        with patch('main.db') as mock_db:
            mock_db.get_stats = AsyncMock(return_value={
                "total": 100,
                "today": 5,
                "this_week": 20,
                "by_type": {"video": 50, "images": 50}
            })

            response = client.get("/stats")

            assert response.status_code == 200
            data = response.json()
            assert "total" in data


class TestDashboardEndpoint:
    """Tests for /dashboard endpoint"""

    def test_dashboard_returns_html(self, client):
        """Dashboard returns HTML page"""
        with patch('main.db') as mock_db, \
             patch('main.storage') as mock_storage:
            mock_db.get_stats = AsyncMock(return_value={
                "total": 0, "today": 0, "this_week": 0, "by_type": {}
            })
            mock_db.get_jobs = AsyncMock(return_value=[])
            mock_storage.get_storage_stats.return_value = {
                "total_size": 0, "file_count": 0, "months": {}
            }

            response = client.get("/dashboard")

            assert response.status_code == 200
            assert "text/html" in response.headers["content-type"]
