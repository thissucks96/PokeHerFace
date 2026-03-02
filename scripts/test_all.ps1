[CmdletBinding()]
param(
  [string]$Preset = "local_qwen3_coder_30b",
  [ValidateSet("fast", "fast_live", "normal", "normal_neural", "shark_classic")]
  [string]$RuntimeProfile = "",
  [double]$EvKeepMargin = 0.001,
  [int]$BacktestSeed = 4090,
  [int]$BacktestMaxSpots = 40,
  [switch]$IncludeGauntlet,
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptCi = Join-Path $PSScriptRoot "test_ci.ps1"
$scriptAcceptance = Join-Path $PSScriptRoot "test_acceptance.ps1"
$scriptBacktest = Join-Path $PSScriptRoot "test_backtest_abc.ps1"
$scriptGauntlet = Join-Path $PSScriptRoot "test_multiseed_gauntlet.ps1"

foreach ($p in @($scriptCi, $scriptAcceptance, $scriptBacktest, $scriptGauntlet)) {
  if (-not (Test-Path $p)) { throw "Missing script: $p" }
}

Write-Host "==> Running canonical CI gate"
& $scriptCi `
  -Preset $Preset `
  -RuntimeProfile $RuntimeProfile `
  -EvKeepMargin $EvKeepMargin `
  -NoiseRuns 1 `
  -StopStartedServices:$StopStartedServices
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Running turn class1 acceptance"
& $scriptAcceptance `
  -Suite turn_class1 `
  -Preset $Preset `
  -RuntimeProfile $RuntimeProfile `
  -EvKeepMargin $EvKeepMargin `
  -StopStartedServices:$StopStartedServices
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Running river class23 acceptance"
& $scriptAcceptance `
  -Suite river_class23 `
  -Preset $Preset `
  -RuntimeProfile $RuntimeProfile `
  -EvKeepMargin $EvKeepMargin `
  -StopStartedServices:$StopStartedServices
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Running A/B/C backtest"
& $scriptBacktest `
  -Preset $Preset `
  -RuntimeProfile $RuntimeProfile `
  -EvKeepMargin $EvKeepMargin `
  -Seed $BacktestSeed `
  -MaxSpots $BacktestMaxSpots `
  -StopStartedServices:$StopStartedServices
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($IncludeGauntlet) {
  Write-Host "==> Running multiseed gauntlet"
  & $scriptGauntlet `
    -Preset $Preset `
    -EvKeepMargin $EvKeepMargin `
    -StopStartedServices:$StopStartedServices
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "All selected test suites completed."
exit 0

