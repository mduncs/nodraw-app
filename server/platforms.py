"""Hostname-boundary matching shared by capture and downloader decisions."""

from collections.abc import Iterable
from urllib.parse import urlparse


# These names are archive identifiers. Keep aliases and unknown-host labels
# compatible with existing filenames and sidecars.
PLATFORM_DOMAINS = {
    'twitter.com': 'twitter',
    'x.com': 'twitter',
    'bsky.app': 'bluesky',
    'youtube.com': 'youtube',
    'youtu.be': 'youtube',
    'instagram.com': 'instagram',
    'tiktok.com': 'tiktok',
    'vimeo.com': 'vimeo',
    'twitch.tv': 'twitch',
    'reddit.com': 'reddit',
    'facebook.com': 'facebook',
    'dailymotion.com': 'dailymotion',
    'soundcloud.com': 'soundcloud',
    'bandcamp.com': 'bandcamp',
    'flickr.com': 'flickr',
    'staticflickr.com': 'flickr',
    'pixiv.net': 'pixiv',
    'artstation.com': 'artstation',
    'deviantart.com': 'deviantart',
    'tumblr.com': 'tumblr',
    'pinterest.com': 'pinterest',
    # The old substring match also caught these regional hosts.
    'pinterest.com.au': 'pinterest',
    'pinterest.com.mx': 'pinterest',
    'artsandculture.google.com': 'googlearts',
}

YOUTUBE_DOMAINS = ('youtube.com', 'youtu.be', 'youtube-nocookie.com')
FLICKR_DOMAINS = ('flickr.com', 'staticflickr.com')


def url_hostname(url: str) -> str:
    """Return a normalized hostname, excluding credentials and ports."""
    try:
        host = (urlparse(url).hostname or '').lower().rstrip('.')
    except ValueError:
        return ''
    while host.startswith(('www.', 'm.', 'mobile.')):
        host = host.split('.', 1)[1]
    return host


def url_path(url: str) -> str:
    """Return just the path, so queries/fragments cannot mimic path markers."""
    try:
        return urlparse(url).path
    except ValueError:
        return ''


def hostname_matches(host: str, domain: str) -> bool:
    return host == domain or host.endswith('.' + domain)


def matches_domains(url: str, domains: Iterable[str]) -> bool:
    host = url_hostname(url)
    return bool(host) and any(hostname_matches(host, domain) for domain in domains)


def detect_platform(url: str) -> str:
    host = url_hostname(url)
    for domain, platform in PLATFORM_DOMAINS.items():
        if hostname_matches(host, domain):
            return platform
    # Preserve the historical penultimate-label fallback (including co.uk/IPs).
    parts = host.split('.')
    return parts[-2] if len(parts) >= 2 else 'unknown'
