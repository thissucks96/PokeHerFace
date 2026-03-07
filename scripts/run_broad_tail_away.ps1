param(
    [switch]$RestartExisting,
    [switch]$NoTail,
    [int]$BridgeStartupSeconds = 5,
    [int]$StaleMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$venvPython = Join-Path $repoRoot ".venv\Scripts\python.exe"
$bridgeScript = Join-Path $repoRoot "4_LLM_Bridge\bridge_server.py"
$labelerScript = Join-Path $repoRoot "scripts\label_reference_offline.py"
$watchdogScript = Join-Path $repoRoot "scripts\watch_offline_labeler_guard.ps1"

$broadTailInput = Join-Path $repoRoot "2_Neural_Brain\local_pipeline\reports\missing_rows_except_flop_p_lt10_f_0_spr_16p.jsonl"
$labelsPath = Join-Path $repoRoot "2_Neural_Brain\local_pipeline\data\raw_spots\solver_reference_labels.jsonl"
$errorsPath = Join-Path $repoRoot "2_Neural_Brain\local_pipeline\reports\offline_label_errors.jsonl"
$manifestPath = Join-Path $repoRoot "2_Neural_Brain\local_pipeline\reports\offline_label_manifest_broad_tail.json"

$bridgeOutLog = Join-Path $repoRoot "logs\broad_tail_bridge.out.log"
$bridgeErrLog = Join-Path $repoRoot "logs\broad_tail_bridge.err.log"
$labelerOutLog = Join-Path $repoRoot "logs\broad_tail_labeler.out.log"
$labelerErrLog = Join-Path $repoRoot "logs\broad_tail_labeler.err.log"
$watchdogOutLog = Join-Path $repoRoot "logs\broad_tail_watchdog.out.log"
$watchdogErrLog = Join-Path $repoRoot "logs\broad_tail_watchdog.err.log"

function Assert-RequiredFile {
    param(
        [string]$Path,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Get-ExistingProcess {
    param(
        [string]$Pattern
    )
    $procs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match "^python(\.exe)?$|^pwsh(\.exe)?$|^powershell(\.exe)?$" -and
        [string]$_.CommandLine -match $Pattern
    }
    if ($null -eq $procs) {
        return @()
    }
    return @($procs)
}

function Stop-ExistingTailWindow {
    param(
        [string]$Path
    )
    $escapedPath = [Regex]::Escape($Path)
    $tailProcs = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match "^pwsh(\.exe)?$|^powershell(\.exe)?$" -and
        [string]$_.CommandLine -match "Get-Content" -and
        [string]$_.CommandLine -match $escapedPath
    }
    foreach ($proc in @($tailProcs)) {
        try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
            Write-Host "Closed existing tail window PID $($proc.ProcessId) for $Path"
        } catch {
            Write-Host "Failed to close existing tail window PID $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Get-WatchdogTargetProcessId {
    param(
        [string]$CommandLine
    )
    $match = [regex]::Match([string]$CommandLine, '(?:^|\s)-ProcessId\s+(\d+)')
    if ($match.Success) {
        return [int]$match.Groups[1].Value
    }
    return 0
}

function Stop-ExistingProcessSet {
    param(
        [string]$Pattern,
        [string]$Label
    )
    $procs = Get-ExistingProcess -Pattern $Pattern
    foreach ($proc in $procs) {
        try {
            Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
            Write-Host "Stopped existing $Label PID $($proc.ProcessId)"
        } catch {
            Write-Host "Failed to stop existing $Label PID $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Rotate-RunLog {
    param(
        [string]$Path,
        [string]$Stamp
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.Length -le 0) {
        return
    }
    $directory = Split-Path -Parent $Path
    $extension = [System.IO.Path]::GetExtension($Path)
    $leafBase = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $archiveName = "$leafBase.$Stamp$extension"
    $archivePath = Join-Path $directory $archiveName
    Move-Item -LiteralPath $Path -Destination $archivePath -Force
    Write-Host "Archived log: $archivePath"
}

function Get-BridgeHealth {
    try {
        return Invoke-RestMethod "http://127.0.0.1:8000/health" -TimeoutSec 5
    } catch {
        return $null
    }
}

function Ensure-Bridge {
    $health = Get-BridgeHealth
    if ($null -ne $health) {
        Write-Host "Bridge already healthy on http://127.0.0.1:8000/health"
        return
    }

    Write-Host "Starting bridge server..."
    Start-Process -FilePath $venvPython -ArgumentList @(
        $bridgeScript
    ) -RedirectStandardOutput $bridgeOutLog -RedirectStandardError $bridgeErrLog -WindowStyle Hidden | Out-Null

    Start-Sleep -Seconds $BridgeStartupSeconds

    $health = Get-BridgeHealth
    if ($null -eq $health) {
        throw "Bridge failed health check after startup."
    }

    Write-Host "Bridge healthy on http://127.0.0.1:8000/health"
}

function Start-VisibleTail {
    param(
        [string]$Title,
        [string]$Path
    )
    Stop-ExistingTailWindow -Path $Path
    $tailCmd = "Set-Location '$repoRoot'; Write-Host '$Title'; if (-not (Test-Path '$Path')) { New-Item -ItemType File -Path '$Path' | Out-Null }; Get-Content '$Path' -Tail 20 -Wait"
    Start-Process -FilePath "pwsh" -ArgumentList @(
        "-NoExit",
        "-Command",
        $tailCmd
    ) | Out-Null
}

Assert-RequiredFile -Path $venvPython -Label "Repo venv python"
Assert-RequiredFile -Path $bridgeScript -Label "Bridge script"
Assert-RequiredFile -Path $labelerScript -Label "Offline labeler script"
Assert-RequiredFile -Path $watchdogScript -Label "Watchdog script"
Assert-RequiredFile -Path $broadTailInput -Label "Broad-tail input JSONL"

New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot "logs") | Out-Null

$existingBridgeHealthy = $null -ne (Get-BridgeHealth)
$existingLabelerBefore = @(Get-ExistingProcess -Pattern "label_reference_offline\.py.*missing_rows_except_flop_p_lt10_f_0_spr_16p\.jsonl")
$existingWatchdogBefore = @(Get-ExistingProcess -Pattern "watch_offline_labeler_guard\.ps1.*offline_label_manifest_broad_tail\.json")
$shouldRotateLogs = $RestartExisting -or (-not $existingBridgeHealthy -and $existingLabelerBefore.Count -eq 0 -and $existingWatchdogBefore.Count -eq 0)

if ($RestartExisting) {
    Stop-ExistingProcessSet -Pattern "bridge_server\.py" -Label "bridge"
    Stop-ExistingProcessSet -Pattern "label_reference_offline\.py.*missing_rows_except_flop_p_lt10_f_0_spr_16p\.jsonl" -Label "broad-tail labeler"
    Stop-ExistingProcessSet -Pattern "watch_offline_labeler_guard\.ps1.*offline_label_manifest_broad_tail\.json" -Label "broad-tail watchdog"
}

if ($shouldRotateLogs) {
    $logStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    foreach ($logPath in @(
        $bridgeOutLog,
        $bridgeErrLog,
        $labelerOutLog,
        $labelerErrLog,
        $watchdogOutLog,
        $watchdogErrLog
    )) {
        Rotate-RunLog -Path $logPath -Stamp $logStamp
    }
}

Ensure-Bridge

$existingLabeler = @(Get-ExistingProcess -Pattern "label_reference_offline\.py.*missing_rows_except_flop_p_lt10_f_0_spr_16p\.jsonl")
if ($existingLabeler.Count -gt 0) {
    $labelerPid = [int]$existingLabeler[0].ProcessId
    Write-Host "Broad-tail labeler already running as PID $labelerPid"
} else {
    Write-Host "Starting broad-tail labeler..."
    $labeler = Start-Process -FilePath $venvPython -ArgumentList @(
        $labelerScript,
        "--input-jsonl", $broadTailInput,
        "--output-jsonl", $labelsPath,
        "--error-jsonl", $errorsPath,
        "--manifest-json", $manifestPath,
        "--runtime-profile", "shark_classic",
        "--timeout-sec", "300",
        "--max-retries", "2",
        "--checkpoint-every", "25",
        "--resume"
    ) -PassThru -RedirectStandardOutput $labelerOutLog -RedirectStandardError $labelerErrLog -WindowStyle Hidden
    $labelerPid = $labeler.Id
    Write-Host "Broad-tail labeler started as PID $labelerPid"
}

$existingWatchdog = @(Get-ExistingProcess -Pattern "watch_offline_labeler_guard\.ps1.*$([Regex]::Escape($manifestPath))")
$reuseWatchdog = $false
if ($existingWatchdog.Count -gt 0) {
    $watchdogTargetPid = Get-WatchdogTargetProcessId -CommandLine ([string]$existingWatchdog[0].CommandLine)
    if ($watchdogTargetPid -eq $labelerPid) {
        $reuseWatchdog = $true
        Write-Host "Broad-tail watchdog already running as PID $($existingWatchdog[0].ProcessId)"
    } else {
        foreach ($watchdogProc in $existingWatchdog) {
            try {
                Stop-Process -Id ([int]$watchdogProc.ProcessId) -Force -ErrorAction Stop
                Write-Host "Stopped stale broad-tail watchdog PID $($watchdogProc.ProcessId) (target was PID $watchdogTargetPid)"
            } catch {
                Write-Host "Failed to stop stale broad-tail watchdog PID $($watchdogProc.ProcessId): $($_.Exception.Message)"
            }
        }
    }
}

if (-not $reuseWatchdog) {
    Write-Host "Starting broad-tail watchdog..."
    $watchdog = Start-Process -FilePath "pwsh" -ArgumentList @(
        "-ExecutionPolicy", "Bypass",
        "-File", $watchdogScript,
        "-ProcessId", $labelerPid,
        "-LabelsPath", $labelsPath,
        "-ErrorsPath", $errorsPath,
        "-ManifestPath", $manifestPath,
        "-StaleMinutes", $StaleMinutes,
        "-Loop"
    ) -PassThru -RedirectStandardOutput $watchdogOutLog -RedirectStandardError $watchdogErrLog -WindowStyle Hidden
    Write-Host "Broad-tail watchdog started as PID $($watchdog.Id)"
}

if (-not $NoTail) {
    Start-VisibleTail -Title "Watching broad-tail labeler progress..." -Path $watchdogOutLog
    Start-VisibleTail -Title "Watching broad-tail labeler errors..." -Path $labelerErrLog
}

Write-Host ""
Write-Host "Broad-tail unattended run is ready."
Write-Host "Input:    $broadTailInput"
Write-Host "Labels:   $labelsPath"
Write-Host "Errors:   $errorsPath"
Write-Host "Manifest: $manifestPath"
Write-Host "Logs:"
Write-Host "  $bridgeOutLog"
Write-Host "  $bridgeErrLog"
Write-Host "  $labelerOutLog"
Write-Host "  $labelerErrLog"
Write-Host "  $watchdogOutLog"
Write-Host "  $watchdogErrLog"
