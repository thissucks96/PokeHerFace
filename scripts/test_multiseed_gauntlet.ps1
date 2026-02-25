[CmdletBinding()]
param(
  [string]$Preset = "local_qwen3_coder_30b",
  [string]$Seeds = "4090,2026,1337",
  [int]$CountPerStreet = 20,
  [double]$EvKeepMargin = 0.001,
  [string]$PhhDir = "",
  [string]$TurnSourceDir = "",
  [string]$RiverSourceDir = "",
  [string]$Output = "",
  [switch]$SkipPoolBuild,
  [switch]$StopStartedServices
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "test_helpers.ps1")

$RepoRoot = Get-RepoRoot -ScriptRoot $PSScriptRoot
$PythonExe = Get-PythonExe -RepoRoot $RepoRoot
$BuildSpotPack = Join-Path $RepoRoot "4_LLM_Bridge\build_spot_pack.py"
$BuildCanonical = Join-Path $RepoRoot "4_LLM_Bridge\build_canonical_pack.py"
$TagClasses = Join-Path $RepoRoot "4_LLM_Bridge\tag_spot_classes.py"
$RunGate = Join-Path $RepoRoot "4_LLM_Bridge\run_acceptance_gate.py"

foreach ($p in @($BuildSpotPack, $BuildCanonical, $TagClasses, $RunGate)) {
  if (-not (Test-Path $p)) { throw "Missing script: $p" }
}

if ([string]::IsNullOrWhiteSpace($PhhDir)) {
  $PhhDir = Join-Path $RepoRoot "3_Hand_Histories\poker-hand-histories"
}
if (-not (Test-Path $PhhDir)) { throw "PHH dir not found: $PhhDir" }

$IsCloudPreset = Get-IsCloudPreset -Preset $Preset
$state = Ensure-TestServices -RepoRoot $RepoRoot -PythonExe $PythonExe -IsCloudPreset:$IsCloudPreset

try {
  $seedList = @()
  foreach ($raw in ($Seeds -split ",")) {
    $v = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($v)) { continue }
    $seedList += [int]$v
  }
  if ($seedList.Count -eq 0) { throw "No valid seeds parsed from: $Seeds" }

  $runBase = Join-Path ([System.IO.Path]::GetTempPath()) ("multiseed_gauntlet_ps1_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
  New-Item -ItemType Directory -Path $runBase | Out-Null

  if (-not $SkipPoolBuild) {
    if ([string]::IsNullOrWhiteSpace($TurnSourceDir)) {
      $turnPool = Join-Path $runBase "turn_pool"
      & $PythonExe $BuildSpotPack `
        --phh-dir $PhhDir `
        --output-dir (Join-Path $turnPool "spots") `
        --street turn `
        --opponent-profile-mode pool `
        --benchmark-mode `
        --report (Join-Path $turnPool "spot_pack_report.json") `
        --output-manifest (Join-Path $turnPool "spot_pack_manifest.jsonl")
      $TurnSourceDir = Join-Path $turnPool "spots"
    }
    if ([string]::IsNullOrWhiteSpace($RiverSourceDir)) {
      $riverPool = Join-Path $runBase "river_pool"
      & $PythonExe $BuildSpotPack `
        --phh-dir $PhhDir `
        --output-dir (Join-Path $riverPool "spots") `
        --street river `
        --opponent-profile-mode pool `
        --benchmark-mode `
        --report (Join-Path $riverPool "spot_pack_report.json") `
        --output-manifest (Join-Path $riverPool "spot_pack_manifest.jsonl")
      $RiverSourceDir = Join-Path $riverPool "spots"
    }
  }

  if (-not (Test-Path $TurnSourceDir)) { throw "Turn source dir not found: $TurnSourceDir" }
  if (-not (Test-Path $RiverSourceDir)) { throw "River source dir not found: $RiverSourceDir" }

  $rows = @()
  foreach ($seed in $seedList) {
    $seedDir = Join-Path $runBase ("seed_" + $seed)
    $turnDir = Join-Path $seedDir "turn20"
    $riverDir = Join-Path $seedDir "river20"

    & $PythonExe $BuildCanonical `
      --spot-dir $TurnSourceDir `
      --output-dir $turnDir `
      --count $CountPerStreet `
      --streets turn `
      --min-per-street $CountPerStreet `
      --seed $seed `
      --benchmark-mode
    & $PythonExe $TagClasses `
      --manifest (Join-Path $turnDir "canonical_manifest.json") `
      --output-manifest (Join-Path $turnDir "tagged_manifest.json") `
      --summary (Join-Path $turnDir "tagged_summary.json") `
      --write-spot-meta
    & $PythonExe $RunGate `
      --spot-dir (Join-Path $turnDir "spots") `
      --preset $Preset `
      --use-spot-opponent-profile `
      --multi-node-classes turn_probe_punish `
      --ev-keep-margin $EvKeepMargin `
      --output (Join-Path $turnDir "acceptance_summary.turn.class1.ps1.json") `
      --details (Join-Path $turnDir "acceptance_records.turn.class1.ps1.json")

    & $PythonExe $BuildCanonical `
      --spot-dir $RiverSourceDir `
      --output-dir $riverDir `
      --count $CountPerStreet `
      --streets river `
      --min-per-street $CountPerStreet `
      --seed $seed `
      --benchmark-mode
    & $PythonExe $TagClasses `
      --manifest (Join-Path $riverDir "canonical_manifest.json") `
      --output-manifest (Join-Path $riverDir "tagged_manifest.json") `
      --summary (Join-Path $riverDir "tagged_summary.json") `
      --write-spot-meta
    & $PythonExe $RunGate `
      --spot-dir (Join-Path $riverDir "spots") `
      --preset $Preset `
      --use-spot-opponent-profile `
      --multi-node-classes river_bigbet_overfold_punish river_underbluff_defense `
      --ev-keep-margin $EvKeepMargin `
      --output (Join-Path $riverDir "acceptance_summary.river.class23.ps1.json") `
      --details (Join-Path $riverDir "acceptance_records.river.class23.ps1.json")

    $turnSummary = Get-Content (Join-Path $turnDir "acceptance_summary.turn.class1.ps1.json") -Raw | ConvertFrom-Json
    $riverSummary = Get-Content (Join-Path $riverDir "acceptance_summary.river.class23.ps1.json") -Raw | ConvertFrom-Json

    $rows += [PSCustomObject]@{
      seed = $seed
      turn_pass = [bool]$turnSummary.pass
      turn_fallback = [double]$turnSummary.fallback_rate
      turn_applied = [double]$turnSummary.lock_applied_rate
      turn_keep = [double]$turnSummary.keep_rate
      river_pass = [bool]$riverSummary.pass
      river_fallback = [double]$riverSummary.fallback_rate
      river_applied = [double]$riverSummary.lock_applied_rate
      river_keep = [double]$riverSummary.keep_rate
    }
  }

  $aggregate = [PSCustomObject]@{
    run_base = $runBase
    phh_dir = $PhhDir
    turn_source = $TurnSourceDir
    river_source = $RiverSourceDir
    seeds = $seedList
    all_turn_pass = [bool](-not ($rows | Where-Object { -not $_.turn_pass }))
    all_river_pass = [bool](-not ($rows | Where-Object { -not $_.river_pass }))
    turn_fallback_avg = [double](($rows | Measure-Object -Property turn_fallback -Average).Average)
    turn_applied_avg = [double](($rows | Measure-Object -Property turn_applied -Average).Average)
    turn_keep_avg = [double](($rows | Measure-Object -Property turn_keep -Average).Average)
    river_fallback_avg = [double](($rows | Measure-Object -Property river_fallback -Average).Average)
    river_applied_avg = [double](($rows | Measure-Object -Property river_applied -Average).Average)
    river_keep_avg = [double](($rows | Measure-Object -Property river_keep -Average).Average)
  }

  if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $RepoRoot "4_LLM_Bridge\examples\gauntlet.multiseed.ps1.json"
  }
  $report = [PSCustomObject]@{
    aggregate = $aggregate
    per_seed = $rows
  }
  $outDir = Split-Path -Parent $Output
  if (-not [string]::IsNullOrWhiteSpace($outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $report | ConvertTo-Json -Depth 6 | Set-Content -Path $Output

  Write-Host ""
  Write-Host "Multiseed Gauntlet Summary"
  Write-Host ("  all_turn_pass={0}" -f $aggregate.all_turn_pass)
  Write-Host ("  all_river_pass={0}" -f $aggregate.all_river_pass)
  Write-Host ("  turn_applied_avg={0}, turn_keep_avg={1}" -f $aggregate.turn_applied_avg, $aggregate.turn_keep_avg)
  Write-Host ("  river_applied_avg={0}, river_keep_avg={1}" -f $aggregate.river_applied_avg, $aggregate.river_keep_avg)
  Write-Host ("  output={0}" -f $Output)
  exit 0
}
finally {
  if ($StopStartedServices) {
    Stop-TestServices -State $state
  }
}
