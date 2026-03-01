<#
.SYNOPSIS
Runs a mixed villain-policy stateful simulation recipe to generate local neural training artifacts.

.DESCRIPTION
This wrapper orchestrates multiple `test_stateful_sim.ps1` runs with configurable hand-ratio splits.
Default recipe:
- 65% engine_random (engine-vs-engine style)
- 25% scripted_aggressive
- 10% scripted_tight

Artifacts can be written directly into `5_Vision_Extraction/out/flop_engine` so
`build_neural_dataset.py --write` can consume them.

.PARAMETER Preset
Bridge LLM preset.

.PARAMETER RuntimeProfile
Bridge runtime profile.

.PARAMETER TotalHands
Total hands across all recipe legs.

.PARAMETER OutputDir
Directory for per-leg simulation reports.

.PARAMETER ArtifactDir
Directory for payload/response artifacts (dataset builder input).

.PARAMETER TimeoutSec
Bridge timeout for each solve call.
#>
[CmdletBinding()]
param(
    [string]$Preset = "local_qwen3_coder_30b",
    [ValidateSet("fast", "fast_live", "normal")]
    [string]$RuntimeProfile = "fast_live",
    [int]$TotalHands = 300,
    [string]$OutputDir = "4_LLM_Bridge/examples/synthetic_hands/recipes",
    [string]$ArtifactDir = "5_Vision_Extraction/out/flop_engine",
    [int]$TimeoutSec = 60,
    [double]$EngineRandomRatio = 0.65,
    [double]$ScriptedAggressiveRatio = 0.25,
    [double]$ScriptedTightRatio = 0.10
)

$ErrorActionPreference = "Stop"
$workspaceRoot = (Resolve-Path "$PSScriptRoot\..").Path
$simRunner = Join-Path $workspaceRoot "scripts\test_stateful_sim.ps1"

if (-not (Test-Path $simRunner)) {
    throw "Missing script: $simRunner"
}

if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $workspaceRoot $OutputDir
}
if (-not [System.IO.Path]::IsPathRooted($ArtifactDir)) {
    $ArtifactDir = Join-Path $workspaceRoot $ArtifactDir
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$ArtifactDir = [System.IO.Path]::GetFullPath($ArtifactDir)
$null = New-Item -ItemType Directory -Path $OutputDir -Force
$null = New-Item -ItemType Directory -Path $ArtifactDir -Force

$ratioSum = [double]$EngineRandomRatio + [double]$ScriptedAggressiveRatio + [double]$ScriptedTightRatio
if ($ratioSum -le 0.0) {
    throw "Recipe ratios must sum to > 0."
}

$engineHands = [int][Math]::Round($TotalHands * ($EngineRandomRatio / $ratioSum))
$aggrHands = [int][Math]::Round($TotalHands * ($ScriptedAggressiveRatio / $ratioSum))
$tightHands = [int]$TotalHands - $engineHands - $aggrHands
if ($tightHands -lt 0) {
    $tightHands = 0
}

$legs = @(
    [PSCustomObject]@{ Mode = "engine_random"; Hands = $engineHands },
    [PSCustomObject]@{ Mode = "scripted_aggressive"; Hands = $aggrHands },
    [PSCustomObject]@{ Mode = "scripted_tight"; Hands = $tightHands }
) | Where-Object { $_.Hands -gt 0 }

if (-not $legs -or $legs.Count -eq 0) {
    throw "No recipe legs have >0 hands. Increase TotalHands or adjust ratios."
}

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$manifestPath = Join-Path $OutputDir "neural_collection_recipe_${runId}.json"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Neural Collection Recipe Runner           " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "RuntimeProfile: $RuntimeProfile"
Write-Host "Preset       : $Preset"
Write-Host "TotalHands   : $TotalHands"
Write-Host "ArtifactDir  : $ArtifactDir"
Write-Host ""
$legIndex = 0
foreach ($leg in $legs) {
    $legIndex += 1
    Write-Host ("Leg {0}: mode={1} hands={2}" -f $legIndex, $leg.Mode, $leg.Hands)
}
Write-Host ""

$results = @()
foreach ($leg in $legs) {
    Write-Host ("Running leg: mode={0}, hands={1}" -f $leg.Mode, $leg.Hands) -ForegroundColor DarkGray
    & $simRunner `
        -Preset $Preset `
        -RuntimeProfile $RuntimeProfile `
        -Hands $leg.Hands `
        -OutputDir $OutputDir `
        -TimeoutSec $TimeoutSec `
        -VillainMode $leg.Mode `
        -ArtifactDir $ArtifactDir

    if ($LASTEXITCODE -ne 0) {
        throw "Recipe leg failed: mode=$($leg.Mode), exit_code=$LASTEXITCODE"
    }

    $results += [PSCustomObject]@{
        mode = $leg.Mode
        hands = $leg.Hands
        status = "ok"
    }
}

$manifest = [PSCustomObject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_profile = $RuntimeProfile
    preset = $Preset
    total_hands = $TotalHands
    artifact_dir = $ArtifactDir
    output_dir = $OutputDir
    ratios = [PSCustomObject]@{
        engine_random = $EngineRandomRatio
        scripted_aggressive = $ScriptedAggressiveRatio
        scripted_tight = $ScriptedTightRatio
    }
    legs = $results
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host ""
Write-Host "Recipe completed." -ForegroundColor Green
Write-Host "Manifest: $manifestPath" -ForegroundColor Green
Write-Host "Next: python .\scripts\build_neural_dataset.py --write" -ForegroundColor Yellow
exit 0
