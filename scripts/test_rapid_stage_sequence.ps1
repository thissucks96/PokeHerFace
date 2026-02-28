[CmdletBinding()]
param(
  [string]$Preset = "local_qwen3_coder_30b",
  [ValidateSet("fast", "fast_live", "normal")]
  [string]$RuntimeProfile = "fast",
  [double]$StaggerMs = 150,
  [int]$SolverTimeout = 180,
  [double]$HttpTimeout = 240,
  [switch]$EnableMultiNodeLocks,
  [string]$Output = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot

if ([string]::IsNullOrWhiteSpace($Output)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $Output = Join-Path $RepoRoot ("4_LLM_Bridge\examples\synthetic_hands\rapid_stage_sequence.{0}.json" -f $stamp)
}

$IsCloudPreset = Get-IsCloudPreset -Preset $Preset
$state = Ensure-TestServices -RepoRoot $RepoRoot -PythonExe $PythonExe -IsCloudPreset:$IsCloudPreset

$packPath = Join-Path $RepoRoot "4_LLM_Bridge\examples\synthetic_hands\ten_hand_progression.json"
if (-not (Test-Path $packPath)) {
  throw "Synthetic pack not found: $packPath"
}

function Get-SyntheticPoint {
  param(
    [Parameter(Mandatory = $true)][object]$Pack,
    [Parameter(Mandatory = $true)][string]$HandId,
    [Parameter(Mandatory = $true)][int]$PointIndex
  )

  $hand = @($Pack.hands | Where-Object { [string]$_.hand_id -eq $HandId } | Select-Object -First 1)
  if ($hand.Count -eq 0) {
    throw "Synthetic hand not found: $HandId"
  }
  $points = @($hand[0].decision_points)
  if ($PointIndex -lt 1 -or $PointIndex -gt $points.Count) {
    throw "Synthetic point $PointIndex missing for hand $HandId"
  }
  return $points[$PointIndex - 1]
}

function Start-BridgeSolveJob {
  param(
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][object]$RequestPayload,
    [Parameter(Mandatory = $true)][double]$RequestTimeoutSec,
    [Parameter(Mandatory = $true)][string]$Label
  )

  $json = $RequestPayload | ConvertTo-Json -Depth 20
  $queued = Get-Date
  $job = Start-Job -Name ("rapid_{0}_{1}" -f $Label, $queued.ToString("HHmmssfff")) -ArgumentList @(
    $Endpoint,
    $json,
    [double]$RequestTimeoutSec,
    $Label,
    $queued.ToUniversalTime().ToString("o")
  ) -ScriptBlock {
    param($endpoint, $requestJson, $requestTimeoutSec, $label, $queuedUtcIso)
    $started = Get-Date
    try {
      $resp = Invoke-RestMethod -Uri ([string]$endpoint) -Method Post -ContentType "application/json" -Body ([string]$requestJson) -TimeoutSec ([int][Math]::Ceiling([double]$requestTimeoutSec))
      $elapsed = ((Get-Date) - $started).TotalSeconds
      [pscustomobject]@{
        ok = $true
        label = [string]$label
        queued_utc = [string]$queuedUtcIso
        started_utc = $started.ToUniversalTime().ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        elapsed_sec = [double]$elapsed
        selected_strategy = if ($resp.PSObject.Properties.Name -contains "selected_strategy") { [string]$resp.selected_strategy } else { "" }
        selection_reason = if ($resp.PSObject.Properties.Name -contains "selection_reason") { [string]$resp.selection_reason } else { "" }
        node_lock_kept = if ($resp.PSObject.Properties.Name -contains "node_lock_kept") { [bool]$resp.node_lock_kept } else { $null }
        llm_error = if ($resp.PSObject.Properties.Name -contains "llm_error" -and $resp.llm_error) { [string]$resp.llm_error } else { "" }
        metrics = if ($resp.PSObject.Properties.Name -contains "metrics") { $resp.metrics } else { $null }
      }
    }
    catch {
      [pscustomobject]@{
        ok = $false
        label = [string]$label
        queued_utc = [string]$queuedUtcIso
        started_utc = $started.ToUniversalTime().ToString("o")
        completed_utc = (Get-Date).ToUniversalTime().ToString("o")
        elapsed_sec = [double](((Get-Date) - $started).TotalSeconds)
        error = $_.Exception.Message
      }
    }
  }

  return [pscustomobject]@{
    job = $job
    label = $Label
    queued = $queued
    request_json = $json
  }
}

try {
  $pack = Get-Content -Path $packPath -Raw | ConvertFrom-Json
  $sequence = @(
    [ordered]@{
      label = "flop"
      hand_id = "H01_BTN_vs_BB_top_pair"
      point_index = 1
    },
    [ordered]@{
      label = "turn"
      hand_id = "H01_BTN_vs_BB_top_pair"
      point_index = 2
    },
    [ordered]@{
      label = "river"
      hand_id = "H05_BTN_bluffcatch_river"
      point_index = 2
    }
  )

  $endpoint = "http://127.0.0.1:8000/solve"
  $jobs = @()
  $runStarted = Get-Date

  foreach ($item in $sequence) {
    $point = Get-SyntheticPoint -Pack $pack -HandId ([string]$item.hand_id) -PointIndex ([int]$item.point_index)
    $request = [ordered]@{
      spot = $point.engine_spot
      timeout_sec = [int]$SolverTimeout
      quiet = $true
      runtime_profile = [string]$RuntimeProfile
      llm = [ordered]@{
        preset = [string]$Preset
      }
    }
    if ($EnableMultiNodeLocks) {
      $request.enable_multi_node_locks = $true
    }

    $startedJob = Start-BridgeSolveJob -Endpoint $endpoint -RequestPayload $request -RequestTimeoutSec $HttpTimeout -Label ([string]$item.label)
    $jobs += $startedJob
    Write-Host ("queued {0} from {1} point={2}" -f [string]$item.label, [string]$item.hand_id, [int]$item.point_index)
    if ($StaggerMs -gt 0) {
      Start-Sleep -Milliseconds ([int][Math]::Round($StaggerMs))
    }
  }

  $results = @()
  foreach ($entry in $jobs) {
    $job = $entry.job
    Wait-Job -Id $job.Id | Out-Null
    $payload = @(Receive-Job -Id $job.Id) | Select-Object -First 1
    Remove-Job -Id $job.Id -Force -ErrorAction SilentlyContinue
    $results += $payload
    if ($payload.ok) {
      Write-Host ("done {0} wall={1:N2}s selected={2} reason={3}" -f $payload.label, [double]$payload.elapsed_sec, [string]$payload.selected_strategy, [string]$payload.selection_reason)
    }
    else {
      Write-Host ("fail {0} wall={1:N2}s err={2}" -f $payload.label, [double]$payload.elapsed_sec, [string]$payload.error)
    }
  }

  $runEnded = Get-Date
  $okCount = @($results | Where-Object { $_.ok }).Count
  $failCount = $results.Count - $okCount
  $elapsedValues = @($results | ForEach-Object { [double]$_.elapsed_sec })
  $summary = [ordered]@{
    schema_version = "rapid_stage_sequence.v1"
    generated_at_utc = [DateTime]::UtcNow.ToString("o")
    run_config = [ordered]@{
      preset = $Preset
      runtime_profile = $RuntimeProfile
      stagger_ms = [double]$StaggerMs
      solver_timeout_sec = [int]$SolverTimeout
      http_timeout_sec = [double]$HttpTimeout
      enable_multi_node_locks = [bool]$EnableMultiNodeLocks
    }
    coverage = [ordered]@{
      queued = $results.Count
      ok = $okCount
      fail = $failCount
      total_wall_time_sec = [double](($runEnded - $runStarted).TotalSeconds)
      max_request_wall_sec = if ($elapsedValues.Count -gt 0) { [double]($elapsedValues | Measure-Object -Maximum).Maximum } else { $null }
      avg_request_wall_sec = if ($elapsedValues.Count -gt 0) { [double]($elapsedValues | Measure-Object -Average).Average } else { $null }
    }
    results = @($results)
  }

  $outDir = Split-Path -Parent $Output
  if ($outDir -and (-not (Test-Path $outDir))) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
  }
  $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $Output -Encoding UTF8
  $queuedCount = [int]$results.Count
  $totalWall = [double](($runEnded - $runStarted).TotalSeconds)
  $maxReq = if ($elapsedValues.Count -gt 0) { [double](($elapsedValues | Measure-Object -Maximum).Maximum) } else { 0.0 }
  $avgReq = if ($elapsedValues.Count -gt 0) { [double](($elapsedValues | Measure-Object -Average).Average) } else { 0.0 }
  Write-Host ("Rapid stage sequence report written: {0}" -f $Output)
  Write-Host ("Summary: queued={0} ok={1} fail={2} total_wall={3:N2}s max_req={4:N2}s avg_req={5:N2}s" -f `
      $queuedCount, [int]$okCount, [int]$failCount, $totalWall, $maxReq, $avgReq)
}
finally {
  # Keep services running by default; this is primarily a profiling helper.
}
