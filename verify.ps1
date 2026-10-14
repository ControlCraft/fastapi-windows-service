<#
.SYNOPSIS
  The measured result: how fast the service becomes ready, recovers from a kill,
  and is ready after a reboot.

.DESCRIPTION
  -Phase Start        stop if running, start, poll /health/ready every 100 ms,
                      record seconds to the first 200.
  -Phase Kill         taskkill /F the service process, poll until a 200 comes
                      from a new process (started_at in /version changed),
                      record seconds from the kill to that 200. This proves the
                      SCM failure actions work. Expected: a little over the 5 s
                      first-restart delay. The SCM uses 5, 10, then 30 s for the
                      first, second and later failures inside the 24 h reset
                      window, so a second Kill run on the same day measures 10 s.
  -Phase AfterReboot  run by hand after a reboot: seconds from LastBootUpTime
                      (Win32_OperatingSystem) to started_at (/version), plus the
                      sc query state.
  -Phase All          Start, then Kill.

  Every phase appends one line to verify-result.txt (tracked as evidence) and
  writes verify-result.json (the phases of this run). All timing comes from
  polling the endpoints; nothing is guessed from sleeps. Exit 0, or 1 with one
  "ERROR: ..." line. Nothing here deletes files.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Kill', 'AfterReboot', 'All')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
$ResultTxt = Join-Path $Root 'verify-result.txt'
$ResultJson = Join-Path $Root 'verify-result.json'
$PollMs = 100
$StartTimeoutSec = 60
$RecoverTimeoutSec = 90     # 30 s third-failure delay + a full start, with margin

# -- helpers (same .env rules as app/config.py and svc.ps1) ----------------------

function Read-DotEnv {
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

function Get-BaseUrl($cfg) {
    $h = $cfg.HOST
    if ($h -eq '' -or $h -eq '0.0.0.0') { $h = '127.0.0.1' }
    elseif ($h -eq '::') { $h = '[::1]' }
    return "http://${h}:$($cfg.PORT)"
}

function Get-Json($url) {
    # $null when the endpoint does not answer 200 (refused, 503, timeout).
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2
        if ($r.StatusCode -ne 200) { return $null }
        return ($r.Content | ConvertFrom-Json)
    } catch { return $null }
}

function Wait-Until([scriptblock]$condition, [double]$timeoutSec) {
    # Returns @{ Seconds; Value } for the first truthy result, or $null.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $v = & $condition
        if ($v) { return @{ Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); Value = $v } }
        Start-Sleep -Milliseconds $PollMs
    }
    return $null
}

function Get-ServicePid($name) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$name'"
    if (-not $s) { throw "service $name is not installed: run .\svc.ps1 -Step Install" }
    return [int]$s.ProcessId
}

function Get-OsLabel {
    $os = Get-CimInstance Win32_OperatingSystem
    return "$($os.Caption.Trim()) $($os.Version)"
}

function Write-Result($phaseName, $seconds, $detail) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "$stamp | $phaseName | $(Get-OsLabel) | $seconds s | $detail"
    Add-Content -Path $ResultTxt -Value $line -Encoding UTF8
    Write-Host "RESULT: $line"
    $script:Results += [pscustomobject]@{
        timestamp = $stamp; phase = $phaseName; os = (Get-OsLabel)
        seconds = $seconds; detail = $detail
    }
}

function Show-LogTail {
    $log = Join-Path $LogDir 'service.log'
    if (Test-Path $log) {
        Write-Host "---- last 20 lines of $log"
        Get-Content $log -Tail 20 | ForEach-Object { Write-Host "   $_" }
    }
}

# -- phases ----------------------------------------------------------------------

function Phase-Start {
    $cfg = Read-DotEnv; $name = $cfg.SERVICE_NAME; $base = Get-BaseUrl $cfg
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { throw "service $name is not installed: run .\svc.ps1 -Step Install" }
    if ($svc.Status -ne 'Stopped') {
        Write-Host "stopping $name first"
        Stop-Service -Name $name -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
    }
    Write-Host "starting $name"
    # sc start returns as soon as the SCM has launched the process, so the clock
    # covers interpreter start, imports, bind and the first successful poll.
    & sc.exe start $name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc start $name failed with code ${LASTEXITCODE}: see 'sc query $name' and logs\service.log" }
    $hit = Wait-Until { Get-Json "$base/health/ready" } $StartTimeoutSec
    if (-not $hit) {
        & sc.exe query $name
        Show-LogTail
        throw "no 200 from $base/health/ready within $StartTimeoutSec s: see the log tail above (503 means REQUIRED_SETTING is empty)"
    }
    $pid_ = Get-ServicePid $name
    Write-Result 'Start' $hit.Seconds "service start to first 200 from /health/ready; pid $pid_; started_at $($hit.Value.started_at)"
}

function Phase-Kill {
    $cfg = Read-DotEnv; $name = $cfg.SERVICE_NAME; $base = Get-BaseUrl $cfg
    $before = Get-Json "$base/version"
    if (-not $before) { throw "service is not ready at $base/version: run .\verify.ps1 -Phase Start first" }
    $oldPid = Get-ServicePid $name
    if ($oldPid -eq 0) { throw "service $name has no process: run .\verify.ps1 -Phase Start first" }
    Write-Host "killing pid $oldPid (started_at $($before.started_at))"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & taskkill.exe /F /PID $oldPid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "taskkill /F /PID $oldPid failed with code ${LASTEXITCODE}: is this shell elevated?" }
    # A 200 from a process with a different started_at proves a new process answered.
    $hit = Wait-Until {
        $v = Get-Json "$base/version"
        if ($v -and $v.started_at -ne $before.started_at) { $v } else { $null }
    } $RecoverTimeoutSec
    $seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    if (-not $hit) {
        & sc.exe query $name
        & sc.exe qfailure $name
        Show-LogTail
        throw "no new process answered 200 within $RecoverTimeoutSec s after the kill: check 'sc qfailure $name' above (failure actions must be set) and the System event log for service $name"
    }
    $newPid = Get-ServicePid $name
    Write-Result 'Kill' $seconds "taskkill /F to 200 from a new process; pid $oldPid -> $newPid; started_at $($hit.Value.started_at); SCM first-failure delay is 5 s"
}

function Phase-AfterReboot {
    $cfg = Read-DotEnv; $name = $cfg.SERVICE_NAME; $base = Get-BaseUrl $cfg
    $null = Get-ServicePid $name        # fails with a clear message when not installed
    $os = Get-CimInstance Win32_OperatingSystem
    $boot = $os.LastBootUpTime.ToUniversalTime()
    Write-Host "last boot (UTC): $($boot.ToString('o'))"
    $state = (& sc.exe query $name | Select-String 'STATE').Line.Trim()
    Write-Host "sc query: $state"
    # Delayed auto-start begins about two minutes after boot; allow that plus the start itself.
    $hit = Wait-Until { Get-Json "$base/version" } 240
    if (-not $hit) {
        Show-LogTail
        throw "no 200 from $base/version within 240 s after this check began; $state; see logs\service.log and the System event log"
    }
    $startedAt = [DateTimeOffset]::Parse($hit.Value.started_at, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    $seconds = [math]::Round(($startedAt - $boot).TotalSeconds, 2)
    if ($startedAt -lt $boot) {
        throw "started_at $($hit.Value.started_at) is before the last boot: the service was not restarted by this boot; run this phase after a reboot"
    }
    Write-Result 'AfterReboot' $seconds "boot to started_at (delayed auto-start); $state; pid $(Get-ServicePid $name)"
}

# -- main --------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir 'verify.log') -Append | Out-Null
[System.Net.WebRequest]::DefaultWebProxy = $null   # no proxy detection on loopback
$script:Results = @()
$exitCode = 0
try {
    Write-Host "== verify.ps1 -Phase $Phase  ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
    switch ($Phase) {
        'Start'       { Phase-Start }
        'Kill'        { Phase-Kill }
        'AfterReboot' { Phase-AfterReboot }
        'All'         { Phase-Start; Phase-Kill }
    }
    Write-Host "== $Phase done; see $ResultTxt"
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    $exitCode = 1
} finally {
    if ($script:Results.Count -gt 0) {
        ConvertTo-Json -InputObject @($script:Results) -Depth 3 | Set-Content -Path $ResultJson -Encoding UTF8
    }
    Stop-Transcript | Out-Null
}
exit $exitCode
