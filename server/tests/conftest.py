"""
Pytest fixtures for url-saver server tests
"""
import pytest
import tempfile
import shutil
import os
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

# Keep tests away from the user's production archive unless explicitly set.
_DEFAULT_ARCHIVE_DIR = None
if "MEDIA_ARCHIVER_DIR" not in os.environ:
    _DEFAULT_ARCHIVE_DIR = tempfile.mkdtemp(prefix="nodraw_pytest_archive_")
    os.environ["MEDIA_ARCHIVER_DIR"] = _DEFAULT_ARCHIVE_DIR
os.environ.setdefault("MEDIA_ARCHIVER_PORT", "8847")

# Add server to path
import sys
sys.path.insert(0, str(Path(__file__).parent.parent))

from storage import StorageManager


@pytest.fixture
def temp_storage_dir():
    """Create temporary storage directory for tests"""
    temp_dir = tempfile.mkdtemp(prefix="urlsaver_test_")
    yield Path(temp_dir)
    shutil.rmtree(temp_dir, ignore_errors=True)


@pytest.fixture
def storage_manager(temp_storage_dir):
    """StorageManager with temp directory"""
    return StorageManager(temp_storage_dir)


@pytest.fixture
def sample_cookies():
    """Sample cookie dict for testing"""
    return {
        "auth_token": "abc123xyz",
        "ct0": "csrf_token_value",
        "guest_id": "v1%3A123456789"
    }


@pytest.fixture
def sample_tweet_url():
    return "https://twitter.com/user/status/1234567890"


@pytest.fixture
def sample_youtube_url():
    return "https://www.youtube.com/watch?v=dQw4w9WgXcQ"


@pytest.fixture
def sample_flickr_url():
    return "https://www.flickr.com/photos/user/12345678901"


@pytest.fixture
def sample_google_arts_url():
    return "https://artsandculture.google.com/asset/the-starry-night/bgEuwDxel93-Pg"


@pytest.fixture
def sample_iiif_url():
    return "https://example.org/iiif/image/12345/info.json"


@pytest.fixture
def mock_httpx_client():
    """Mock httpx client for testing without network"""
    client = AsyncMock()
    response = MagicMock()
    response.status_code = 200
    response.content = b"fake image data"
    response.headers = {"content-type": "image/jpeg"}
    client.get.return_value = response
    return client


# Test data for various platforms
PLATFORM_URL_CASES = [
    ("https://twitter.com/user/status/123", "twitter"),
    ("https://x.com/user/status/123", "twitter"),
    ("https://www.youtube.com/watch?v=abc", "youtube"),
    ("https://youtu.be/abc", "youtube"),
    ("https://www.instagram.com/p/abc/", "instagram"),
    ("https://www.tiktok.com/@user/video/123", "tiktok"),
    ("https://vimeo.com/123456", "vimeo"),
    ("https://www.twitch.tv/user", "twitch"),
    ("https://www.reddit.com/r/sub/comments/abc/title/", "reddit"),
    ("https://www.flickr.com/photos/user/123", "flickr"),
    ("https://www.pixiv.net/artworks/12345", "pixiv"),
    ("https://www.artstation.com/artwork/abc", "artstation"),
    ("https://www.deviantart.com/user/art/title-123", "deviantart"),
    ("https://unknown-site.com/page", "unknown-site"),
]


@pytest.fixture(params=PLATFORM_URL_CASES)
def platform_url_case(request):
    """Parametrized fixture for platform detection tests"""
    return request.param


def pytest_sessionfinish(session, exitstatus):
    if _DEFAULT_ARCHIVE_DIR:
        shutil.rmtree(_DEFAULT_ARCHIVE_DIR, ignore_errors=True)
