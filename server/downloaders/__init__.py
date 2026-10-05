"""
Downloader module for handling various media types
"""

from .base import DownloadFailureKind, DownloadResult
from .ytdlp_handler import YtDlpHandler
from .gallery_handler import GalleryDlHandler
from .dezoomify_handler import DezoomifyHandler
from typing import Optional
import logging

logger = logging.getLogger(__name__)

class DownloadManager:
    """Manages different download handlers"""

    def __init__(self):
        self.handlers = [
            DezoomifyHandler(),  # Check dezoomify first for tiled images
            GalleryDlHandler(),  # Then gallery-dl for image galleries
            YtDlpHandler()       # Finally yt-dlp as fallback
        ]

    def get_handler(self, url: str):
        """Get appropriate handler for URL"""
        for handler in self.handlers:
            if handler.can_handle(url):
                logger.info(f"Using {handler.name} for {url}")
                return handler

        # Default to yt-dlp as it supports the most sites
        logger.info(f"Using default yt-dlp handler for {url}")
        return self.handlers[-1]  # Use last handler (yt-dlp) as default

    def list_handlers(self):
        """List available handlers"""
        return [h.name for h in self.handlers]

    def get_fallback_handler(self, handler, url: str, result: DownloadResult):
        """Try yt-dlp only when gallery-dl explicitly rejects the URL."""
        if (
            handler.name != 'gallery-dl'
            or result.success
            or result.failure_kind != DownloadFailureKind.UNSUPPORTED
        ):
            return None
        return next(
            (h for h in self.handlers if h.name == 'yt-dlp' and h.can_handle(url)),
            None,
        )

__all__ = ['DownloadManager', 'DownloadFailureKind', 'DownloadResult']
