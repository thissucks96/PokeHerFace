[CmdletBinding()]
param(
  [string]$Preset = "local_qwen3_coder_30b",
  [string]$ProfileName = "fast_edge_v1",
  [ValidateSet("fast", "normal")]
  [string]$RuntimeProfile = "fast",
  [double]$EvKeepMargin = 0.001,
  [int]$TurnCandidateCount = 1,
  [int]$RiverCandidateCount = 1,
  [int]$TurnMaxTargets = 1,
  [int]$RiverMaxTargets = 1,
  [double]$RootCheckFloor = 0.50,
  [int]$BacktestSeed = 4090,
  [int]$BacktestMaxSpots = 40,
  [switch]$NoSpotOpponentProfile,
  [switch]$RestartServices,
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

function Stop-BridgeProcess {
  Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like "*4_LLM_Bridge\\bridge_server.py*" } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OllamaServeProcess {
  Get-CimInstance Win32_Process |
    Where-Object { $_.Name -like "ollama*" -and $_.CommandLine -like "*serve*" } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$OutputRoot = Join-Path $RepoRoot "4_LLM_Bridge\examples\fast_profile_runs"
$RunTs = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $OutputRoot ("{0}.{1}" -f $ProfileName, $RunTs)
$null = New-Item -ItemType Directory -Path $RunDir -Force

if ($RestartServices) {
  Write-Host "Restarting bridge + Ollama so profile env is applied cleanly..."
  Stop-BridgeProcess
  Stop-OllamaServeProcess
}

$env:EV_KEEP_MARGIN = [string]$EvKeepMargin
$env:RUNTIME_PROFILE_DEFAULT = [string]$RuntimeProfile
$env:TURN_CANDIDATE_COUNT = [string]$TurnCandidateCount
$env:RIVER_CANDIDATE_COUNT = [string]$RiverCandidateCount
$env:TURN_MAX_TARGETS = [string]$TurnMaxTargets
$env:RIVER_MAX_TARGETS = [string]$RiverMaxTargets
$env:ROOT_CHECK_FLOOR = [string]$RootCheckFloor

$EnvSnapshot = [ordered]@{
  profile_name = $ProfileName
  runtime_profile = $RuntimeProfile
  preset = $Preset
  ev_keep_margin = $env:EV_KEEP_MARGIN
  turn_candidate_count = $env:TURN_CANDIDATE_COUNT
  river_candidate_count = $env:RIVER_CANDIDATE_COUNT
  turn_max_targets = $env:TURN_MAX_TARGETS
  river_max_targets = $env:RIVER_MAX_TARGETS
  root_check_floor = $env:ROOT_CHECK_FLOOR
  backtest_seed = $BacktestSeed
  backtest_max_spots = $BacktestMaxSpots
  no_spot_opponent_profile = [bool]$NoSpotOpponentProfile
  run_timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$EnvSnapshotPath = Join-Path $RunDir "profile.env.json"
$EnvSnapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $EnvSnapshotPath -Encoding UTF8

$AcceptanceScript = Join-Path $PSScriptRoot "test_acceptance.ps1"
$BacktestScript = Join-Path $PSScriptRoot "test_backtest_abc.ps1"

$TurnSummary = Join-Path $RunDir "acceptance.turn.summary.json"
$TurnDetails = Join-Path $RunDir "acceptance.turn.details.json"
$RiverSummary = Join-Path $RunDir "acceptance.river.summary.json"
$RiverDetails = Join-Path $RunDir "acceptance.river.details.json"
$BacktestOutput = Join-Path $RunDir "backtest.abc.json"

Write-Host "==> Fast Profile: turn_class1 acceptance"
$TurnArgs = @{
  Suite = "turn_class1"
  Preset = $Preset
  RuntimeProfile = $RuntimeProfile
  EvKeepMargin = $EvKeepMargin
  Output = $TurnSummary
  Details = $TurnDetails
}
if ($NoSpotOpponentProfile) { $TurnArgs["NoSpotOpponentProfile"] = $true }
if ($StopStartedServices) { $TurnArgs["StopStartedServices"] = $true }
& $AcceptanceScript @TurnArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Fast Profile: river_class23 acceptance"
$RiverArgs = @{
  Suite = "river_class23"
  Preset = $Preset
  RuntimeProfile = $RuntimeProfile
  EvKeepMargin = $EvKeepMargin
  Output = $RiverSummary
  Details = $RiverDetails
}
if ($NoSpotOpponentProfile) { $RiverArgs["NoSpotOpponentProfile"] = $true }
if ($StopStartedServices) { $RiverArgs["StopStartedServices"] = $true }
& $AcceptanceScript @RiverArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Fast Profile: A/B/C backtest"
$BacktestArgs = @{
  Preset = $Preset
  RuntimeProfile = $RuntimeProfile
  EvKeepMargin = $EvKeepMargin
  Seed = $BacktestSeed
  MaxSpots = $BacktestMaxSpots
  Output = $BacktestOutput
}
if ($StopStartedServices) { $BacktestArgs["StopStartedServices"] = $true }
& $BacktestScript @BacktestArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not (Test-Path $TurnSummary)) { throw "Missing output: $TurnSummary" }
if (-not (Test-Path $RiverSummary)) { throw "Missing output: $RiverSummary" }
if (-not (Test-Path $BacktestOutput)) { throw "Missing output: $BacktestOutput" }

$Turn = Get-Content $TurnSummary -Raw | ConvertFrom-Json
$River = Get-Content $RiverSummary -Raw | ConvertFrom-Json
$Backtest = Get-Content $BacktestOutput -Raw | ConvertFrom-Json

$Summary = [ordered]@{
  profile = $EnvSnapshot
  acceptance = [ordered]@{
    turn_class1 = [ordered]@{
      pass = [bool]$Turn.pass
      fallback_rate = $Turn.fallback_rate
      lock_applied_rate = $Turn.lock_applied_rate
      keep_rate = $Turn.keep_rate
      output = $TurnSummary
      details = $TurnDetails
    }
    river_class23 = [ordered]@{
      pass = [bool]$River.pass
      fallback_rate = $River.fallback_rate
      lock_applied_rate = $River.lock_applied_rate
      keep_rate = $River.keep_rate
      output = $RiverSummary
      details = $RiverDetails
    }
  }
  backtest = [ordered]@{
    output = $BacktestOutput
    summaries = $Backtest.summaries
  }
}

$SummaryPath = Join-Path $RunDir "fast_profile.summary.json"
$Summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Host ""
Write-Host "Fast Profile Summary"
Write-Host ("  profile={0}" -f $ProfileName)
Write-Host ("  turn_class1: pass={0}, fallback={1}, keep={2}" -f $Summary.acceptance.turn_class1.pass, $Summary.acceptance.turn_class1.fallback_rate, $Summary.acceptance.turn_class1.keep_rate)
Write-Host ("  river_class23: pass={0}, fallback={1}, keep={2}" -f $Summary.acceptance.river_class23.pass, $Summary.acceptance.river_class23.fallback_rate, $Summary.acceptance.river_class23.keep_rate)

$Modes = $Summary.backtest.summaries.PSObject.Properties.Name
foreach ($mode in $Modes) {
  $m = $Summary.backtest.summaries.$mode
  Write-Host ("  {0}: bb100_avg={1}, fallback_rate={2}, keep_rate={3}, p50={4}s, p95={5}s" -f `
    $mode, $m.bb100_avg, $m.fallback_rate, $m.keep_rate, $m.latency_p50_sec, $m.latency_p95_sec)
}
Write-Host ("  summary={0}" -f $SummaryPath)

exit 0
