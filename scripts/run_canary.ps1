[CmdletBinding()]
param(
  [ValidateSet("mini2h", "mini4h", "full48h", "custom")]
  [string]$Profile = "mini2h",
  [double]$DurationHours = 0,
  [int]$MaxCalls = 0,
  [string]$Preset = "local_qwen3_coder_30b",
  [double]$EvKeepMargin = 0.001,
  [int]$SolverTimeoutSec = 900,
  [int]$HttpTimeoutSec = 1200,
  [string]$TurnSpotDir = "",
  [string]$RiverSpotDir = "",
  [double]$GuardrailMaxFallbackRate = 0.0,
  [double]$GuardrailMinKeepRate = 0.90,
  [double]$GuardrailMaxP95LatencySec = 20.0,
  [int]$GuardrailWindowCalls = 50,
  [int]$GuardrailMinCallsBeforeTrip = 20,
  [ValidateSet("baseline_only", "reject")]
  [string]$KillSwitchMode = "baseline_only"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

function Get-PercentileValue {
  param(
    [Parameter(Mandatory = $true)][double[]]$Values,
    [double]$Quantile = 0.95
  )
  $vals = @($Values)
  if (-not $vals -or $vals.Count -eq 0) {
    return $null
  }
  $sorted = @($vals | Sort-Object)
  $sortedCount = @($sorted).Count
  if ($sortedCount -eq 1) {
    return [double]$sorted[0]
  }
  $q = [Math]::Max(0.0, [Math]::Min(1.0, $Quantile))
  $idx = ($sortedCount - 1) * $q
  $lo = [Math]::Floor($idx)
  $hi = [Math]::Ceiling($idx)
  if ($lo -eq $hi) {
    return [double]$sorted[$lo]
  }
  $frac = $idx - $lo
  return ([double]$sorted[$lo] * (1.0 - $frac)) + ([double]$sorted[$hi] * $frac)
}

function Stop-BridgeServerProcesses {
  $bridgeProcs = Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*4_LLM_Bridge\\bridge_server.py*" }
  foreach ($proc in $bridgeProcs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Start-OllamaIfNeeded {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )
  if (Test-Endpoint -Uri "http://127.0.0.1:11434/api/tags") {
    return $false
  }
  Write-Host "Starting Ollama..."
  Start-Process -FilePath "ollama" -ArgumentList "serve" -WorkingDirectory $RepoRoot | Out-Null
  if (-not (Wait-Endpoint -Uri "http://127.0.0.1:11434/api/tags" -Attempts 90 -SleepMs 500)) {
    throw "Failed to start Ollama at http://127.0.0.1:11434"
  }
  return $true
}

function Start-BridgeWithGuardrails {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PythonExe
  )
  Stop-BridgeServerProcesses
  Write-Host "Starting bridge server with canary guardrails..."
  Start-Process -FilePath $PythonExe -ArgumentList (Join-Path $RepoRoot "4_LLM_Bridge\bridge_server.py") -WorkingDirectory $RepoRoot | Out-Null
  if (-not (Wait-Endpoint -Uri "http://127.0.0.1:8000/health" -Attempts 90 -SleepMs 500)) {
    throw "Failed to start bridge server at http://127.0.0.1:8000"
  }
}

function Stop-OllamaStartedByScript {
  $procs = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -like "ollama*" -and $_.CommandLine -like "*serve*" }
  foreach ($proc in $procs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot

if ([string]::IsNullOrWhiteSpace($TurnSpotDir)) {
  $TurnSpotDir = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\multinode_class1_spots"
}
if ([string]::IsNullOrWhiteSpace($RiverSpotDir)) {
  $RiverSpotDir = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_river20\spots"
}
if (-not (Test-Path $TurnSpotDir)) { throw "Turn spot dir not found: $TurnSpotDir" }
if (-not (Test-Path $RiverSpotDir)) { throw "River spot dir not found: $RiverSpotDir" }

switch ($Profile) {
  "mini2h" { if ($DurationHours -le 0) { $DurationHours = 2.0 } }
  "mini4h" { if ($DurationHours -le 0) { $DurationHours = 4.0 } }
  "full48h" { if ($DurationHours -le 0) { $DurationHours = 48.0 } }
  "custom" {
    if ($DurationHours -le 0) {
      throw "When -Profile custom is used, -DurationHours must be > 0."
    }
  }
}

if ($DurationHours -le 0) {
  throw "Invalid duration. Use -DurationHours > 0."
}

$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$runDir = Join-Path $RepoRoot ("4_LLM_Bridge\examples\canary_runs\canary.{0}.{1}" -f $timestamp, $Profile)
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$recordsNdjson = Join-Path $runDir "records.ndjson"
$summaryPath = Join-Path $runDir "summary.json"
$snapshotPath = Join-Path $runDir "config_snapshot.json"
$envSnapshotPath = Join-Path $runDir ".env.snapshot"

$gitHash = (git rev-parse HEAD).Trim()
$gitBranch = (git rev-parse --abbrev-ref HEAD).Trim()
$bridgeEnvPath = Join-Path $RepoRoot "4_LLM_Bridge\.env"
if (Test-Path $bridgeEnvPath) {
  Copy-Item -Path $bridgeEnvPath -Destination $envSnapshotPath -Force
}

$configSnapshot = [ordered]@{
  generated_at = (Get-Date).ToString("o")
  repo_root = $RepoRoot
  git_hash = $gitHash
  git_branch = $gitBranch
  profile = $Profile
  duration_hours = $DurationHours
  max_calls = $MaxCalls
  preset = $Preset
  ev_keep_margin = $EvKeepMargin
  solver_timeout_sec = $SolverTimeoutSec
  http_timeout_sec = $HttpTimeoutSec
  turn_spot_dir = $TurnSpotDir
  river_spot_dir = $RiverSpotDir
  guardrails = [ordered]@{
    enabled = $true
    max_fallback_rate = $GuardrailMaxFallbackRate
    min_keep_rate = $GuardrailMinKeepRate
    max_p95_latency_sec = $GuardrailMaxP95LatencySec
    window_calls = $GuardrailWindowCalls
    min_calls_before_trip = $GuardrailMinCallsBeforeTrip
    kill_switch_mode = $KillSwitchMode
  }
  env_snapshot_copied = (Test-Path $envSnapshotPath)
}
$configSnapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $snapshotPath -Encoding UTF8

$startedOllama = $false
try {
  $startedOllama = Start-OllamaIfNeeded -RepoRoot $RepoRoot

  # Guardrail env for this bridge process.
  $env:CANARY_GUARDRAILS_ENABLED = "1"
  $env:CANARY_MAX_FALLBACK_RATE = "$GuardrailMaxFallbackRate"
  $env:CANARY_MIN_KEEP_RATE = "$GuardrailMinKeepRate"
  $env:CANARY_MAX_P95_LATENCY_SEC = "$GuardrailMaxP95LatencySec"
  $env:CANARY_WINDOW_CALLS = "$GuardrailWindowCalls"
  $env:CANARY_MIN_CALLS_BEFORE_TRIP = "$GuardrailMinCallsBeforeTrip"
  $env:CANARY_KILL_SWITCH_MODE = "$KillSwitchMode"
  $env:CANARY_AUTO_EXIT_ON_TRIP = "0"

  Start-BridgeWithGuardrails -RepoRoot $RepoRoot -PythonExe $PythonExe

  $turnSpots = @(Get-ChildItem -Path $TurnSpotDir -Filter "*.json" -File | Select-Object -ExpandProperty FullName)
  $riverSpots = @(Get-ChildItem -Path $RiverSpotDir -Filter "*.json" -File | Select-Object -ExpandProperty FullName)
  $spotFiles = @($turnSpots + $riverSpots)
  if ($spotFiles.Count -eq 0) {
    throw "No spot files found across turn/river directories."
  }

  $start = Get-Date
  $deadline = $start.AddHours($DurationHours)
  $callCount = 0
  $httpOk = 0
  $fallbackCount = 0
  $keepCount = 0
  $latencies = New-Object System.Collections.Generic.List[Double]
  $alerts = New-Object System.Collections.Generic.List[String]
  $records = New-Object System.Collections.Generic.List[Object]
  $spotIndex = 0
  $canaryTripped = $false
  $tripReason = ""

  Write-Host ("Canary run started: profile={0}, duration_hours={1}, run_dir={2}" -f $Profile, $DurationHours, $runDir)

  while ((Get-Date) -lt $deadline) {
    if ($MaxCalls -gt 0 -and $callCount -ge $MaxCalls) {
      break
    }
    $spotPath = $spotFiles[$spotIndex % $spotFiles.Count]
    $spotIndex += 1
    $spotPayload = Get-Content -Path $spotPath -Raw | ConvertFrom-Json

    $payload = [ordered]@{
      spot = $spotPayload
      timeout_sec = $SolverTimeoutSec
      quiet = $true
      auto_select_best = $true
      ev_keep_margin = $EvKeepMargin
      llm = @{
        preset = $Preset
        mode = "canary"
      }
      enable_multi_node_locks = $true
    }
    if ($spotPayload.meta -and $spotPayload.meta.opponent_profile) {
      $payload.opponent_profile = $spotPayload.meta.opponent_profile
    }

    $callStarted = Get-Date
    $statusCode = 200
    $fallback = $false
    $kept = $false
    $selected = ""
    $llmError = $null
    $lockApplied = $false
    $lockTargets = 0
    $callError = $null
    $resp = $null

    try {
      $resp = Invoke-RestMethod `
        -Method Post `
        -Uri "http://127.0.0.1:8000/solve" `
        -TimeoutSec $HttpTimeoutSec `
        -ContentType "application/json" `
        -Body ($payload | ConvertTo-Json -Depth 100 -Compress)
      $httpOk += 1
      $selected = [string]$resp.selected_strategy
      $kept = [bool]$resp.node_lock_kept
      $llmError = $resp.metrics.llm_error
      $fallback = [bool]$llmError
      $lockApplied = [bool]$resp.metrics.lock_applied
      $lockTargets = [int]$resp.metrics.node_lock_target_count
      if ($kept) { $keepCount += 1 }
      if ($fallback) { $fallbackCount += 1 }
      $hasCanary = $resp.PSObject.Properties.Name -contains "canary_guardrails"
      if ($hasCanary -and $resp.canary_guardrails -and $resp.canary_guardrails.state -and $resp.canary_guardrails.state.tripped) {
        $canaryTripped = $true
        $tripReason = [string]$resp.canary_guardrails.state.trip_reason
      }
    }
    catch {
      $statusCode = 500
      $fallback = $true
      $fallbackCount += 1
      $callError = $_.Exception.Message
    }

    $callElapsed = ((Get-Date) - $callStarted).TotalSeconds
    $latencies.Add([double]$callElapsed)
    $callCount += 1

    $record = [ordered]@{
      idx = $callCount
      ts = (Get-Date).ToString("o")
      spot = $spotPath
      status_code = $statusCode
      selected_strategy = $selected
      node_lock_kept = $kept
      fallback = $fallback
      lock_applied = $lockApplied
      node_lock_target_count = $lockTargets
      llm_error = $llmError
      call_error = $callError
      wall_time_sec = $callElapsed
    }
    $records.Add([pscustomobject]$record) | Out-Null
    Add-Content -Path $recordsNdjson -Value (($record | ConvertTo-Json -Compress))

    $fallbackRate = if ($callCount -gt 0) { $fallbackCount / $callCount } else { 0.0 }
    $keepRate = if ($callCount -gt 0) { $keepCount / $callCount } else { 0.0 }
    $latencyP95 = Get-PercentileValue -Values $latencies.ToArray() -Quantile 0.95

    Write-Host ("[{0}] calls={1} ok={2} keep={3:N3} fallback={4:N3} p95={5:N2}s spot={6}" -f `
      (Get-Date).ToString("HH:mm:ss"), $callCount, $httpOk, $keepRate, $fallbackRate, $latencyP95, (Split-Path $spotPath -Leaf))

    if ($canaryTripped) {
      Write-Host ("Canary kill switch tripped by bridge: {0}" -f $tripReason)
      break
    }
  }

  $finished = Get-Date
  $durationSec = ($finished - $start).TotalSeconds
  $fallbackRateFinal = if ($callCount -gt 0) { $fallbackCount / $callCount } else { 0.0 }
  $keepRateFinal = if ($callCount -gt 0) { $keepCount / $callCount } else { 0.0 }
  $latencyP95Final = if ($latencies.Count -gt 0) { Get-PercentileValue -Values $latencies.ToArray() -Quantile 0.95 } else { $null }

  if ($fallbackRateFinal -gt $GuardrailMaxFallbackRate) {
    $alerts.Add(("fallback_rate_exceeded: {0:N4} > {1:N4}" -f $fallbackRateFinal, $GuardrailMaxFallbackRate)) | Out-Null
  }
  if ($keepRateFinal -lt $GuardrailMinKeepRate) {
    $alerts.Add(("keep_rate_below_min: {0:N4} < {1:N4}" -f $keepRateFinal, $GuardrailMinKeepRate)) | Out-Null
  }
  if ($latencyP95Final -ne $null -and $latencyP95Final -gt $GuardrailMaxP95LatencySec) {
    $alerts.Add(("latency_p95_exceeded: {0:N2}s > {1:N2}s" -f $latencyP95Final, $GuardrailMaxP95LatencySec)) | Out-Null
  }
  if ($canaryTripped) {
    $alerts.Add(("bridge_kill_switch_tripped: {0}" -f $tripReason)) | Out-Null
  }

  $health = $null
  try {
    $health = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:8000/health" -TimeoutSec 10
  }
  catch {
    $health = @{ status = "unreachable_after_run" }
  }

  $summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    profile = $Profile
    run_dir = $runDir
    preset = $Preset
    duration_hours_target = $DurationHours
    duration_sec_actual = $durationSec
    call_count = $callCount
    http_ok = $httpOk
    fallback_rate = $fallbackRateFinal
    keep_rate = $keepRateFinal
    latency_p95_sec = $latencyP95Final
    ev_keep_margin = $EvKeepMargin
    guardrails = [ordered]@{
      max_fallback_rate = $GuardrailMaxFallbackRate
      min_keep_rate = $GuardrailMinKeepRate
      max_p95_latency_sec = $GuardrailMaxP95LatencySec
      window_calls = $GuardrailWindowCalls
      min_calls_before_trip = $GuardrailMinCallsBeforeTrip
      kill_switch_mode = $KillSwitchMode
      bridge_tripped = $canaryTripped
      bridge_trip_reason = $tripReason
    }
    alerts = @($alerts)
    pass = ($alerts.Count -eq 0)
    config_snapshot = $snapshotPath
    env_snapshot = if (Test-Path $envSnapshotPath) { $envSnapshotPath } else { $null }
    health = $health
  }
  $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryPath -Encoding UTF8

  Write-Host ""
  Write-Host "Canary Summary"
  Write-Host ("  pass={0}" -f [bool]$summary.pass)
  Write-Host ("  calls={0} ok={1}" -f $summary.call_count, $summary.http_ok)
  Write-Host ("  fallback_rate={0}" -f $summary.fallback_rate)
  Write-Host ("  keep_rate={0}" -f $summary.keep_rate)
  Write-Host ("  latency_p95_sec={0}" -f $summary.latency_p95_sec)
  Write-Host ("  alerts={0}" -f (($summary.alerts -join "; ")))
  Write-Host ("  summary={0}" -f $summaryPath)
}
finally {
  # Always stop bridge process started for canary run.
  Stop-BridgeServerProcesses
  if ($startedOllama) {
    Stop-OllamaStartedByScript
  }
}
