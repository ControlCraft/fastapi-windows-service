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


def _service_state(name: str) -> int | None:
    """Current state through the SCM API, not by parsing sc.exe text. None when not installed."""
    import pywintypes
    import win32serviceutil

    try:
        return win32serviceutil.QueryServiceStatus(name)[1]
    except pywintypes.error as exc:
        if exc.winerror == 1060:  # ERROR_SERVICE_DOES_NOT_EXIST
            return None
        raise


@pytest.fixture(scope="module")
def installed_service():
    settings = load_settings()
    if not _is_admin():
        pytest.skip("run from an elevated shell")
    if _service_state(settings.service_name) is None:
        pytest.skip(f"service {settings.service_name} is not installed: .\\svc.ps1 -Step Install")
    return settings


def test_service_running(installed_service):
    import win32service

    state = _service_state(installed_service.service_name)
    sc_text = subprocess.run(["sc.exe", "query", installed_service.service_name], capture_output=True, text=True).stdout
    assert state == win32service.SERVICE_RUNNING, f"service state is {state}, not RUNNING:\n{sc_text}\nstart it with .\\svc.ps1 -Step Start"


def test_ready_200(installed_service):
    host = installed_service.host
    if host in ("0.0.0.0", "::"):
        host = "127.0.0.1"
    with urllib.request.urlopen(f"http://{host}:{installed_service.port}/health/ready", timeout=5) as r:
        assert r.status == 200
        body = json.loads(r.read())
    assert body["status"] == "ready"
