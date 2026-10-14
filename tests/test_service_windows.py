"""Checks the installed service on the server itself. Skipped anywhere else.

Requires: Windows, an elevated shell, and the service registered under the
SERVICE_NAME from .env. Run with: uv run --group dev pytest tests/test_service_windows.py
"""

import ctypes
import json
import subprocess
import sys
import urllib.request

import pytest

from app.config import load_settings

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows service test")


def _is_admin() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _sc_query(name: str) -> str:
    return subprocess.run(["sc", "query", name], capture_output=True, text=True).stdout


@pytest.fixture(scope="module")
def installed_service():
    settings = load_settings()
    if not _is_admin():
        pytest.skip("run from an elevated shell")
    out = _sc_query(settings.service_name)
    if "STATE" not in out:
        pytest.skip(f"service {settings.service_name} is not installed: .\\svc.ps1 -Step Install")
    return settings


def test_service_running(installed_service):
    out = _sc_query(installed_service.service_name)
    assert "RUNNING" in out, f"service is not RUNNING:\n{out}\nstart it with .\\svc.ps1 -Step Start"


def test_ready_200(installed_service):
    host = installed_service.host
    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    with urllib.request.urlopen(f"http://{host}:{installed_service.port}/health/ready", timeout=5) as r:
        assert r.status == 200
        body = json.loads(r.read())
    assert body["status"] == "ready"
