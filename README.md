# FastAPI worker as a native Windows service (pywin32 + uv)

A small FastAPI worker that runs as a Windows service on Windows Server 2016 and 2019
without containers and without a third-party service wrapper: no NSSM, no WinSW,
no pythonservice.exe. The interpreter is Python 3.12 managed by uv and installed
under the project directory. The service host is `service.py`, a pywin32
`ServiceFramework` subclass that runs uvicorn in-process.

The worker itself is domain-neutral on purpose. It exposes a readiness contract,
a version endpoint and one working endpoint (`POST /echo`) that stands in for the
real job. The point of the repository is the deployment: how the service is
registered, how it starts, how it stops, how it recovers, and how that is measured.

## Design decisions

**The registered executable is the base interpreter, not `.venv\Scripts\python.exe`.**
On Windows the `python.exe` inside a virtual environment is a small launcher that
starts the real interpreter as a child process. The Service Control Manager (SCM)
only talks to the process it started, so a service registered on the venv launcher
either times out (error 1053) or is controlled through the wrong process.
The command line registered with the SCM is `"<root>\python\...\python.exe" -E -s "<root>\service.py"`.
`service.py` adds `.venv\Lib\site-packages` to `sys.path` at import through
`site.addsitedir`, so pywin32's `.pth` file registers its DLL directory, then moves
that entry to the front so the venv wins over anything in the base install.
`-E` ignores `PYTHON*` environment variables and `-s` disables the user site
directory, so what the service imports does not depend on who started it.

**START_PENDING is reported before any heavy import.** The C host inside pywin32
reports START_PENDING as soon as the service main runs, and `service.py` reports it
again with a longer wait hint before importing uvicorn and the application.
Import time can therefore never be the cause of error 1053.

**uvicorn runs in-process in a worker thread and RUNNING is reported only when the
server is listening.** `SvcDoRun` is not the main thread, so signal handlers cannot
be installed there. `service.py` subclasses `uvicorn.Server` and turns both
`install_signal_handlers` (uvicorn before 0.29) and `capture_signals` (uvicorn 0.29
and later) into no-ops. The service reports RUNNING only once `server.started` is
true. While waiting it keeps sending START_PENDING with a wait hint. If the server
thread dies, or 60 seconds pass, it fails with a message that names the cause
(typically a port in use or a bad HOST).

**Stop is graceful.** `SvcStop` sets `server.should_exit`, waits for the server
thread to finish, then returns, and STOPPED is reported. In-flight requests finish;
uvicorn stops accepting new ones immediately. `SvcShutdown` takes the same path.

**Logging goes to a file, and unhandled exceptions fail loudly.** A service has no
console. The root logger writes to `logs\service.log` through a
`RotatingFileHandler`, and uvicorn is configured with `log_config=None` so its
loggers propagate into the same file. If `SvcDoRun` raises, the exception is logged
and re-raised, and the pywin32 host reports STOPPED with a non-zero exit code, so
the SCM failure actions configured by `svc.ps1` (restart after 5, 10 and 30 s) fire.

## Install

Run PowerShell as administrator in the project directory.

```powershell
irm https://astral.sh/uv/install.ps1 | iex
Copy-Item .env.example .env
.\svc.ps1 -Step Install
.\verify.ps1 -Phase All
Restart-Computer
.\verify.ps1 -Phase AfterReboot
```

What each step does:

- `svc.ps1 -Step Install` runs `Preflight` (administrator, uv on PATH, Windows version,
  port free), then `Sync` (installs Python 3.12 under `<root>\python`, creates `.venv`
  from `uv.lock` with `uv sync --frozen --no-dev`, checks the base interpreter is under
  the project), then registers the service with delayed automatic start, configures
  SCM failure actions, switches the service to the virtual account
  `NT SERVICE\<SERVICE_NAME>`, and grants that account read and execute on the project
  and modify on `logs\` only.
- `verify.ps1 -Phase All` starts the service and measures the time to the first
  `200` from `/health/ready`, then kills the service process with `taskkill /F` and
  measures the time until a new process answers `200`. This proves SCM recovery.
- `verify.ps1 -Phase AfterReboot` reports how many seconds after boot the service
  was ready, using `started_at` from `/version` and `LastBootUpTime` from the OS.

Every phase appends one line to `verify-result.txt` and writes `verify-result.json`.

Other steps: `.\svc.ps1 -Step Start|Stop|Status|Uninstall`. `Uninstall` removes the
service registration and keeps all files, `.env` and logs. Nothing in these scripts
deletes anything. `.\svc.ps1 -Step Install -RunAsLocalSystem` skips the account
step, which is useful to separate permission problems from everything else.

## Measured on Windows Server 2016

| Measurement | Seconds | Source line in verify-result.txt |
| --- | --- | --- |
| Service start to first `200` from `/health/ready` | TBD | TBD |
| Process killed with `taskkill /F` to `200` from a new process | TBD | TBD |
| Boot to ready (`started_at` minus `LastBootUpTime`) | TBD | TBD |

The kill measurement is expected to be a little over 5 seconds: the first SCM
restart delay is 5000 ms, then the interpreter starts and the server binds.

## Adapting it to a real worker

- Replace `app/main.py` with the real application. Keep the three endpoints
  `/health/live`, `/health/ready` and `/version`: `svc.ps1` and `verify.ps1` depend on
  them, and so does whoever operates the service.
- Keep the readiness contract: `/health/ready` checks configuration only and never
  makes a remote or paid call. It returns `503` with a list of problems until the
  service can do its job, and `200` with `started_at` afterwards. Anything that costs
  money or depends on a third party belongs behind a real endpoint, not readiness.
- Set `HOST` in `.env` to the interface the upstream caller uses. `127.0.0.1` is only
  reachable from the same machine. If a remote caller needs the port, bind the specific
  interface address rather than `0.0.0.0`, and add a firewall rule that allows that port
  only from the caller's address:
  `New-NetFirewallRule -DisplayName "FastApiWorker" -Direction Inbound -Protocol TCP -LocalPort 8010 -RemoteAddress 10.0.0.5 -Action Allow`.
- Secrets go into `.env` or the service environment, never into the repository.
  `.env` is readable by the virtual account because it lives under the project root.
  If that is too broad, move secrets to a file with a tighter ACL and read it in
  `app/config.py`.
- Add dependencies with `uv add`, commit `uv.lock`, run `.\svc.ps1 -Step Stop`,
  `.\svc.ps1 -Step Sync`, `.\svc.ps1 -Step Start`.

## Troubleshooting

**Error 1053: the service did not respond to the start or control request in a
timely fashion.** The SCM waited 30 s and never heard START_PENDING or RUNNING.
With this layout the usual causes are: the registered executable is not the real
interpreter (check `sc qc <name>`: the path must be under `<root>\python`, not
`.venv\Scripts`); `service.py` failed before reaching the dispatcher (look at
`logs\service.log` and the Application event log for a Python traceback); or the
service account cannot read the project (run `.\svc.ps1 -Step Install -RunAsLocalSystem`
to rule that out, then compare `icacls <root>`). `python service.py debug` runs the
same code in a console with the same interpreter and shows the traceback directly.

**DLL load failed while importing win32service, pywintypes or servicemanager.**
pywin32 keeps `pywintypes312.dll` and `pythoncom312.dll` in
`.venv\Lib\site-packages\pywin32_system32` and registers that directory from its
`.pth` file. The service relies on `site.addsitedir` running against the venv's
`site-packages`, which `service.py` does at import. If the error persists, check that
`.venv\Lib\site-packages\pywin32.pth` exists (re-run `.\svc.ps1 -Step Sync`), that
`.venv` was created with `UV_LINK_MODE=copy` (hardlinked files share the ACL of the uv
cache in the user profile, which the service account cannot read), and that the
service account has read access to `.venv` (`icacls .venv`). Do not run the pywin32
post-install script; it copies DLLs into the interpreter directory and is not needed.

**Port in use.** `logs\service.log` contains
`[Errno 10048] error while attempting to bind on address` and the service stops with
an error shortly after start. Find the owner with
`Get-NetTCPConnection -LocalPort 8010 | Select OwningProcess` and
`Get-Process -Id <pid>`. Either stop that process or change `PORT` in `.env` and
restart the service. `svc.ps1 -Step Preflight` checks the port before installing.

**The service starts but `/health/ready` returns 503.** Read the `problems` list in
the response. The most common one is an empty `REQUIRED_SETTING`: set it in `.env`
and restart the service.

## Layout

```
app/config.py        settings from .env and the process environment, stdlib only
app/main.py          FastAPI application: /health/live, /health/ready, /version, POST /echo
service.py           pywin32 service host; also the install/start/stop/remove/debug CLI
svc.ps1              Preflight, Sync, Install, Start, Stop, Status, Uninstall
verify.ps1           the measured result: Start, Kill, AfterReboot, All
tests/               pytest; the Windows test skips unless run as administrator on a machine with the service installed
.env.example         configuration template
verify-result.txt    one line per verify phase, tracked as evidence
```

Run the unit tests with `uv run --group dev pytest`.

## License

MIT.
