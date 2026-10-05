"""Archive-label compatibility and hostname/path classification regressions."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from downloaders import DownloadManager
from downloaders.base import DownloadFailureKind, DownloadResult
from downloaders.dezoomify_handler import DezoomifyHandler
from downloaders.gallery_handler import GalleryDlHandler
from downloaders.ytdlp_handler import YtDlpHandler
from platforms import YOUTUBE_DOMAINS, matches_domains, url_hostname
from storage import StorageManager, detect_platform


# Aliases that previously used the unknown-host fallback keep their archive
# labels. Routing may recognize an alias without renaming existing captures.
PLATFORM_URLS = [
    ('https://x.com/user/status/123', 'twitter'),
    ('https://twitter.com/user/status/123', 'twitter'),
    ('https://mobile.twitter.com/user/status/123', 'twitter'),
    ('https://m.twitter.com/user/status/123', 'twitter'),
    ('https://www.twitter.com/user/status/123', 'twitter'),
    ('https://t.co/abc?source=x.com', 't'),
    ('https://www.youtube.com/watch?v=abc', 'youtube'),
    ('https://youtu.be/abc', 'youtube'),
    ('https://music.youtube.com/watch?v=abc', 'youtube'),
    ('https://m.youtube.com/shorts/abc', 'youtube'),
    ('https://www.youtube-nocookie.com/embed/abc', 'youtube-nocookie'),
    ('https://old.reddit.com/r/python/comments/abc/title', 'reddit'),
    ('https://new.reddit.com/r/python/comments/abc/title', 'reddit'),
    ('https://i.redd.it/abc.jpg', 'redd'),
    ('https://v.redd.it/abc', 'redd'),
    ('https://bsky.app/profile/user/post/abc', 'bluesky'),
    ('https://cdn.bsky.app/img/feed_fullsize/plain/abc.jpg', 'bluesky'),
    ('https://www.flickr.com/photos/user/123', 'flickr'),
    ('https://live.staticflickr.com/123/abc.jpg', 'flickr'),
    ('https://www.pixiv.net/artworks/123', 'pixiv'),
    ('https://www.instagram.com/p/abc/', 'instagram'),
    ('https://www.pinterest.com/pin/123/', 'pinterest'),
    ('https://www.pinterest.co.uk/pin/123/', 'co'),
    ('https://www.pinterest.de/pin/123/', 'pinterest'),
    ('https://www.pinterest.com.au/pin/123/', 'pinterest'),
    ('https://pinterest.com.mx/pin/123/', 'pinterest'),
    ('https://artist.tumblr.com/post/123/title', 'tumblr'),
    ('https://artsandculture.google.com/asset/title/abc', 'googlearts'),
    ('https://www.tiktok.com/@user/video/123', 'tiktok'),
    ('https://vimeo.com/123', 'vimeo'),
    ('https://www.twitch.tv/user', 'twitch'),
    ('https://www.facebook.com/watch/?v=123', 'facebook'),
    ('https://www.dailymotion.com/video/abc', 'dailymotion'),
    ('https://soundcloud.com/user/track', 'soundcloud'),
    ('https://artist.bandcamp.com/album/title', 'bandcamp'),
    ('https://www.artstation.com/artwork/abc', 'artstation'),
    ('https://artist.deviantart.com/art/title-123', 'deviantart'),
    ('https://netflix.com/watch/123', 'netflix'),
    ('https://dropbox.com/s/abc/file.mp4', 'dropbox'),
    ('https://notx.com/user/status/123', 'notx'),
    ('https://x.com.evil.example/user/status/123', 'evil'),
    ('https://twitter.com.evil.example/user/status/123', 'evil'),
    ('https://youtube.com.evil.example/watch?v=abc', 'evil'),
    ('https://flickr.com.evil.example/photos/user/123', 'evil'),
    ('https://example.co.uk/page', 'co'),
    ('https://127.0.0.1:8000/page', '0'),
    ('https://192.168.1.42/page', '1'),
    ('https://[::1]:8000/page', 'unknown'),
    ('https://X.COM:443/user/status/123', 'twitter'),
    ('https://MOBILE.TWITTER.COM/user/status/123', 'twitter'),
    ('https://user:password@www.youtube.com:443/watch?v=abc', 'youtube'),
    ('https://x.com@dropbox.com/s/abc/file.mp4', 'dropbox'),
    ('https://twitter.com@example.org/page', 'example'),
    ('https://user:pass@EXAMPLE.com:8443/page', 'example'),
    ('https://example.com/path/x.com?url=twitter.com', 'example'),
    ('https://example.com./page', 'example'),
    ('https://unknown-site.com/page', 'unknown-site'),
    ('https://localhost:8000/page', 'unknown'),
    ('not a url', 'unknown'),
    ('', 'unknown'),
]


@pytest.mark.parametrize(('url', 'expected'), PLATFORM_URLS)
def test_archive_platform_labels(url, expected):
    assert detect_platform(url) == expected


@pytest.mark.parametrize('url', [
    'https://netflix.com/watch/123',
    'https://dropbox.com/s/abc/file.mp4',
    'https://notx.com/status/123',
    'https://x.com.evil.example/status/123',
    'https://example.com/path/x.com',
    'https://x.com@example.org/watch',
    'https://example.org/watch?url=https://flickr.com/photos/user/123',
    'https://flickr.com.evil.example/photos/alice/123',
    'https://notpixiv.net/artworks/123',
    'https://example.org/watch?redirect=/gallery/123#fallback=/iiif/info.json',
    'https://artsandculture.google.com.evil.example/asset/title/123',
    'https://example.org/watch?url=https://artsandculture.google.com/asset/123',
])
def test_handlers_do_not_claim_hostname_or_query_lookalikes(url):
    gallery = GalleryDlHandler()
    dezoomify = DezoomifyHandler()
    dezoomify.dezoomify_path = 'dezoomify-rs'
    assert not gallery.can_handle(url)
    assert not dezoomify.can_handle(url)
    assert YtDlpHandler().can_handle(url)
    assert not matches_domains(url, YOUTUBE_DOMAINS)


@pytest.mark.parametrize('url', [
    'https://www.flickr.com:443/photos/user/123',
    'https://user:pass@M.PIXIV.NET/artworks/123',
    'https://artist.tumblr.com/post/123',
    'https://live.staticflickr.com/123/abc.jpg',
])
def test_gallery_exclusions_use_hostname(url):
    assert GalleryDlHandler().can_handle(url)
    assert not YtDlpHandler().can_handle(url)


def test_cookie_and_metadata_hosts_exclude_credentials_and_ports(tmp_path):
    from downloaders.metadata_extract import extract_source_context

    url = 'https://user:pass@artist.tumblr.com:443/post/123'
    assert url_hostname(url) == 'artist.tumblr.com'
    assert extract_source_context(url, 'tumblr')['blog_name'] == 'artist'
    cookie_path = tmp_path / 'cookies.txt'
    YtDlpHandler()._write_netscape_cookies(cookie_path, {'session': 'value'}, url)
    assert '.artist.tumblr.com\t' in cookie_path.read_text()
    assert 'user:pass@' not in cookie_path.read_text()


def test_path_markers_are_not_read_from_query_or_fragment():
    from main import extract_content_id

    url = 'https://example.org/page?redirect=/status/123#/comments/abc'
    assert extract_content_id(url) is None
    assert GalleryDlHandler()._extract_twitter_status_id(url) is None
    assert DezoomifyHandler()._detect_format(url + '/info.json') == 'unknown'
    assert extract_content_id('https://www.youtube.com/watch?feature=share&v=abc') == 'abc'
    assert extract_content_id('https://youtu.be/abc?t=3') == 'abc'
    assert extract_content_id('https://youtube.com.evil.example/watch?v=abc') is None


@pytest.mark.asyncio
async def test_gallery_unsupported_url_has_distinct_disposition(tmp_path):
    async def stderr():
        yield b'[gallery-dl][error] Unsupported URL https://example.org/gallery/123\n'
        yield b'[gallery-dl][info] exiting\n'

    process = MagicMock(returncode=64)
    process.stderr = stderr()
    process.wait = AsyncMock()
    handler = GalleryDlHandler()
    with (
        patch.object(handler, '_gallery_dl_command', return_value=['gallery-dl']),
        patch('downloaders.gallery_handler.asyncio.create_subprocess_exec',
              AsyncMock(return_value=process)),
    ):
        result = await handler.download('https://example.org/gallery/123', {}, tmp_path)
    assert result.failure_kind == DownloadFailureKind.UNSUPPORTED
    assert result.is_terminal_failure  # Remains failed until a fallback succeeds.
    assert not result.is_no_media
    assert not result.published_paths


@pytest.mark.parametrize(('url', 'kind', 'allowed'), [
    ('https://netflix.com/gallery/123', DownloadFailureKind.UNSUPPORTED, True),
    ('https://dropbox.com/gallery/123', DownloadFailureKind.UNSUPPORTED, True),
    ('https://www.flickr.com/photos/user/123', DownloadFailureKind.UNSUPPORTED, False),
    ('https://example.org/gallery/123', DownloadFailureKind.TERMINAL, False),
    ('https://example.org/gallery/123', DownloadFailureKind.NO_MEDIA, False),
])
def test_fallback_respects_disposition_and_handler_exclusions(url, kind, allowed):
    manager = DownloadManager()
    gallery = next(h for h in manager.handlers if h.name == 'gallery-dl')
    result = DownloadResult(None, {}, success=False, failure_kind=kind)
    fallback = manager.get_fallback_handler(gallery, url, result)
    assert bool(fallback) == allowed
    if allowed:
        assert fallback.name == 'yt-dlp'


@pytest.mark.asyncio
@pytest.mark.parametrize('fallback_success', [True, False])
async def test_gallery_to_ytdlp_fallthrough_in_process_download(tmp_path, fallback_success):
    import main

    media = tmp_path / 'video.mp4'
    media.write_bytes(b'published test media')
    gallery = MagicMock()
    gallery.name = 'gallery-dl'
    gallery.can_handle.return_value = True
    gallery.download = AsyncMock(return_value=DownloadResult(
        None, {}, success=False, error='Unsupported URL',
        failure_kind=DownloadFailureKind.UNSUPPORTED,
    ))
    ytdlp = MagicMock()
    ytdlp.name = 'yt-dlp'
    ytdlp.can_handle.return_value = True
    ytdlp.download = AsyncMock(return_value=(
        DownloadResult(media, {'title': 'Video'}, published_paths=(media,))
        if fallback_success else DownloadResult(
            None, {}, success=False, error='yt-dlp extraction failed',
            failure_kind=DownloadFailureKind.TERMINAL,
        )
    ))
    manager = DownloadManager()
    manager.handlers = [gallery, ytdlp]
    database = MagicMock()
    database.update_job_status = AsyncMock()
    database.update_job_complete = AsyncMock()
    database.update_job_failed = AsyncMock()
    with (
        patch.object(main, 'db', database),
        patch.object(main, 'storage', StorageManager(tmp_path)),
        patch.object(main, 'downloader', manager),
        patch.object(main, 'append_to_index'),
    ):
        await main.process_download(
            job_id='unsupported-gallery', url='https://netflix.com/gallery/123',
            cookies=[], options={}, save_mode='quick',
        )
    gallery.download.assert_awaited_once()
    ytdlp.download.assert_awaited_once_with(**gallery.download.call_args.kwargs)
    if fallback_success:
        database.update_job_failed.assert_not_awaited()
        database.update_job_complete.assert_awaited_once()
        assert database.update_job_complete.call_args.kwargs['metadata']['downloader'] == 'yt-dlp'
    else:
        database.update_job_complete.assert_not_awaited()
        database.update_job_failed.assert_awaited_once_with(
            'unsupported-gallery', 'yt-dlp extraction failed', 'server_error',
        )
