"""Settings for the worker.

Precedence, lowest to highest: built-in defaults, the .env file next to the
project root, the process environment. Parsing is stdlib only: the file format
is KEY=VALUE, nothing more, and twelve lines of code cover it.

Readiness is a configuration check and nothing else. It must never make a
remote or paid call: it runs on every poll from the service scripts and from
whoever monitors the service.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_ROOT / ".env"

DEFAULTS: dict[str, str] = {
    "SERVICE_NAME": "FastApiWorker",
    "SERVICE_DISPLAY_NAME": "FastAPI Worker (reference)",
    "HOST": "127.0.0.1",
    "PORT": "8010",
    "REQUIRED_SETTING": "",
    "LOG_LEVEL": "INFO",
}

LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")


def parse_env_file(path: Path) -> dict[str, str]:
    """Read KEY=VALUE lines. Blank lines and # comments are skipped, an
    "export " prefix and one pair of surrounding quotes are stripped.
    No variable interpolation, no multi-line values: keep .env boring."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


@dataclass(frozen=True)
class Settings:
    service_name: str
    service_display_name: str
    host: str
    port: int
    required_setting: str
    log_level: str

    def problems(self) -> list[str]:
        """What stops the worker from doing its job. Empty means ready.
        Every entry says what to do next; it ends up in a 503 body."""
        found: list[str] = []
        if not self.required_setting:
            found.append("REQUIRED_SETTING is empty: set it in .env or in the service environment")
        if self.log_level not in LOG_LEVELS:
            found.append(f"LOG_LEVEL={self.log_level!r} is not one of {', '.join(LOG_LEVELS)}")
        if not (1 <= self.port <= 65535):
            found.append(f"PORT={self.port} is outside 1..65535")
        return found


def load_settings(env_file: Path | None = ENV_FILE, environ: Mapping[str, str] | None = None) -> Settings:
    """Merge defaults, the .env file and the process environment.

    PORT must be an integer: a service cannot bind to a typo, so it fails here
    with a message instead of producing a half-configured object."""
    merged = dict(DEFAULTS)
    if env_file is not None:
        merged.update(parse_env_file(env_file))
    env = os.environ if environ is None else environ
    for key in DEFAULTS:
        if key in env:
            merged[key] = env[key]

    try:
        port = int(merged["PORT"])
    except ValueError:
        raise ValueError(
            f"PORT={merged['PORT']!r} is not an integer: fix it in {env_file} or in the environment"
        ) from None

    return Settings(
        service_name=merged["SERVICE_NAME"],
        service_display_name=merged["SERVICE_DISPLAY_NAME"],
        host=merged["HOST"],
        port=port,
        required_setting=merged["REQUIRED_SETTING"],
        log_level=merged["LOG_LEVEL"].upper(),
    )
