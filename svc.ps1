<#
.SYNOPSIS
  Install, start, stop, inspect and remove the FastAPI worker Windows service.

.DESCRIPTION
  One step per call: -Step Preflight|Sync|Install|Start|Stop|Status|Uninstall.
  Install runs Preflight and Sync first. Output goes to the console and to
  logs\svc.log. Exit code 0 on success, 1 with one "ERROR: ..." line otherwise.
  Nothing here deletes files.

  Sync installs Python 3.12 under <root>\python (UV_PYTHON_INSTALL_DIR) with
  UV_PYTHON_PREFERENCE=only-managed, so the interpreter is not in the user profile
  of whoever ran the install, where a service account could not read it. It sets
  UV_LINK_MODE=copy because a hardlinked file shares its ACL with the uv cache in
  the user profile; copied files inherit the project ACL instead.

  Install registers the service through service.py with delayed automatic start,
  then configures SCM failure actions (restart after 5, 10, 30 s; counter reset
  after one day; also on stops with an error code), switches the service to the
  virtual account NT SERVICE\<name> (no password to manage) and grants that
  account read+execute on the project and modify on logs\ only.
  -RunAsLocalSystem skips the account step, to separate permission problems from
  everything else while diagnosing.

.EXAMPLE
  .\svc.ps1 -Step Install
  .\svc.ps1 -Step Status
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Preflight', 'Sync', 'Install', 'Start', 'Stop', 'Status', 'Uninstall')]
    [string]$Step,
    [switch]$RunAsLocalSystem
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
$ServicePy = Join-Path $Root 'service.py'
$ReadyTimeoutSec = 60

# -- helpers -------------------------------------------------------------------

function Read-DotEnv {
    # Same rules as app/config.py: KEY=VALUE, # comments, optional quotes,
    # optional "export " prefix; the process environment wins over the file.
    $values = @{
        SERVICE_NAME = 'FastApiWorker'; SERVICE_DISPLAY_NAME = 'FastAPI Worker (reference)'
        HOST = '127.0.0.1'; PORT = '8010'; REQUIRED_SETTING = ''; LOG_LEVEL = 'INFO'
    }
    $file = Join-Path $Root '.env'
    if (Test-Path $file) {
        foreach ($raw in Get-Content $file -Encoding UTF8) {
            $line = $raw.Trim()
            if ($line -eq '' -or $line.StartsWith('#') -or -not $line.Contains('=')) { continue }
            if ($line.StartsWith('export ')) { $line = $line.Substring(7) }
            $key, $value = $line.Split('=', 2)
            $key = $key.Trim(); $value = $value.Trim()
            if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and ($value[0] -eq '"' -or $value[0] -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ($key) { $values[$key] = $value }
        }
    }
    foreach ($key in @($values.Keys)) {
        $fromEnv = [Environment]::GetEnvironmentVariable($key)
        if ($null -ne $fromEnv) { $values[$key] = $fromEnv }
    }
    return $values
}

function Get-ReadyUrl($cfg) {
    $h = $cfg.HOST
    if ($h -eq '' -or $h -eq '0.0.0.0') { $h = '127.0.0.1' }
    elseif ($h -eq '::') { $h = '[::1]' }
    return "http://${h}:$($cfg.PORT)/health/ready"
}

function Test-Ready($url) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Wait-Ready($url, $timeoutSec) {
    # Polls every 100 ms. Returns seconds to the first 200, or $null.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if (Test-Ready $url) { return [math]::Round($sw.Elapsed.TotalSeconds, 2) }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Find-Service($name) {
    return Get-Service -Name $name -ErrorAction SilentlyContinue
}

function Get-BasePython {
    # The venv records its base interpreter in pyvenv.cfg ("home = <dir>").
    # That interpreter, not .venv\Scripts\python.exe, is what the SCM must start.
    $cfg = Join-Path $Root '.venv\pyvenv.cfg'
    if (-not (Test-Path $cfg)) { throw ".venv\pyvenv.cfg not found: run .\svc.ps1 -Step Sync" }
    $home_ = (Get-Content $cfg | Where-Object { $_ -match '^\s*home\s*=\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
    if (-not $home_) { throw "no 'home =' line in ${cfg}: delete .venv and run .\svc.ps1 -Step Sync" }
    $exe = Join-Path $home_ 'python.exe'
    if (-not (Test-Path $exe)) { throw "base interpreter $exe not found: run .\svc.ps1 -Step Sync" }
    return $exe
}

function Invoke-Checked([string]$what, [scriptblock]$block) {
    Write-Host ">> $what"
    & $block
    if ($LASTEXITCODE -ne 0) { throw "$what failed with exit code $LASTEXITCODE (see output above)" }
}

function Show-LogTail {
    $log = Join-Path $LogDir 'service.log'
    if (Test-Path $log) {
        Write-Host "---- last 20 lines of $log"
        Get-Content $log -Tail 20 | ForEach-Object { Write-Host "   $_" }
    }
}

# -- steps ---------------------------------------------------------------------

function Step-Preflight {
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "not running as administrator: open PowerShell with 'Run as administrator'"
    }
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or newer is required" }

    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "OS: $($os.Caption) $($os.Version)"
    if ([version]$os.Version -lt [version]'10.0.14393') {
        Write-Warning "tested on Windows Server 2016 (10.0.14393) and 2019 (10.0.17763); older versions are not covered"
    }

    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) {
        throw "uv is not on PATH: install with 'irm https://astral.sh/uv/install.ps1 | iex', then open a new PowerShell"
    }
    Write-Host "uv: $(& uv --version) at $($uv.Source)"

    if (-not (Test-Path (Join-Path $Root 'uv.lock'))) { throw "uv.lock is missing: it must be committed with the project" }
    if (-not (Test-Path (Join-Path $Root '.env'))) {
        throw ".env is missing: Copy-Item .env.example .env, then set REQUIRED_SETTING"
    }
    $cfg = Read-DotEnv
    Write-Host "service: $($cfg.SERVICE_NAME) on $($cfg.HOST):$($cfg.PORT)"
    if (-not $cfg.REQUIRED_SETTING) {
        Write-Warning "REQUIRED_SETTING is empty: the service will start but /health/ready will answer 503"
    }

    # The port must be free, unless our own service already holds it.
    $listeners = @(Get-NetTCPConnection -LocalPort ([int]$cfg.PORT) -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$($cfg.SERVICE_NAME)'"
        $ours = $svc -and ($listeners | Where-Object { $_.OwningProcess -eq $svc.ProcessId })
        if (-not $ours) {
            $owner = Get-Process -Id $listeners[0].OwningProcess -ErrorAction SilentlyContinue
            throw "port $($cfg.PORT) is in use by PID $($listeners[0].OwningProcess) ($($owner.ProcessName)): stop it or change PORT in .env"
        }
    }
    Write-Host "preflight ok"
}

function Step-Sync {
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $Root 'python'
    $env:UV_PYTHON_PREFERENCE = 'only-managed'
    $env:UV_LINK_MODE = 'copy'
    Push-Location $Root
    try {
        Invoke-Checked "uv python install 3.12 (into $env:UV_PYTHON_INSTALL_DIR)" { & uv python install 3.12 }
        Invoke-Checked "uv sync --frozen --no-dev" { & uv sync --frozen --no-dev }
    } finally { Pop-Location }

    $base = Get-BasePython
    $expected = (Join-Path $Root 'python') + '\'
    if (-not $base.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "base interpreter is $base, expected it under $expected. Delete .venv and run Sync again in a shell where UV_PYTHON_INSTALL_DIR is not set elsewhere"
    }
    Write-Host "base interpreter: $base"

    # Exactly what the service does at import: base interpreter, -E -s, venv site added by hand.
    $site = Join-Path $Root '.venv\Lib\site-packages'
    $code = "import site, sys; site.addsitedir(r'$site'); import win32service, servicemanager, uvicorn, fastapi; print('imports ok, uvicorn', uvicorn.__version__)"
    Invoke-Checked "import check with the base interpreter" { & $base -E -s -c $code }
}

function Step-Install {
    Step-Preflight
    Step-Sync
    $cfg = Read-DotEnv
    $name = $cfg.SERVICE_NAME
    $base = Get-BasePython

    $existing = Find-Service $name
    if ($existing) {
        if ($existing.Status -ne 'Stopped') {
            Write-Host "stopping existing service $name"
            Stop-Service -Name $name -Force
            (Get-Service $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        Invoke-Checked "service.py update (service already registered)" { & $base -E -s $ServicePy --startup delayed update }
    } else {
        Invoke-Checked "service.py install" { & $base -E -s $ServicePy --startup delayed install }
    }

    # sc is an alias of Set-Content in PowerShell; sc.exe is the tool. The
    # "key= value" spelling with the space is what sc.exe parses.
    Invoke-Checked "sc failure" { & sc.exe failure $name reset= 86400 actions= restart/5000/restart/10000/restart/30000 }
    Invoke-Checked "sc failureflag" { & sc.exe failureflag $name 1 }

    if ($RunAsLocalSystem) {
        Invoke-Checked "sc config obj= LocalSystem" { & sc.exe config $name obj= LocalSystem }
        Write-Warning "running as LocalSystem for diagnosis; re-run Install without -RunAsLocalSystem afterwards"
    } else {
        $account = "NT SERVICE\$name"
        # unrestricted: the per-service SID is in the token, which is the SID the ACLs below name.
        Invoke-Checked "sc sidtype unrestricted" { & sc.exe sidtype $name unrestricted }
        Invoke-Checked "sc config obj= $account" { & sc.exe config $name obj= $account }
        Invoke-Checked "icacls $Root (RX)" { & icacls.exe $Root /grant "${account}:(OI)(CI)RX" }
        Invoke-Checked "icacls $LogDir (M)" { & icacls.exe $LogDir /grant "${account}:(OI)(CI)M" }
        # Inheritable ACEs propagate to existing children when the directory ACL
        # is set. Verify on a deep file and fall back to /T if a child was protected.
        $probe = Join-Path $Root '.venv\Lib\site-packages\pywin32.pth'
        if (-not ((& icacls.exe $probe) -match [regex]::Escape($account))) {
            Write-Host "inheritance did not reach $probe, applying /T"
            Invoke-Checked "icacls $Root /T" { & icacls.exe $Root /grant "${account}:(OI)(CI)RX" /T /Q }
        }
    }

    Write-Host "---- sc qc $name"
    & sc.exe qc $name
    Write-Host "---- sc qfailure $name"
    & sc.exe qfailure $name
    Write-Host "installed. Next: .\svc.ps1 -Step Start  (or .\verify.ps1 -Phase All)"
}

function Step-Start {
    $cfg = Read-DotEnv
    $name = $cfg.SERVICE_NAME
    $svc = Find-Service $name
    if (-not $svc) { throw "service $name is not installed: run .\svc.ps1 -Step Install" }
    $url = Get-ReadyUrl $cfg
    if ($svc.Status -eq 'Running' -and (Test-Ready $url)) {
        Write-Host "already running and ready at $url"
        return
    }
    if ($svc.Status -eq 'Stopped') {
        Invoke-Checked "sc start $name" { & sc.exe start $name | Out-Null }
    }
    $seconds = Wait-Ready $url $ReadyTimeoutSec
    if ($null -eq $seconds) {
        Write-Host "---- sc query $name"
        & sc.exe query $name
        Show-LogTail
        throw "no 200 from $url within $ReadyTimeoutSec s: read the log tail above; a 503 means REQUIRED_SETTING is empty in .env"
    }
    $pid_ = (Get-CimInstance Win32_Service -Filter "Name='$name'").ProcessId
    Write-Host "ready after $seconds s (pid $pid_) at $url"
}

function Step-Stop {
    $cfg = Read-DotEnv
    $name = $cfg.SERVICE_NAME
    $svc = Find-Service $name
    if (-not $svc) { throw "service $name is not installed" }
    if ($svc.Status -eq 'Stopped') { Write-Host "already stopped"; return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-Service -Name $name
    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    Write-Host "stopped in $([math]::Round($sw.Elapsed.TotalSeconds, 2)) s"
}

function Step-Status {
    $cfg = Read-DotEnv
    $name = $cfg.SERVICE_NAME
    $svc = Find-Service $name
    if (-not $svc) { Write-Host "service $name is not installed"; return }
    & sc.exe query $name
    & sc.exe qc $name
    & sc.exe qfailure $name
    $wmi = Get-CimInstance Win32_Service -Filter "Name='$name'"
    Write-Host "pid: $($wmi.ProcessId)  account: $($wmi.StartName)"
    $url = Get-ReadyUrl $cfg
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2
        Write-Host "$url -> $($r.StatusCode) $($r.Content)"
    } catch {
        Write-Host "$url -> $($_.Exception.Message)"
    }
    Show-LogTail
}

function Step-Uninstall {
    $cfg = Read-DotEnv
    $name = $cfg.SERVICE_NAME
    $svc = Find-Service $name
    if (-not $svc) { Write-Host "service $name is not installed, nothing to do"; return }
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $name -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
    if (Test-Path (Join-Path $Root '.venv\pyvenv.cfg')) {
        Invoke-Checked "service.py remove" { & (Get-BasePython) -E -s $ServicePy remove }
    } else {
        Invoke-Checked "sc delete $name" { & sc.exe delete $name }
    }
    Write-Host "service removed. Files, .env, python\, .venv\ and logs\ are kept; delete them by hand if wanted"
}

# -- main ----------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'svc.log') -Append | Out-Null
# Loopback calls must not wait for proxy auto-detection; it would also skew timings.
[System.Net.WebRequest]::DefaultWebProxy = $null
$exitCode = 0
try {
    Write-Host "== svc.ps1 -Step $Step  ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
    & "Step-$Step"
    Write-Host "== $Step done"
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    Stop-Transcript | Out-Null
}
exit $exitCode
