r"""Windows service host for the FastAPI worker: pywin32 only, no NSSM, no WinSW,
no pythonservice.exe.

Registered command line:  "<root>\python\...\python.exe" -E -s "<root>\service.py"
Command line use:         python service.py [--startup delayed] install|start|stop|remove|debug

Decisions, and why.

(1) The registered executable is the base interpreter (sys._base_executable),
    not .venv\Scripts\python.exe. On Windows the venv python.exe is a launcher
    that starts the real interpreter as a child process. The Service Control
    Manager (SCM) only talks to the process it started, so a service registered
    on the launcher never reaches RUNNING. This file therefore activates the
    venv itself: site.addsitedir(.venv\Lib\site-packages) at import, which also
    executes pywin32.pth and registers pywin32's DLL directory, then the new
    entries are moved to the front so the venv wins over the base install.
    -E ignores PYTHON* variables and -s drops the user site directory, so the
    import set does not depend on which account started the process.

(2) START_PENDING is reported before any heavy import. pywin32's C host reports
    START_PENDING when the service main runs; SvcRun reports it again with a
    longer wait hint, and only then imports uvicorn and the application. Import
    time can never be the cause of error 1053. Everything imported at module
    level here is stdlib, pywin32 or app.config (stdlib only).

(3) uvicorn runs in-process in a worker thread. SvcRun is called on a thread the
    SCM dispatcher owns, not the main thread, so no signal handler can be
    installed there. ServiceServer subclasses uvicorn.Server and turns both
    install_signal_handlers (uvicorn before 0.29) and capture_signals (0.29 and
    later) into no-ops. Current uvicorn already skips signals off the main
    thread, but in "debug" mode SvcRun *is* the main thread, and there uvicorn
    would otherwise take Ctrl+C for itself instead of letting the pywin32 debug
    console handler run SvcStop. RUNNING is reported only when server.started is
    true. Until then START_PENDING is re-sent with a wait hint; if the server
    thread dies (port in use, bad HOST) or 60 s pass, startup fails with a
    message that says what to check.

(4) Stop is graceful. SvcStop reports STOP_PENDING, sets server.should_exit,
    waits for the server thread to join, then lets SvcRun return. uvicorn stops
    accepting connections at once and finishes in-flight requests, bounded by
    timeout_graceful_shutdown. SvcShutdown takes the same path.

(5) Logging goes to logs\service.log through a RotatingFileHandler on the root
    logger. uvicorn is configured with log_config=None so its loggers keep
    propagating to the root. A service has no console; "debug" mode adds one.
    Timestamps are UTC with a Z suffix, the same clock as started_at in
    /version and as verify-result.txt.

(6) An unhandled exception is logged and re-raised out of SvcRun. pywin32's host
    (PythonService.cpp, service_main) then reports STOPPED with
    win32ExitCode=ERROR_SERVICE_SPECIFIC_ERROR, which is what makes the SCM
    failure actions fire when "sc failureflag <name> 1" is set. Reporting
    STOPPED from Python first would be followed by the host's own STOPPED report
    with exit code 0, which is why this file does not do that.

Entry point: no arguments means the SCM started us (servicemanager.Initialize,
PrepareToHostSingle, StartServiceCtrlDispatcher). Anything else goes to
win32serviceutil.HandleCommandLine.
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import site
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VENV_SITE = ROOT / ".venv" / "Lib" / "site-packages"
LOG_DIR = ROOT / "logs"
LOG_FILE = LOG_DIR / "service.log"

START_TIMEOUT_S = 60          # decision (3)
START_POLL_S = 0.25
STOP_GRACEFUL_S = 20          # uvicorn finishes in-flight requests within this
STOP_JOIN_S = STOP_GRACEFUL_S + 5
WAIT_HINT_MS = 10_000


class UtcFormatter(logging.Formatter):
    """UTC with an explicit Z, same clock as started_at and verify-result.txt.
    Local time without a zone made the two files impossible to line up."""

    converter = time.gmtime
    default_time_format = "%Y-%m-%dT%H:%M:%S"
    default_msec_format = "%s.%03dZ"


LOG_FORMAT = "%(asctime)s %(levelname)s pid=%(process)d %(name)s: %(message)s"


def _configure_logging() -> logging.Logger:
    LOG_DIR.mkdir(exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8"
    )
    handler.setFormatter(UtcFormatter(LOG_FORMAT))
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(handler)
    return logging.getLogger("service")


log = _configure_logging()


def _activate_venv() -> None:
    """Decision (1). Idempotent: when started through the venv launcher (uv run,
    .venv\\Scripts\\python.exe) the directory is already on sys.path."""
    if not VENV_SITE.is_dir():
        msg = f"{VENV_SITE} not found: run .\\svc.ps1 -Step Sync first"
        log.error(msg)
        raise SystemExit("ERROR: " + msg)
    known = set(sys.path)
    site.addsitedir(str(VENV_SITE))
    added = [p for p in sys.path if p not in known]
    if added:
        sys.path[:] = added + [p for p in sys.path if p not in added]


_activate_venv()

# Light imports only from here on (decision 2).
import servicemanager  # noqa: E402
import win32service  # noqa: E402
import win32serviceutil  # noqa: E402

from app.config import LOG_LEVELS, Settings, load_settings  # noqa: E402

try:
    SETTINGS: Settings = load_settings()
except ValueError as exc:
    log.error("%s", exc)
    raise SystemExit(f"ERROR: {exc}")

# An unknown LOG_LEVEL is reported by /health/ready, not by a crash here.
if SETTINGS.log_level in LOG_LEVELS:
    logging.getLogger().setLevel(SETTINGS.log_level)

# The process the SCM must start: the real interpreter, never the venv launcher.
BASE_PYTHON = Path(getattr(sys, "_base_executable", None) or sys.executable).resolve()


def _event_log(message: str, error: bool = False) -> None:
    """Application event log, best effort: it is where an operator looks first
    when a service fails before the log file exists."""
    try:
        (servicemanager.LogErrorMsg if error else servicemanager.LogInfoMsg)(message)
    except Exception:  # noqa: BLE001 -- the file log is the record of truth
        pass


def _make_server(settings: Settings):
    """Decision (3). Imports uvicorn and the app; called after START_PENDING."""
    import contextlib

    import uvicorn

    from app.main import create_app

    class ServiceServer(uvicorn.Server):
        def install_signal_handlers(self) -> None:  # uvicorn < 0.29
            pass

        @contextlib.contextmanager
        def capture_signals(self):  # uvicorn >= 0.29
            yield

    config = uvicorn.Config(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        log_config=None,                       # decision (5)
        log_level=settings.log_level.lower(),
        timeout_graceful_shutdown=STOP_GRACEFUL_S,
    )
    return ServiceServer(config)


class WorkerService(win32serviceutil.ServiceFramework):
    _svc_name_ = SETTINGS.service_name
    _svc_display_name_ = SETTINGS.service_display_name
    _svc_description_ = "FastAPI worker hosted in-process by pywin32 (reference project)"
    _exe_name_ = str(BASE_PYTHON)
    _exe_args_ = f'-E -s "{ROOT / "service.py"}"'

    def __init__(self, args):
        super().__init__(args)
        self._server = None
        self._thread: threading.Thread | None = None
        self._stop_requested = threading.Event()

    # -- lifecycle -----------------------------------------------------------

    def SvcRun(self) -> None:
        # The base class reports RUNNING before SvcDoRun, which contradicts (3).
        self.ReportServiceStatus(win32service.SERVICE_START_PENDING, waitHint=WAIT_HINT_MS)
        try:
            self.SvcDoRun()
        except KeyboardInterrupt:
            # "debug" mode only: Ctrl+C reaches the main thread as well.
            self.SvcStop()
        except Exception:
            log.exception("service failed; the SCM is told STOPPED with an error code")
            _event_log(f"{self._svc_name_} failed, see {LOG_FILE}", error=True)
            raise                                      # decision (6)
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING, waitHint=WAIT_HINT_MS)
        log.info("stopped")

    def SvcDoRun(self) -> None:
        log.info(
            "starting %s: python=%s exe=%s service.py=%s", self._svc_name_,
            sys.version.split()[0], sys.executable, ROOT / "service.py",
        )
        self._server = _make_server(SETTINGS)
        self._thread = threading.Thread(target=self._server.run, name="uvicorn", daemon=True)
        self._thread.start()
        self._wait_until_listening()
        if self._stop_requested.is_set():
            # Stopped while still starting: never claim RUNNING.
            self._join_server()
            return

        self.ReportServiceStatus(win32service.SERVICE_RUNNING)
        log.info("running on http://%s:%d", SETTINGS.host, SETTINGS.port)
        _event_log(f"{self._svc_name_} running on http://{SETTINGS.host}:{SETTINGS.port}")

        # Wake once a second so a dead server thread is noticed and reported,
        # instead of a service that says RUNNING while nothing listens.
        while not self._stop_requested.wait(1.0):
            if not self._thread.is_alive():
                raise RuntimeError(
                    f"uvicorn thread exited while the service was RUNNING; see {LOG_FILE}"
                )
        self._join_server()

    def _wait_until_listening(self) -> None:
        deadline = time.monotonic() + START_TIMEOUT_S
        while not self._server.started:
            if self._stop_requested.is_set():
                self._server.should_exit = True
                return
            if not self._thread.is_alive():
                raise RuntimeError(
                    f"uvicorn exited before listening on {SETTINGS.host}:{SETTINGS.port}; "
                    f"the uvicorn.error lines above say why (port in use: change PORT in .env "
                    f"or stop the other process; bad HOST: use an address of this machine)"
                )
            if time.monotonic() > deadline:
                self._server.should_exit = True
                self._thread.join(5)
                raise RuntimeError(
                    f"uvicorn did not start listening within {START_TIMEOUT_S} s; "
                    f"run 'python service.py debug' from the project directory to see why"
                )
            self.ReportServiceStatus(win32service.SERVICE_START_PENDING, waitHint=WAIT_HINT_MS)
            time.sleep(START_POLL_S)

    def _join_server(self) -> None:
        if self._thread is None or not self._thread.is_alive():
            return
        self._thread.join(STOP_JOIN_S)
        if self._thread.is_alive():
            log.warning("uvicorn did not stop within %d s, forcing exit", STOP_JOIN_S)
            self._server.force_exit = True
            self._thread.join(5)

    def SvcStop(self) -> None:
        # Idempotent: in debug mode two console handlers and KeyboardInterrupt
        # can all arrive for one Ctrl+C.
        if self._stop_requested.is_set():
            return
        self._stop_requested.set()
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING, waitHint=(STOP_JOIN_S + 10) * 1000)
        log.info("stop requested")
        if self._server is not None:
            self._server.should_exit = True            # decision (4)
        self._join_server()

    def SvcShutdown(self) -> None:
        self.SvcStop()


def main(argv: list[str]) -> int:
    if len(argv) == 1:
        # Started by the SCM: become the service host.
        try:
            servicemanager.Initialize()
            servicemanager.PrepareToHostSingle(WorkerService)
            servicemanager.StartServiceCtrlDispatcher()
        except Exception as exc:  # noqa: BLE001
            # Typically error 1063 when run from a console without arguments.
            log.error("StartServiceCtrlDispatcher failed: %s", exc)
            print(
                "This file is the service host. From a console use one of:\n"
                "  python service.py --startup delayed install\n"
                "  python service.py start|stop|remove|debug",
                file=sys.stderr,
            )
            return 1
        return 0

    if "debug" in argv:
        console = logging.StreamHandler()
        console.setFormatter(UtcFormatter(LOG_FORMAT))
        logging.getLogger().addHandler(console)
        print(f"log file: {LOG_FILE}")

    if "install" in argv:
        print(f"service executable: {WorkerService._exe_name_} {WorkerService._exe_args_}")
        if ".venv" in BASE_PYTHON.parts:
            print(
                "ERROR: the base interpreter resolves inside .venv, which is a launcher. "
                "Run this with the uv-managed python under <root>\\python (svc.ps1 does).",
                file=sys.stderr,
            )
            return 1
    rc = win32serviceutil.HandleCommandLine(WorkerService, argv=argv)
    return int(rc or 0)


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main(sys.argv))
