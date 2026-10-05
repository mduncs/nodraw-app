"""Every sidecar header the server writes reads back as exactly what was written."""
from datetime import date, datetime, timezone
from io import BytesIO
from pathlib import Path
import random
import struct
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from downloaders.base import DownloadResult
from sidecar_projection import parse_sidecar, project
from sidecar_writer import DateText, render_sidecar, yaml_value


# Values that broke, or could break, a hand-built header.
AWKWARD = [
    'Sāmple "Quoted" Name',
    "/J\\",
    "C:\\Users\\example",
    '12" vinyl',
    "¯\\_(ツ)_/¯",
    "line one\nline two\n\nline four",
    "tab\there",
    "emoji 🌙 and 🧛\u200d♀️ zwj",
    "sep\u2028arator\u2029s and \x85 next-line",
    "del\x7f and bell\x07 and nul\x00",
    "\ufeffbom",
    "yes", "no", "on", "null", "~", "true", "1e3", "0x1f", "2026-10-03",
    "- dash", ": colon", "#hash", "@at", "`tick", "{brace}", "[bracket]", "&anchor", "*alias", "!tag", "%pct", "|pipe", ">fold",
    "  padded  ",
    "trailing colon:",
    "key: value",
    "---",
    "...",
]


def header_of(content: bytes) -> dict:
    return parse_sidecar(content.decode("utf-8"))[3]


@pytest.mark.parametrize("value", AWKWARD)
def test_awkward_text_reads_back_unchanged(value):
    content = render_sidecar({"source": "https://example.com/a", "author": value, "title": value, "notes": value, "tags": [value, "plain"]}, ["", "body"])
    header = header_of(content)
    assert header["author"] == value
    assert header["title"] == value
    assert header["notes"] == value
    assert header["tags"] == [value, "plain"]


def test_random_unicode_reads_back_unchanged():
    generator = random.Random(20261003)
    alphabet = [chr(code) for code in [*range(0x00, 0x250), *range(0x2000, 0x2070), 0xFEFF, 0xFFFD, *range(0x1F300, 0x1F320)]]
    for _ in range(500):
        value = "".join(generator.choice(alphabet) for _ in range(generator.randint(1, 40)))
        assert header_of(render_sidecar({"source": "https://example.com", "title": value}))["title"] == value


def test_lone_surrogate_becomes_a_replacement_character():
    content = render_sidecar({"source": "https://example.com", "author": "half \ud83d emoji"}, ["", "body \ud83d"])
    assert header_of(content)["author"] == "half \ufffd emoji"
    assert content.decode("utf-8").endswith("body \ufffd")


def test_emoji_stay_readable_in_the_file():
    assert "🌙" in render_sidecar({"source": "https://example.com", "author": "moon 🌙"}).decode("utf-8")


def test_dates_are_timestamps_and_other_text_stays_text():
    now = datetime(2026, 10, 3, 1, 24, 41, 123456)
    header = header_of(render_sidecar({
        "source": "https://example.com",
        "archived": now,
        "tweet_date": DateText("2026-03-24T12:35:03.000Z"),
        "upload_date": DateText("2024-01-02"),
        "date_taken": DateText("2024:01:02 10:00:00"),
        "post_date": DateText("yesterday"),
    }))
    # Local wall time is written with its offset, so it reads back as the same instant.
    assert header["archived"] == now.astimezone()
    assert header["archived"].tzinfo is not None
    assert isinstance(header["tweet_date"], datetime)
    assert header["upload_date"] == date(2024, 1, 2)
    assert header["date_taken"] == "2024:01:02 10:00:00"
    assert header["post_date"] == "yesterday"


def test_layout_and_types_match_the_old_writers():
    content = render_sidecar({
        "source": "https://x.com/a/status/1",
        "platform": "twitter",
        "author": "a",
        "tweet_id": 1000000000000000013,
        "archived": datetime(2026, 10, 3, 1, 0, 0, 1, tzinfo=timezone.utc),
        "fallback": True,
        "fallback_reason": "no_media_found",
        "media_count": 0,
        "title": "",
        "notes": None,
        "tags": [],
    }, ["", "![[a.jpg]]", ""]).decode("utf-8")
    assert content == (
        '---\nsource: "https://x.com/a/status/1"\nplatform: twitter\nauthor: "a"\ntweet_id: 1000000000000000013\n'
        "archived: 2026-10-03T01:00:00.000001+00:00\nfallback: true\nfallback_reason: no_media_found\nmedia_count: 0\n"
        "---\n\n![[a.jpg]]\n"
    )


def test_bare_fields_are_quoted_when_yaml_would_misread_them():
    assert yaml_value("twitter", bare=True) == "twitter"
    assert yaml_value("yes", bare=True) == '"yes"'
    assert yaml_value("Twitter", bare=True) == '"Twitter"'
    assert yaml_value("twitter") == '"twitter"'


def test_field_names_are_checked():
    with pytest.raises(ValueError):
        render_sidecar({"source": "https://example.com", "bad key": "x"})


def test_tag_and_note_edits_use_the_same_quoting(tmp_path):
    sidecar = tmp_path / "item.md"
    sidecar.write_bytes(render_sidecar({"source": "https://example.com", "tags": ["old"]}, ["", "body", ""]))
    project(sidecar, {"tags": ['a "b"', "c\\"], "notes": "two\nlines \u2028"}, {"tags": [["old"]], "notes": [""]})
    header = header_of(sidecar.read_bytes())
    assert header["tags"] == ['a "b"', "c\\"]
    assert header["notes"] == "two\nlines \u2028"


# The writers themselves, with the awkward author/title/note that broke real sidecars.
NASTY_TITLE = 'He said "hi" \\ bye'
NASTY_NOTE = 'first line\nsecond "quoted" line \\'
USER = {"user_tags": ["fav", 'with "quotes"'], "user_note": NASTY_NOTE, "capture_intent": {"captureId": "writer-capture"}}


def _capture_mocks(directory, handler_name, result):
    handler = MagicMock(name=handler_name)
    handler.name = handler_name
    handler.download = AsyncMock(return_value=result)
    database = AsyncMock()
    storage = MagicMock()
    storage.get_dated_path.return_value = directory
    storage.generate_base_name.return_value = "capture"
    manager = MagicMock()
    manager.handlers = [handler]
    manager.get_handler.return_value = handler
    return database, storage, manager


def _sidecar_header(database) -> dict:
    metadata = database.update_job_complete.await_args.kwargs["metadata"]
    return header_of(Path(metadata["sidecar_path"]).read_bytes())


@pytest.mark.asyncio
async def test_text_capture_keeps_title_tags_and_multiline_note(temp_storage_dir):
    import main

    database, storage, manager = _capture_mocks(temp_storage_dir, "yt-dlp", None)
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("text", "https://example.com/post", [], options=USER, save_mode="text", page_title=NASTY_TITLE, screenshot="data:image/png;base64,c2NyZWVuc2hvdA==")

    header = _sidecar_header(database)
    assert header["capture_id"] == "writer-capture"
    assert header["title"] == NASTY_TITLE
    assert header["tags"] == USER["user_tags"]
    assert header["notes"] == NASTY_NOTE, "line breaks in a note are kept, not flattened"


@pytest.mark.asyncio
async def test_twitter_media_capture_keeps_author_and_user_tags(temp_storage_dir):
    import main

    media = temp_storage_dir / "capture-1.jpg"
    media.write_bytes(b"media")
    result = DownloadResult(media, {"files": [str(media)]}, published_paths=(media,))
    database, storage, manager = _capture_mocks(temp_storage_dir, "gallery-dl", result)
    options = {**USER, "emotionTag": "joy", "tweetContent": {"userName": 'Sāmple "Quoted" Name\n@samplequote', "text": "post", "timestamp": "2026-03-24T12:35:03.000Z"}}
    with patch.object(main, "db", database), patch.object(main, "storage", storage), patch.object(main, "downloader", manager):
        await main.process_download("x", "https://x.com/samplequote/status/1000000000000000013", [], options=options, save_mode="quick")

    header = _sidecar_header(database)
    assert header["capture_id"] == "writer-capture"
    assert header["author"] == 'Sāmple "Quoted" Name'
    assert header["tweet_id"] == 1000000000000000013
    assert isinstance(header["tweet_date"], datetime)
    assert header["tags"] == ["joy", *USER["user_tags"]]
    assert header["notes"] == NASTY_NOTE


@pytest.mark.asyncio
async def test_other_platform_media_capture_keeps_user_tags(temp_storage_dir):
    import main
    from storage import StorageManager

    media = temp_storage_dir / "capture.mp4"
    media.write_bytes(b"media")
    result = DownloadResult(media, {"title": NASTY_TITLE, "uploader": "/J\\", "tags": ["source", "tags"]}, published_paths=(media,))
    database, _, manager = _capture_mocks(temp_storage_dir, "yt-dlp", result)
    real_storage = StorageManager(temp_storage_dir)
    real_storage.get_dated_path = MagicMock(return_value=temp_storage_dir)
    with patch.object(main, "db", database), patch.object(main, "storage", real_storage), patch.object(main, "downloader", manager):
        await main.process_download("v", "https://vimeo.com/1", [], options=USER, save_mode="quick", page_title=NASTY_TITLE)

    header = _sidecar_header(database)
    assert header["capture_id"] == "writer-capture"
    assert header["title"] == NASTY_TITLE
    assert header["tags"] == USER["user_tags"], "the user's tags, not the site's"
    assert header["notes"] == NASTY_NOTE


@pytest.mark.asyncio
@pytest.mark.parametrize("writer", ["twitter_content", "twitter_gallery", "twitter_fallback", "bluesky"])
async def test_platform_creation_writers_include_capture_id(tmp_path, writer):
    import main

    media = tmp_path / "media.jpg"
    media.write_bytes(b"media")
    content = {"text": "post", "userName": "author", "handle": "author"}
    url = "https://x.com/author/status/1"
    if writer == "twitter_content":
        path = await main.create_twitter_sidecar_from_content(tmp_path, [media], content, url, "capture", options=USER)
    elif writer == "twitter_gallery":
        path = await main.create_twitter_sidecar(tmp_path, [str(media)], content, url, options=USER)
    elif writer == "twitter_fallback":
        path = await main.create_twitter_metadata_fallback_sidecar(tmp_path, "capture", {**content, "quotedFiles": [str(media)]}, url, "quick", options=USER)
    else:
        path = await main.create_bluesky_sidecar(tmp_path, [media], content, "https://bsky.app/profile/a/post/1", "capture", options=USER)
    assert header_of(Path(path).read_bytes())["capture_id"] == "writer-capture"


@pytest.mark.asyncio
@pytest.mark.parametrize("fallback", ["yt-dlp", "screenshot"])
async def test_download_fallback_creation_includes_capture_id(tmp_path, fallback):
    import main
    from downloaders.base import DownloadFailureKind

    no_media = DownloadResult(None, {}, success=False, failure_kind=DownloadFailureKind.NO_MEDIA)
    database, storage, manager = _capture_mocks(tmp_path, "gallery-dl", no_media)
    screenshot = None
    if fallback == "yt-dlp":
        media = tmp_path / "video.mp4"
        media.write_bytes(b"media")
        handler = MagicMock()
        handler.name = "yt-dlp"
        handler.download = AsyncMock(return_value=DownloadResult(media, {}, published_paths=(media,)))
        manager.handlers.append(handler)
    else:
        # The initial handler's explicit no-media result goes directly to screenshot fallback.
        manager.handlers[0].name = "yt-dlp"
        screenshot = "data:image/png;base64,fixture"

    async def save_screenshot(_payload, path):
        path.write_bytes(b"screenshot")
        return True

    with (
        patch.object(main, "db", database),
        patch.object(main, "storage", storage),
        patch.object(main, "downloader", manager),
        patch.object(main, "decode_and_save_screenshot", AsyncMock(side_effect=save_screenshot)),
    ):
        await main.process_download("fallback", "https://www.reddit.com/r/sub/comments/abc/post/", [], options=USER, save_mode="quick", screenshot=screenshot)

    assert header_of(Path(database.update_job_complete.await_args.kwargs["metadata"]["sidecar_path"]).read_bytes())["capture_id"] == "writer-capture"


@pytest.mark.asyncio
async def test_storage_creation_keeps_capture_id_from_metadata(tmp_path):
    from storage import StorageManager

    media = tmp_path / "media.mp4"
    media.write_bytes(b"media")
    path = await StorageManager(tmp_path).save_metadata(media, {"original_url": "https://example.com/post", "capture_id": "storage-capture"})
    assert header_of(path.read_bytes())["capture_id"] == "storage-capture"


@pytest.mark.asyncio
async def test_twitter_writers_parse_with_awkward_authors(temp_storage_dir):
    import main

    content = {"userName": "/J\\", "text": "t", "timestamp": "not a date", "quotes": [], "handle": 'a "b"'}
    media = temp_storage_dir / "m.jpg"
    media.write_bytes(b"m")
    paths = [
        await main.create_twitter_sidecar_from_content(temp_storage_dir, [media], content, "https://x.com/j/status/1", "one", options=USER),
        await main.create_twitter_sidecar(temp_storage_dir, [str(media)], content, "https://x.com/j/status/2", options=USER),
        await main.create_twitter_metadata_fallback_sidecar(temp_storage_dir, "three", {**content, "quotedFiles": [str(media)]}, "https://x.com/j/status/3", "text", title=NASTY_TITLE, options=USER),
        await main.create_bluesky_sidecar(temp_storage_dir, [media], content, "https://bsky.app/profile/a/post/1", "four", options=USER),
    ]
    for path in paths:
        header = header_of(Path(path).read_bytes())
        assert header.get("author") in {"/J\\", 'a "b"'}
        assert header["tags"] == USER["user_tags"]
        assert header["notes"] == NASTY_NOTE
        assert header.get("tweet_date", "not a date") == "not a date"


@pytest.mark.asyncio
@pytest.mark.parametrize("with_capture_id", [False, True])
async def test_image_capture_keeps_description_lines(tmp_path, with_capture_id):
    import main
    from main import ImageArchiveRequest, ImageMetadata
    from PIL import Image

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

    archive_storage = MagicMock()
    archive_storage.get_dated_path.return_value = tmp_path
    archive_storage.generate_base_name.return_value = "capture"
    archive_downloader = MagicMock()
    archive_downloader.get_handler.return_value = None
    database = AsyncMock()
    with patch.object(main, "storage", archive_storage), patch.object(main, "downloader", archive_downloader), patch.object(main, "db", database), patch("httpx.AsyncClient", Client):
        request = ImageArchiveRequest(
            image_url="https://example.com/image.png",
            metadata=ImageMetadata(title=NASTY_TITLE, author="/J\\", description="one\ntwo", tags=["x", 'y "z"'], note=NASTY_NOTE, dateTaken="2024-01-02T03:04:05Z"),
        )
        if with_capture_id:
            from capture_service import CaptureIntent
            intent = CaptureIntent(
                captureId="image-capture", fingerprint="v1-image", kind="media",
                targetUrl=request.image_url, sourcePageUrl="https://example.com/post",
                createdAt=datetime.now(timezone.utc),
                page={"title": NASTY_TITLE, "author": "/J\\", "description": "one\ntwo"},
                user={"tags": request.metadata.tags, "note": NASTY_NOTE},
                options={"siteData": {"dateTaken": "2024-01-02T03:04:05Z"}},
            )
            await main.process_image_capture("image-job", intent, [])
            result = {"sidecar_path": database.update_job_complete.await_args.args[2]["sidecar_path"]}
        else:
            result = await main._archive_image_impl(request)

    header = header_of(Path(result["sidecar_path"]).read_bytes())
    if with_capture_id:
        assert header["capture_id"] == "image-capture"
    else:
        assert "capture_id" not in header
    assert header["title"] == NASTY_TITLE
    assert header["author"] == "/J\\"
    assert header["description"] == "one\ntwo"
    assert header["tags"] == ["x", 'y "z"']
    assert header["notes"] == NASTY_NOTE
    assert isinstance(header["date_taken"], datetime)


@pytest.mark.skipif(sys.platform != "darwin", reason="Finder's Date Added is a macOS attribute")
def test_tag_edit_keeps_finder_date_added(tmp_path):
    from sidecar_projection import _added_time, _set_added_time

    sidecar = tmp_path / "item.md"
    sidecar.write_bytes(render_sidecar({"source": "https://example.com"}, ["", "body", ""]))
    added = struct.pack("=qq", 1754793149, 0)
    assert _set_added_time(sidecar, added)
    project(sidecar, {"tags": ["new"]}, {"tags": [[]]})
    assert header_of(sidecar.read_bytes())["tags"] == ["new"]
    assert _added_time(sidecar) == added


def test_archived_time_carries_the_local_offset(monkeypatch):
    import time
    monkeypatch.setenv("TZ", "America/Chicago")
    time.tzset()
    try:
        # 01:24 in Chicago; read as UTC it would land on the previous evening.
        assert yaml_value(datetime(2026, 10, 3, 1, 24, 41)) == "2026-10-03T01:24:41-05:00"
        assert yaml_value(datetime(2026, 1, 3, 1, 24, 41)) == "2026-01-03T01:24:41-06:00"
    finally:
        monkeypatch.undo()
        time.tzset()
