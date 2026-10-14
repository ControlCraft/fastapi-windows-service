from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import __version__
from app.config import load_settings, parse_env_file
from app.main import create_app


def make_client(tmp_path: Path, monkeypatch, env_file_text: str = "", **env) -> TestClient:
    """Isolate from any real .env and from the developer's environment."""
    env_file = tmp_path / ".env"
    env_file.write_text(env_file_text, encoding="utf-8")
    for key in ("SERVICE_NAME", "SERVICE_DISPLAY_NAME", "HOST", "PORT", "REQUIRED_SETTING", "LOG_LEVEL"):
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    return TestClient(create_app(load_settings(env_file=env_file)))


def test_live(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch)
    r = client.get("/health/live")
    assert r.status_code == 200
    assert r.json() == {"status": "live"}


def test_ready_ok(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch, REQUIRED_SETTING="x")
    r = client.get("/health/ready")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ready"
    assert body["started_at"].endswith("+00:00")


def test_ready_503_when_required_setting_empty(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch, "REQUIRED_SETTING=from-file\n", REQUIRED_SETTING="")
    r = client.get("/health/ready")
    assert r.status_code == 503
    body = r.json()
    assert body["status"] == "not ready"
    assert any("REQUIRED_SETTING" in p for p in body["problems"])


def test_version_fields(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch, "HOST=10.1.2.3\nPORT=9001\n", REQUIRED_SETTING="x")
    r = client.get("/version")
    assert r.status_code == 200
    body = r.json()
    assert body["version"] == __version__
    assert body["host"] == "10.1.2.3"
    assert body["port"] == 9001
    assert body["python"].count(".") == 2
    assert body["started_at"] == client.get("/health/ready").json()["started_at"]


def test_echo(tmp_path, monkeypatch):
    client = make_client(tmp_path, monkeypatch, REQUIRED_SETTING="x")
    r = client.post("/echo", json={"message": "hello"})
    assert r.status_code == 200
    body = r.json()
    assert body["echo"] == "hello"
    assert body["length"] == 5
    assert "received_at" in body
    assert client.post("/echo", json={}).status_code == 422


def test_env_file_parsing_and_precedence(tmp_path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# comment\n\nexport HOST = '0.0.0.0'\nPORT=\"8020\"\nREQUIRED_SETTING=a=b\nLOG_LEVEL=debug\n",
        encoding="utf-8",
    )
    assert parse_env_file(env_file) == {
        "HOST": "0.0.0.0",
        "PORT": "8020",
        "REQUIRED_SETTING": "a=b",
        "LOG_LEVEL": "debug",
    }
    monkeypatch.setenv("PORT", "8030")
    s = load_settings(env_file=env_file, environ={"PORT": "8030"})
    assert s.host == "0.0.0.0"
    assert s.port == 8030  # process environment wins over the file
    assert s.log_level == "DEBUG"
    assert s.problems() == []
    assert load_settings(env_file=tmp_path / "missing", environ={}).port == 8010


def test_bad_port_fails_with_message(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("PORT=eighty\n", encoding="utf-8")
    with pytest.raises(ValueError, match="PORT='eighty' is not an integer"):
        load_settings(env_file=env_file, environ={})
