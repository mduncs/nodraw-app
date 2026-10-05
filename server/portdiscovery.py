"""
Runtime port discovery helpers for the local download server.

The app-managed launchd path sets MEDIA_ARCHIVER_PORT explicitly. These helpers
mainly support manual server runs that ask for an ephemeral port and publish the
selected port for local tooling.
"""

from __future__ import annotations

import atexit
import json
import os
import socket
import tempfile
import time
from pathlib import Path
from typing import Set

_registered_services: Set[str] = set()


def find_free_port(host: str = "127.0.0.1") -> int:
    """Return an available TCP port without keeping the probing socket open."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, 0))
        return int(sock.getsockname()[1])


def write_port_file(service_name: str, port: int, version: str = "") -> Path:
    """Write a small JSON port file and return its path."""
    port_dir = _port_directory()
    port_dir.mkdir(parents=True, exist_ok=True)

    port_file = _port_file_path(service_name)
    tmp_file = port_file.with_suffix(port_file.suffix + ".tmp")
    payload = {
        "service": service_name,
        "port": int(port),
        "host": "127.0.0.1",
        "version": version,
        "pid": os.getpid(),
        "updated_at": time.time(),
    }

    tmp_file.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    tmp_file.replace(port_file)
    return port_file


def remove_port_file(service_name: str) -> None:
    """Remove the service port file if it exists."""
    _port_file_path(service_name).unlink(missing_ok=True)


def register_cleanup(service_name: str) -> None:
    """Register one atexit cleanup handler for the service port file."""
    if service_name in _registered_services:
        return

    _registered_services.add(service_name)
    atexit.register(remove_port_file, service_name)


def _port_directory() -> Path:
    configured = os.environ.get("MEDIA_ARCHIVER_PORT_DIR")
    if configured:
        return Path(configured).expanduser()

    return Path(tempfile.gettempdir()) / "nodraw-ports"


def _port_file_path(service_name: str) -> Path:
    safe_name = "".join(
        char if char.isalnum() or char in ("-", "_", ".") else "_"
        for char in service_name
    )
    return _port_directory() / f"{safe_name}.json"
