param(
    [string]$Preset = "local_qwen3_coder_30b",
    [string]$CanonicalManifest = "",
    [string]$Output = "",
    [string]$Details = "",
    [double]$EvKeepMargin = 0.001,
    [int]$CallsPerSpot = 1,
    [int]$NoiseRuns = 1,
    [double]$FallbackMax = 0.05,
    [double]$LockAppliedMin = 0.95,
    [double]$KeepRateMin = 0.000001,
    [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PythonExe = Join-Path $RepoRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $PythonExe)) {
    $PythonExe = "python"
}

$GateScript = Join-Path $RepoRoot "4_LLM_Bridge\run_acceptance_gate.py"
if (-not (Test-Path $GateScript)) {
    throw "Missing gate script: $GateScript"
}

if ([string]::IsNullOrWhiteSpace($CanonicalManifest)) {
    $CanonicalManifest = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\canonical_manifest.json"
}
if (-not (Test-Path $CanonicalManifest)) {
    throw "Canonical manifest not found: $CanonicalManifest"
}

if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\acceptance_summary.ci.json"
}
if ([string]::IsNullOrWhiteSpace($Details)) {
    $Details = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\acceptance_records.ci.json"
}

function Test-Endpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 3
    )
    try {
        Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec $TimeoutSec | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Wait-Endpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSec = 3,
        [int]$Attempts = 30,
        [int]$SleepMs = 500
    )
    for ($i = 0; $i -lt $Attempts; $i++) {
        if (Test-Endpoint -Uri $Uri -TimeoutSec $TimeoutSec) {
            return $true
        }
        Start-Sleep -Milliseconds $SleepMs
    }
    return $false
}

$IsCloudPreset = $Preset -like "openai*"
$StartedOllama = $false
$StartedBridge = $false

if (-not $IsCloudPreset) {
    if (-not (Test-Endpoint -Uri "http://127.0.0.1:11434/api/tags")) {
        Write-Host "Starting Ollama..."
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WorkingDirectory $RepoRoot | Out-Null
        if (-not (Wait-Endpoint -Uri "http://127.0.0.1:11434/api/tags" -Attempts 60 -SleepMs 500)) {
            throw "Failed to start Ollama at http://127.0.0.1:11434"
        }
        $StartedOllama = $true
    }
}

if (-not (Test-Endpoint -Uri "http://127.0.0.1:8000/health")) {
    Write-Host "Starting bridge server..."
    Start-Process -FilePath $PythonExe -ArgumentList (Join-Path $RepoRoot "4_LLM_Bridge\bridge_server.py") -WorkingDirectory $RepoRoot | Out-Null
    if (-not (Wait-Endpoint -Uri "http://127.0.0.1:8000/health" -Attempts 40 -SleepMs 500)) {
        throw "Failed to start bridge server at http://127.0.0.1:8000"
    }
    $StartedBridge = $true
}

$GateArgs = @(
    $GateScript,
    "--canonical-manifest", $CanonicalManifest,
    "--preset", $Preset,
    "--calls-per-spot", "$CallsPerSpot",
    "--ev-keep-margin", "$EvKeepMargin",
    "--calibrate-noise-runs", "$NoiseRuns",
    "--fallback-max", "$FallbackMax",
    "--lock-applied-min", "$LockAppliedMin",
    "--keep-rate-min", "$KeepRateMin",
    "--output", $Output,
    "--details", $Details
)

& $PythonExe @GateArgs
$GateExit = $LASTEXITCODE

if (-not (Test-Path $Output)) {
    throw "Acceptance summary not produced: $Output"
}

$Summary = Get-Content $Output -Raw | ConvertFrom-Json
$FallbackRate = [double]$Summary.fallback_rate
$LockAppliedRate = [double]$Summary.lock_applied_rate
$KeepRate = [double]$Summary.keep_rate
$Pass = [bool]$Summary.pass

$CiPass = $Pass -and
    ($GateExit -eq 0) -and
    ($FallbackRate -le $FallbackMax) -and
    ($LockAppliedRate -ge $LockAppliedMin) -and
    ($KeepRate -gt $KeepRateMin)

if ($StopStartedServices) {
    if ($StartedBridge) {
        Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*4_LLM_Bridge\\bridge_server.py*" } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    if ($StartedOllama) {
        Get-CimInstance Win32_Process | Where-Object { $_.Name -like "ollama*" -and $_.CommandLine -like "*serve*" } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $CiPass) {
    Write-Host "CI gate FAILED"
    Write-Host ("  fallback_rate={0} (max {1})" -f $FallbackRate, $FallbackMax)
    Write-Host ("  lock_applied_rate={0} (min {1})" -f $LockAppliedRate, $LockAppliedMin)
    Write-Host ("  keep_rate={0} (min > {1})" -f $KeepRate, $KeepRateMin)
    exit 1
}

Write-Host "CI gate PASSED"
Write-Host ("  fallback_rate={0}" -f $FallbackRate)
Write-Host ("  lock_applied_rate={0}" -f $LockAppliedRate)
Write-Host ("  keep_rate={0}" -f $KeepRate)
exit 0
