[CmdletBinding()]
param(
  [string[]]$Presets = @("openai_5mini", "openai_52"),
  [int]$CallsPerModel = 10,
  [string]$SpotPath = "",
  [double]$EvKeepMargin = 0.001,
  [bool]$EnableMultiNodeLocks = $true,
  [string]$Output = "",
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

function New-CallPayload {
  param(
    [Parameter(Mandatory = $true)][object]$Spot,
    [Parameter(Mandatory = $true)][string]$Preset,
    [Parameter(Mandatory = $true)][double]$EvKeepMargin,
    [Parameter(Mandatory = $true)][bool]$EnableMultiNodeLocks
  )
  return @{
    spot = $Spot
    timeout_sec = 900
    quiet = $true
    ev_keep_margin = $EvKeepMargin
    enable_multi_node_locks = $EnableMultiNodeLocks
    llm = @{
      preset = $Preset
      mode = "benchmark"
    }
  }
}

function Get-ModelSummary {
  param(
    [Parameter(Mandatory = $true)][object[]]$Rows
  )
  $ok = @($Rows | Where-Object { $_.status_code -eq 200 })
  if ($ok.Count -eq 0) {
    return @{
      calls = $Rows.Count
      ok_calls = 0
    }
  }

  $fallbackRate = (@($ok | Where-Object { $_.selected_strategy -eq "baseline_gto" }).Count) / [double]$ok.Count
  $keepRate = (@($ok | Where-Object { $_.node_lock_kept -eq $true }).Count) / [double]$ok.Count
  $lockAppliedRate = (@($ok | Where-Object { $_.lock_applied -eq $true }).Count) / [double]$ok.Count
  $candGenAvg = ($ok | Measure-Object -Property llm_candidate_generated_count -Average).Average
  $candSolveAvg = ($ok | Measure-Object -Property llm_candidate_solve_count -Average).Average
  $llmAvg = ($ok | Measure-Object -Property llm_time_sec -Average).Average
  $solverAvg = ($ok | Measure-Object -Property solver_time_sec -Average).Average
  $bridgeAvg = ($ok | Measure-Object -Property total_bridge_time_sec -Average).Average

  return @{
    calls = $Rows.Count
    ok_calls = $ok.Count
    fallback_rate = [double]$fallbackRate
    keep_rate = [double]$keepRate
    lock_applied_rate = [double]$lockAppliedRate
    llm_candidate_generated_avg = if ($null -ne $candGenAvg) { [double]$candGenAvg } else { $null }
    llm_candidate_solve_avg = if ($null -ne $candSolveAvg) { [double]$candSolveAvg } else { $null }
    llm_time_avg_sec = if ($null -ne $llmAvg) { [double]$llmAvg } else { $null }
    solver_time_avg_sec = if ($null -ne $solverAvg) { [double]$solverAvg } else { $null }
    total_bridge_time_avg_sec = if ($null -ne $bridgeAvg) { [double]$bridgeAvg } else { $null }
  }
}

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot

if ([string]::IsNullOrWhiteSpace($SpotPath)) {
  $SpotPath = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\spots\spot_01.spot.poker_hand_histories_dwan_ivey_2009.77fa0279b8.turn.two_tone.unknown.unknown.json"
}
if (-not (Test-Path $SpotPath)) {
  throw "Spot file not found: $SpotPath"
}

$allCloud = $true
foreach ($preset in $Presets) {
  if (-not (Get-IsCloudPreset -Preset $preset)) {
    $allCloud = $false
    break
  }
}
$state = Ensure-TestServices -RepoRoot $RepoRoot -PythonExe $PythonExe -IsCloudPreset:$allCloud

try {
  $endpoint = "http://127.0.0.1:8000/solve"
  $spot = Get-Content $SpotPath -Raw | ConvertFrom-Json
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $RepoRoot ("4_LLM_Bridge\examples\benchmark.api_progress.{0}.json" -f $stamp)
  }

  $report = @{
    endpoint = $endpoint
    spot = $SpotPath
    calls_per_model_requested = $CallsPerModel
    ev_keep_margin = $EvKeepMargin
    enable_multi_node_locks = [bool]$EnableMultiNodeLocks
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    models = @{}
  }

  foreach ($preset in $Presets) {
    $isCloud = Get-IsCloudPreset -Preset $preset
    $effectiveCalls = $CallsPerModel
    if ($isCloud -and $effectiveCalls -gt 10) {
      Write-Host ("[{0}] calls-per-model capped from {1} to 10 for cloud preset" -f $preset, $effectiveCalls) -ForegroundColor Yellow
      $effectiveCalls = 10
    }
    if ($effectiveCalls -lt 1) {
      $effectiveCalls = 1
    }

    Write-Host ""
    Write-Host ("==> Preset: {0} ({1} calls)" -f $preset, $effectiveCalls) -ForegroundColor Cyan
    $rows = @()
    $swModel = [System.Diagnostics.Stopwatch]::StartNew()

    for ($i = 1; $i -le $effectiveCalls; $i++) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $payload = New-CallPayload -Spot $spot -Preset $preset -EvKeepMargin $EvKeepMargin -EnableMultiNodeLocks $EnableMultiNodeLocks
      try {
        $resp = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 100) -TimeoutSec 1800
        $sw.Stop()
        $m = $resp.metrics
        $row = [pscustomobject][ordered]@{
          call = $i
          status_code = 200
          request_wall_time_sec = [double]$sw.Elapsed.TotalSeconds
          selected_strategy = $resp.selected_strategy
          node_lock_kept = [bool]$resp.node_lock_kept
          lock_applied = [bool]$m.lock_applied
          llm_error = $m.llm_error
          llm_candidate_mode_enabled = [bool]$m.llm_candidate_mode_enabled
          llm_candidate_generated_count = [int]$m.llm_candidate_generated_count
          llm_candidate_solve_count = [int]$m.llm_candidate_solve_count
          llm_time_sec = [double]$m.llm_time_sec
          solver_time_sec = [double]$m.solver_time_sec
          total_bridge_time_sec = [double]$m.total_bridge_time_sec
          final_exploitability_pct = $m.final_exploitability_pct
        }
        $rows += $row

        Write-Host ("[{0}/{1}] {2} sel={3} keep={4} applied={5} cand={6}/{7} llm={8:N3}s solver={9:N3}s" -f `
          $i, $effectiveCalls, $preset, $row.selected_strategy, $row.node_lock_kept, $row.lock_applied, `
          $row.llm_candidate_generated_count, $row.llm_candidate_solve_count, $row.llm_time_sec, $row.solver_time_sec)
      }
      catch {
        $sw.Stop()
        $row = [pscustomobject][ordered]@{
          call = $i
          status_code = 0
          request_wall_time_sec = [double]$sw.Elapsed.TotalSeconds
          error = $_.Exception.Message
        }
        $rows += $row
        Write-Host ("[{0}/{1}] {2} ERROR {3}" -f $i, $effectiveCalls, $preset, $_.Exception.Message) -ForegroundColor Red
      }

      $summary = Get-ModelSummary -Rows $rows
      $elapsed = $swModel.Elapsed.TotalSeconds
      $avgPerCall = if ($rows.Count -gt 0) { $elapsed / $rows.Count } else { 0.0 }
      $remaining = [Math]::Max(0, $effectiveCalls - $rows.Count)
      $etaSec = $avgPerCall * $remaining
      $candGenAvgDisplay = if ($null -ne $summary.llm_candidate_generated_avg) { $summary.llm_candidate_generated_avg } else { 0.0 }
      Write-Host ("    roll: ok={0}/{1} fallback={2:P1} keep={3:P1} lock={4:P1} cand_gen_avg={5:N2} eta={6:N1}s" -f `
        $summary.ok_calls, $summary.calls, $summary.fallback_rate, $summary.keep_rate, $summary.lock_applied_rate, `
        $candGenAvgDisplay, $etaSec) -ForegroundColor DarkGray
    }

    $report.models[$preset] = @{
      calls_per_model_effective = $effectiveCalls
      provider = if ($isCloud) { "openai" } else { "local" }
      summary = (Get-ModelSummary -Rows $rows)
      records = $rows
    }
  }

  $reportJson = $report | ConvertTo-Json -Depth 100
  $outDir = Split-Path -Parent $Output
  if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  Set-Content -Path $Output -Value $reportJson -Encoding UTF8

  Write-Host ""
  Write-Host ("Report written: {0}" -f $Output) -ForegroundColor Green
  exit 0
}
finally {
  if ($StopStartedServices) {
    Stop-TestServices -State $state
  }
}
