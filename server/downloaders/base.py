"""
Base classes for media downloaders
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Dict, Optional, Any


class DownloadFailureKind(str, Enum):
    """Machine-readable disposition for an unsuccessful downloader result."""

    NO_MEDIA = "no_media"
    UNSUPPORTED = "unsupported"
    TERMINAL = "terminal"


@dataclass
class DownloadResult:
    """Result of a download operation"""
    file_path: Optional[Path]
    metadata: Dict[str, Any]
    success: bool = True
    error: Optional[str] = None
    failure_kind: Optional[DownloadFailureKind] = None
    published_paths: tuple[Path, ...] = ()

    @property
    def is_no_media(self) -> bool:
        """Whether screenshot/metadata fallback is explicitly safe."""
        return not self.success and self.failure_kind == DownloadFailureKind.NO_MEDIA

    @property
    def is_terminal_failure(self) -> bool:
        """Treat legacy untyped failures conservatively as terminal."""
        return not self.success and not self.is_no_media

class BaseDownloader(ABC):
    """Abstract base class for all downloaders"""

    name: str = "base"

    @abstractmethod
    def can_handle(self, url: str) -> bool:
        """Check if this downloader can handle the given URL"""
        pass

    @abstractmethod
    async def download(
        self,
        url: str,
        cookies: Dict[str, str],
        output_dir: Path,
        options: Optional[Dict] = None
    ) -> DownloadResult:
        """
        Download media from URL

        Args:
            url: URL to download from
            cookies: Dictionary of cookies
            output_dir: Directory to save files to
            options: Additional options for the downloader

        Returns:
            DownloadResult with file path and metadata
        """
        pass
