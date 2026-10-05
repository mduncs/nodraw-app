"""
Platform-specific metadata extraction from gallery-dl JSON and URL patterns.

Two approaches:
1. Parse gallery-dl's --write-metadata JSON files for rich fields
2. URL-based fallback that extracts context from known URL patterns
"""

import json
import re
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import urlparse
from platforms import matches_domains, url_hostname
import logging

logger = logging.getLogger(__name__)


# --- gallery-dl JSON metadata extraction ---

# Maps gallery-dl extractor names to field extraction rules.
# Each rule: (gallery_dl_field, sidecar_field, optional_nested_path)
PLATFORM_FIELD_MAP: Dict[str, List[tuple]] = {
    'reddit': [
        ('subreddit', 'subreddit', None),
        ('author', 'author', None),
        ('title', 'title', None),
        ('score', 'score', None),
    ],
    'pinterest': [
        ('board.name', 'board_name', None),
        ('board', 'board_name', None),  # fallback flat field
        ('pinner.username', 'author', None),
    ],
    'tumblr': [
        ('blog_name', 'blog_name', None),
        ('blog', 'blog_name', None),
    ],
    'deviantart': [
        ('category_path', 'gallery_name', None),
        ('category', 'gallery_name', None),
        ('author.username', 'author', None),
        ('username', 'author', None),
    ],
    'pixiv': [
        ('user.name', 'artist_name', None),
        ('user_name', 'artist_name', None),
        ('user.account', 'artist_id', None),
        ('tag_string', 'source_tags', 'split_space'),
    ],
    'artstation': [
        ('username', 'artist_name', None),
        ('user.username', 'artist_name', None),
        ('user.full_name', 'artist_display_name', None),
    ],
    'flickr': [
        ('group_name', 'group_name', None),
        ('pool_name', 'group_name', None),
        ('album_title', 'album_title', None),
        ('owner.username', 'author', None),
        ('username', 'author', None),
    ],
    'danbooru': [
        ('tag_string_artist', 'artist_name', 'split_space'),
        ('tag_string_character', 'characters', 'split_space'),
        ('tag_string_copyright', 'source_series', 'split_space'),
        ('tag_string_general', 'source_tags', 'split_space'),
        ('rating', 'rating', None),
    ],
    'gelbooru': [
        ('tags', 'source_tags', 'split_space'),
        ('source', 'original_source', None),
        ('rating', 'rating', None),
    ],
}


def _resolve_nested(data: dict, dotted_key: str):
    """Resolve a dotted key like 'user.name' from a nested dict."""
    parts = dotted_key.split('.')
    current = data
    for part in parts:
        if isinstance(current, dict):
            current = current.get(part)
        else:
            return None
        if current is None:
            return None
    return current


def extract_from_gallery_dl_json(json_data: dict, platform: str) -> Dict:
    """
    Extract platform-specific metadata from a gallery-dl metadata JSON blob.

    Args:
        json_data: Parsed JSON from gallery-dl's --write-metadata output
        platform: Platform name (reddit, pinterest, etc.)

    Returns:
        Dict of sidecar-ready fields (only non-empty values)
    """
    result = {}
    rules = PLATFORM_FIELD_MAP.get(platform, [])

    for gdl_field, sidecar_field, transform in rules:
        # Skip if we already have this sidecar field
        if sidecar_field in result and result[sidecar_field]:
            continue

        value = _resolve_nested(json_data, gdl_field)
        if value is None:
            continue

        # Apply transforms
        if transform == 'split_space' and isinstance(value, str):
            value = [t.strip() for t in value.split() if t.strip()]
        elif transform == 'split_space' and isinstance(value, list):
            pass  # already a list

        if value:
            result[sidecar_field] = value

    # Extract tags/hashtags generically (many platforms have these)
    for tag_field in ('tags', 'hashtags', 'tag_list'):
        tags = json_data.get(tag_field)
        if tags and 'source_tags' not in result:
            if isinstance(tags, str):
                result['source_tags'] = [t.strip() for t in tags.split() if t.strip()]
            elif isinstance(tags, list):
                # Tags can be strings or dicts with 'name' key
                parsed = []
                for t in tags:
                    if isinstance(t, str):
                        parsed.append(t)
                    elif isinstance(t, dict) and 'name' in t:
                        parsed.append(t['name'])
                if parsed:
                    result['source_tags'] = parsed

    # Generic author fallback
    if 'author' not in result:
        for author_field in ('author', 'user', 'uploader', 'creator', 'owner'):
            val = json_data.get(author_field)
            if isinstance(val, str) and val:
                result['author'] = val
                break
            elif isinstance(val, dict):
                for name_key in ('name', 'username', 'display_name', 'screen_name'):
                    name = val.get(name_key)
                    if name:
                        result['author'] = name
                        break

    # Generic title fallback
    if 'title' not in result:
        title = json_data.get('title') or json_data.get('description', '')
        if isinstance(title, str) and title:
            result['title'] = title[:500]  # cap length

    return result


def parse_gallery_dl_metadata_files(
    output_dir: Path,
    platform: str,
    cleanup: bool = True
) -> Dict:
    """
    Find and parse gallery-dl metadata JSON files in output_dir.

    gallery-dl writes .json files alongside each downloaded media file
    when --write-metadata is enabled. We parse the first one found
    (they usually share the same source context fields).

    Args:
        output_dir: Directory containing downloaded files
        platform: Platform name for field extraction
        cleanup: Whether to delete .json files after parsing

    Returns:
        Dict of extracted metadata fields
    """
    combined = {}
    json_files = list(output_dir.glob('*.json'))

    if not json_files:
        logger.debug(f"No gallery-dl metadata JSON files found in {output_dir}")
        return combined

    logger.info(f"Found {len(json_files)} gallery-dl metadata JSON files")

    for json_file in json_files:
        # Skip our own config files
        if json_file.name.startswith('.'):
            continue

        try:
            data = json.loads(json_file.read_text(encoding='utf-8'))
            extracted = extract_from_gallery_dl_json(data, platform)

            # Merge: first file's values win for scalar fields,
            # lists get extended (for source_tags)
            for key, value in extracted.items():
                if key not in combined:
                    combined[key] = value
                elif isinstance(value, list) and isinstance(combined[key], list):
                    # Extend tags, deduplicate
                    existing = set(combined[key])
                    for item in value:
                        if item not in existing:
                            combined[key].append(item)
                            existing.add(item)

            logger.debug(f"Extracted from {json_file.name}: {list(extracted.keys())}")

        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            logger.warning(f"Failed to parse gallery-dl JSON {json_file.name}: {e}")
        except Exception as e:
            logger.warning(f"Error reading {json_file.name}: {e}")

    # Cleanup JSON files
    if cleanup:
        for json_file in json_files:
            if json_file.name.startswith('.'):
                continue
            try:
                json_file.unlink()
                logger.debug(f"Cleaned up metadata file: {json_file.name}")
            except OSError as e:
                logger.warning(f"Failed to delete {json_file.name}: {e}")

    if combined:
        logger.info(f"Extracted gallery-dl metadata: {list(combined.keys())}")

    return combined


# --- URL-based fallback extraction ---

def extract_source_context(url: str, platform: str) -> Dict:
    """
    Extract source context from URL patterns as a fallback when
    gallery-dl metadata is unavailable.

    Args:
        url: The source URL
        platform: Detected platform name

    Returns:
        Dict of extracted fields (only non-empty)
    """
    result = {}
    parsed = urlparse(url)
    path = parsed.path.rstrip('/')

    try:
        if platform == 'reddit':
            # /r/{subreddit}/comments/{id}/...
            match = re.search(r'/r/([^/]+)', path)
            if match:
                result['subreddit'] = match.group(1)

            # /user/{username}/...
            match = re.search(r'/user/([^/]+)', path)
            if match:
                result['author'] = f"u/{match.group(1)}"

        elif platform == 'pinterest':
            # /{user}/{board}/... or /pin/{id}
            parts = [p for p in path.split('/') if p]
            if len(parts) >= 2 and parts[0] != 'pin':
                result['author'] = parts[0]
                result['board_name'] = parts[1]

        elif platform == 'tumblr':
            # {blog}.tumblr.com/post/{id}/...
            hostname = url_hostname(url)
            if hostname != 'tumblr.com' and matches_domains(url, ('tumblr.com',)):
                blog = hostname.replace('.tumblr.com', '').replace('www.', '')
                if blog and blog != 'www':
                    result['blog_name'] = blog

        elif platform == 'youtube':
            # /channel/{id} or /@{handle} or /c/{name}
            match = re.search(r'/@([^/]+)', path)
            if match:
                result['channel_name'] = match.group(1)

            match = re.search(r'/channel/([^/]+)', path)
            if match:
                result['channel_id'] = match.group(1)

            match = re.search(r'/c/([^/]+)', path)
            if match:
                result['channel_name'] = match.group(1)

        elif platform == 'deviantart':
            # {username}.deviantart.com/... or deviantart.com/{username}/...
            hostname = url_hostname(url)
            if hostname != 'deviantart.com' and matches_domains(url, ('deviantart.com',)):
                # Subdomain style: coolart.deviantart.com
                username = hostname.replace('.deviantart.com', '')
                if username:
                    result['author'] = username
            else:
                # New URL format: deviantart.com/{username}/art/...
                parts = [p for p in path.split('/') if p]
                if parts and parts[0] not in ('art', 'tag', 'search', 'about'):
                    result['author'] = parts[0]

        elif platform == 'pixiv':
            # /users/{id} or /artworks/{id}
            match = re.search(r'/users/(\d+)', path)
            if match:
                result['artist_id'] = match.group(1)

        elif platform == 'artstation':
            # artstation.com/{username} or artstation.com/artwork/{id}
            parts = [p for p in path.split('/') if p]
            if parts and parts[0] != 'artwork':
                result['artist_name'] = parts[0]

        elif platform == 'flickr':
            # /photos/{user_id}/albums/{album_id}
            # /groups/{group_id}/pool/
            match = re.search(r'/photos/([^/]+)', path)
            if match:
                result['author'] = match.group(1)

            match = re.search(r'/albums/(\d+)', path)
            if match:
                result['album_id'] = match.group(1)

            match = re.search(r'/groups/([^/]+)', path)
            if match:
                result['group_name'] = match.group(1)

    except Exception as e:
        logger.warning(f"URL context extraction failed for {url}: {e}")

    if result:
        logger.debug(f"URL context for {platform}: {result}")

    return result
