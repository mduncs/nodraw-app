"""
Import and dependency-health tests for the download server entrypoint.
"""

import json
import os
import subprocess
import sys
from pathlib import Path


SERVER_DIR = Path(__file__).resolve().parent.parent


def _run_import(tmp_path, script):
    env = os.environ.copy()
    env["MEDIA_ARCHIVER_DIR"] = str(tmp_path / "archive")
    env["MEDIA_ARCHIVER_PORT"] = "8847"
    env["PYTHONPATH"] = str(SERVER_DIR)

    return subprocess.run(
        [sys.executable, "-c", script],
        cwd=SERVER_DIR,
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def test_main_imports_with_temp_archive_and_fixed_port(tmp_path):
    result = _run_import(
        tmp_path,
        "import main; print(f'imported:{main.PORT}:{main.ARCHIVE_DIR}')",
    )

    assert result.returncode == 0, result.stderr
    assert "imported:8847:" in result.stdout


def test_main_imports_when_setproctitle_is_unavailable(tmp_path):
    script = """
import builtins

real_import = builtins.__import__

def guarded_import(name, *args, **kwargs):
    if name == "setproctitle":
        raise ImportError("blocked for fallback test")
    return real_import(name, *args, **kwargs)

builtins.__import__ = guarded_import
import main
print(main._set_process_title("nodraw-server-test"))
"""
    result = _run_import(tmp_path, script)

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "False"


def test_portdiscovery_writes_and_removes_port_file(tmp_path, monkeypatch):
    monkeypatch.setenv("MEDIA_ARCHIVER_PORT_DIR", str(tmp_path))

    from portdiscovery import find_free_port, remove_port_file, write_port_file

    port = find_free_port()
    path = write_port_file("org.nodraw.download-server", port, version="test")

    assert path == tmp_path / "org.nodraw.download-server.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["service"] == "org.nodraw.download-server"
    assert payload["port"] == port
    assert payload["host"] == "127.0.0.1"
    assert payload["version"] == "test"

    remove_port_file("org.nodraw.download-server")
    assert not path.exists()
