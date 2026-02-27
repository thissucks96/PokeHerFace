[CmdletBinding()]
param(
  [string]$Preset = "local_qwen3_coder_30b",
  [ValidateSet("fast", "normal")]
  [string]$RuntimeProfile = "fast",
  [int]$SolverTimeout = 600,
  [double]$HttpTimeout = 900,
  [double]$EvKeepMargin = 0.001,
  [switch]$DisableMultiNodeLocks,
  [int]$MaxPoints = 0,
  [string]$Pack = "",
  [string]$Output = "",
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot
$Runner = Join-Path $RepoRoot "4_LLM_Bridge\run_synthetic_hand_pack.py"
if (-not (Test-Path $Runner)) {
  throw "Missing synthetic runner: $Runner"
}

if ([string]::IsNullOrWhiteSpace($Pack)) {
  $Pack = Join-Path $RepoRoot "4_LLM_Bridge\examples\synthetic_hands\ten_hand_progression.json"
}
if (-not (Test-Path $Pack)) {
  throw "Synthetic pack not found: $Pack"
}

if ([string]::IsNullOrWhiteSpace($Output)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $Output = Join-Path $RepoRoot ("4_LLM_Bridge\examples\synthetic_hands\timing_report.{0}.json" -f $stamp)
}

$IsCloudPreset = Get-IsCloudPreset -Preset $Preset
$state = Ensure-TestServices -RepoRoot $RepoRoot -PythonExe $PythonExe -IsCloudPreset:$IsCloudPreset

try {
  $Args = @(
    $Runner,
    "--pack", $Pack,
    "--preset", $Preset,
    "--runtime-profile", $RuntimeProfile,
    "--solver-timeout", "$SolverTimeout",
    "--http-timeout", "$HttpTimeout",
    "--ev-keep-margin", "$EvKeepMargin",
    "--output", $Output
  )

  if ($DisableMultiNodeLocks) {
    $Args += "--disable-multi-node-locks"
  }
  if ($MaxPoints -gt 0) {
    $Args += @("--max-points", "$MaxPoints")
  }

  & $PythonExe @Args
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) {
    exit $ExitCode
  }

  if (-not (Test-Path $Output)) {
    throw "Synthetic timing report not produced: $Output"
  }

  $Report = Get-Content $Output -Raw | ConvertFrom-Json
  Write-Host ""
  Write-Host "Synthetic Pack Timing Summary"
  $Coverage = $Report.coverage
  Write-Host ("  points={0} success={1} failure={2} success_rate={3}" -f `
      $Coverage.decision_points_processed, $Coverage.success_count, $Coverage.failure_count, $Coverage.success_rate)

  $b = $Report.timing.bottleneck_by_total
  if ($null -ne $b) {
    Write-Host ("  bottleneck_total={0} total_sec={1} share={2}" -f $b.stage, $b.total_sec, $b.share_of_measured_stage_time)
  }
  else {
    Write-Host "  bottleneck_total=<none> (no successful stage timings captured)"
  }
  Write-Host ("  output={0}" -f $Output)
  exit 0
}
finally {
  if ($StopStartedServices) {
    Stop-TestServices -State $state
  }
}
