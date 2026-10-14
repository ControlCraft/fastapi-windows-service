"""The worker. Domain-neutral on purpose: replace this module and keep the
readiness contract (see README, "Adapting it to a real worker").

started_at is taken when the application object is built, which happens in
the service process just before uvicorn binds the port. verify.ps1 uses it to
tell a restarted process from the one it killed, and to measure boot-to-ready.
"""

from __future__ import annotations

import platform
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app import __version__
from app.config import Settings, load_settings


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class EchoIn(BaseModel):
    message: str


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or load_settings()
    app = FastAPI(title="FastAPI worker (Windows service reference)", version=__version__)
    app.state.settings = settings
    app.state.started_at = _utc_now_iso()

    @app.get("/health/live")
    def live() -> dict:
        # Process is up and the event loop answers. Nothing else is claimed.
        return {"status": "live"}

    @app.get("/health/ready")
    def ready(request: Request):
        problems = request.app.state.settings.problems()
        if problems:
            return JSONResponse(status_code=503, content={"status": "not ready", "problems": problems})
        return {"status": "ready", "started_at": request.app.state.started_at}

    @app.get("/version")
    def version(request: Request) -> dict:
        s: Settings = request.app.state.settings
        return {
            "version": __version__,
            "started_at": request.app.state.started_at,
            "python": platform.python_version(),
            "host": s.host,
            "port": s.port,
        }

    @app.post("/echo")
    def echo(body: EchoIn) -> dict:
        return {"echo": body.message, "length": len(body.message), "received_at": _utc_now_iso()}

    return app


app = create_app()
