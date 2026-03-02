[CmdletBinding()]
param(
  [string]$Preset = "local_qwen3_coder_30b",
  [ValidateSet("fast", "fast_live", "normal", "normal_neural", "shark_classic")]
  [string]$RuntimeProfile = "",
  [double]$EvKeepMargin = 0.001,
  [int]$Seed = 4090,
  [int]$MaxSpots = 0,
  [string]$TurnSpotDir = "",
  [string]$RiverSpotDir = "",
  [string]$Output = "",
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot
$BacktestScript = Join-Path $RepoRoot "4_LLM_Bridge\run_true_backtest.py"
if (-not (Test-Path $BacktestScript)) {
  throw "Missing backtest script: $BacktestScript"
}

if ([string]::IsNullOrWhiteSpace($TurnSpotDir)) {
  $TurnSpotDir = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\multinode_class1_spots"
}
if ([string]::IsNullOrWhiteSpace($RiverSpotDir)) {
  $RiverSpotDir = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_river20\spots"
}
if (-not (Test-Path $TurnSpotDir)) { throw "Turn spot dir not found: $TurnSpotDir" }
if (-not (Test-Path $RiverSpotDir)) { throw "River spot dir not found: $RiverSpotDir" }

if ([string]::IsNullOrWhiteSpace($Output)) {
  $Output = Join-Path $RepoRoot "4_LLM_Bridge\examples\backtest.abc.ps1.json"
}

$IsCloudPreset = Get-IsCloudPreset -Preset $Preset
$state = Ensure-TestServices -RepoRoot $RepoRoot -PythonExe $PythonExe -IsCloudPreset:$IsCloudPreset

try {
  $Args = @(
    $BacktestScript,
    "--spot-dir", $TurnSpotDir,
    "--spot-dir", $RiverSpotDir,
    "--preset", $Preset,
    "--modes", "baseline_gto", "class1_live_shadow23", "full_multi_node_benchmark",
    "--ev-keep-margin", "$EvKeepMargin",
    "--seed", "$Seed",
    "--output", $Output
  )
  if (-not [string]::IsNullOrWhiteSpace($RuntimeProfile)) {
    $Args += @("--runtime-profile", $RuntimeProfile)
  }
  if ($MaxSpots -gt 0) {
    $Args += @("--max-spots", "$MaxSpots")
  }

  & $PythonExe @Args
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) { exit $ExitCode }

  if (-not (Test-Path $Output)) {
    throw "Backtest output not produced: $Output"
  }
  $Report = Get-Content $Output -Raw | ConvertFrom-Json
  Write-Host ""
  Write-Host "Backtest A/B/C Summary"
  foreach ($mode in $Report.summaries.PSObject.Properties.Name) {
    $s = $Report.summaries.$mode
    Write-Host ("  {0}: bb100_avg={1}, ev_delta_avg_pct={2}, fallback_rate={3}, keep_rate={4}, p50={5}s, p95={6}s" -f `
      $mode, $s.bb100_avg, $s.ev_delta_avg_pct, $s.fallback_rate, $s.keep_rate, $s.latency_p50_sec, $s.latency_p95_sec)
  }
  Write-Host ("  output={0}" -f $Output)
  exit 0
}
finally {
  if ($StopStartedServices) {
    Stop-TestServices -State $state
  }
}

