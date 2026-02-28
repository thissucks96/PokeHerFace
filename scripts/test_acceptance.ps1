[CmdletBinding()]
param(
  [ValidateSet("turn_class1", "river_class23", "canonical_turn_ci")]
  [string]$Suite = "canonical_turn_ci",
  [string]$Preset = "local_qwen3_coder_30b",
  [ValidateSet("fast", "fast_live", "normal")]
  [string]$RuntimeProfile = "",
  [double]$EvKeepMargin = 0.001,
  [int]$CallsPerSpot = 1,
  [int]$NoiseRuns = 0,
  [double]$FallbackMax = 0.05,
  [double]$LockAppliedMin = 0.95,
  [double]$KeepRateMin = 0.000001,
  [string]$Output = "",
  [string]$Details = "",
  [switch]$NoSpotOpponentProfile,
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot
$GateScript = Join-Path $RepoRoot "4_LLM_Bridge\run_acceptance_gate.py"
if (-not (Test-Path $GateScript)) {
  throw "Missing gate script: $GateScript"
}

$IsCloudPreset = Get-IsCloudPreset -Preset $Preset
$state = Ensure-TestServices -RepoRoot $RepoRoot -PythonExe $PythonExe -IsCloudPreset:$IsCloudPreset

try {
  $Args = @(
    $GateScript,
    "--preset", $Preset,
    "--calls-per-spot", "$CallsPerSpot",
    "--ev-keep-margin", "$EvKeepMargin",
    "--calibrate-noise-runs", "$NoiseRuns",
    "--fallback-max", "$FallbackMax",
    "--lock-applied-min", "$LockAppliedMin",
    "--keep-rate-min", "$KeepRateMin"
  )
  if (-not [string]::IsNullOrWhiteSpace($RuntimeProfile)) {
    $Args += @("--runtime-profile", $RuntimeProfile)
  }

  switch ($Suite) {
    "turn_class1" {
      $SpotDir = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\multinode_class1_spots"
      if (-not (Test-Path $SpotDir)) { throw "Spot dir not found: $SpotDir" }
      $Args += @("--spot-dir", $SpotDir, "--multi-node-classes", "turn_probe_punish")
      if (-not $NoSpotOpponentProfile) { $Args += @("--use-spot-opponent-profile") }
      if ([string]::IsNullOrWhiteSpace($Output)) {
        $Output = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\acceptance_summary.turn_class1.ps1.json"
      }
      if ([string]::IsNullOrWhiteSpace($Details)) {
        $Details = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\acceptance_records.turn_class1.ps1.json"
      }
    }
    "river_class23" {
      $SpotDir = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_river20\spots"
      if (-not (Test-Path $SpotDir)) { throw "Spot dir not found: $SpotDir" }
      $Args += @("--spot-dir", $SpotDir, "--multi-node-classes", "river_bigbet_overfold_punish", "river_underbluff_defense")
      if (-not $NoSpotOpponentProfile) { $Args += @("--use-spot-opponent-profile") }
      if ([string]::IsNullOrWhiteSpace($Output)) {
        $Output = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_river20\acceptance_summary.river_class23.ps1.json"
      }
      if ([string]::IsNullOrWhiteSpace($Details)) {
        $Details = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_river20\acceptance_records.river_class23.ps1.json"
      }
    }
    "canonical_turn_ci" {
      $Manifest = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\canonical_manifest.json"
      if (-not (Test-Path $Manifest)) { throw "Canonical manifest not found: $Manifest" }
      $Args += @("--canonical-manifest", $Manifest)
      if ([string]::IsNullOrWhiteSpace($Output)) {
        $Output = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\acceptance_summary.canonical_turn_ci.ps1.json"
      }
      if ([string]::IsNullOrWhiteSpace($Details)) {
        $Details = Join-Path $RepoRoot "4_LLM_Bridge\examples\canonical_turn20\acceptance_records.canonical_turn_ci.ps1.json"
      }
    }
    default {
      throw "Unsupported suite: $Suite"
    }
  }

  $Args += @("--output", $Output, "--details", $Details)
  & $PythonExe @Args
  $ExitCode = $LASTEXITCODE

  if (-not (Test-Path $Output)) {
    throw "Acceptance summary not produced: $Output"
  }
  $Summary = Get-Content $Output -Raw | ConvertFrom-Json
  Write-Host ""
  Write-Host "Acceptance Suite: $Suite"
  Write-Host ("  pass={0}" -f [bool]$Summary.pass)
  Write-Host ("  fallback_rate={0}" -f $Summary.fallback_rate)
  Write-Host ("  lock_applied_rate={0}" -f $Summary.lock_applied_rate)
  Write-Host ("  keep_rate={0}" -f $Summary.keep_rate)
  Write-Host ("  output={0}" -f $Output)

  if ($ExitCode -ne 0) {
    exit $ExitCode
  }
  exit 0
}
finally {
  if ($StopStartedServices) {
    Stop-TestServices -State $state
  }
}
