<#
.SYNOPSIS
Runs a local neural data-collection recipe with mixed villain and geometry legs.

.DESCRIPTION
This wrapper orchestrates multiple `test_stateful_sim.ps1` runs and intentionally
mixes stack/pot/range geometries so the resulting flop dataset contains both
complexity-guard and non-guard spots.

Default `mixed_geometry_v1` recipe:
- Deep/wide spots (guard-prone)
- Mid-SPR mixed spots
- Short-stack spots

Legacy `legacy_villain_mix` remains available.

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

.PARAMETER RecipePreset
Recipe layout. Use mixed_geometry_v1 for neural dataset generation.

.PARAMETER BaseSeed
Optional base RNG seed. Each leg uses BaseSeed + leg_index*10000.
#>
[CmdletBinding()]
param(
    [string]$Preset = "local_qwen3_coder_30b",
    [ValidateSet("fast", "fast_live", "normal", "normal_neural", "shark_classic")]
    [string]$RuntimeProfile = "fast_live",
    [int]$TotalHands = 300,
    [string]$OutputDir = "4_LLM_Bridge/examples/synthetic_hands/recipes",
    [string]$ArtifactDir = "5_Vision_Extraction/out/flop_engine",
    [int]$TimeoutSec = 60,
    [ValidateSet("mixed_geometry_v1", "legacy_villain_mix")]
    [string]$RecipePreset = "mixed_geometry_v1",
    [int]$BaseSeed = 0,
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

$wideRange = "22+,A2s+,K2s+,Q2s+,J2s+,T2s+,92s+,82s+,72s+,62s+,52s+,42s+,32s+,A2o+,K2o+,Q2o+,J2o+,T2o+,92o+,82o+,72o+,62o+,52o+,42o+,32o+"
$mediumRange = "66+,A8s+,KTs+,QTs+,JTs,T9s,98s,AJo+,KQo"
$tightRange = "88+,ATs+,KQs,AQo+"

function New-RecipeLeg {
    param(
        [string]$Name,
        [double]$Weight,
        [string]$Mode,
        [int]$StackBB,
        [int]$PotBB,
        [int]$MinBetBB,
        [string]$VillainRange
    )
    return [PSCustomObject]@{
        Name = $Name
        Weight = [double]$Weight
        Mode = $Mode
        StackBB = [int]$StackBB
        PotBB = [int]$PotBB
        MinBetBB = [int]$MinBetBB
        VillainRange = [string]$VillainRange
        Hands = 0
    }
}

function Set-HandAllocation {
    param(
        [Parameter(Mandatory)] [array]$Legs,
        [Parameter(Mandatory)] [int]$Hands
    )

    $totalWeight = ($Legs | Measure-Object -Property Weight -Sum).Sum
    if (-not $totalWeight -or [double]$totalWeight -le 0.0) {
        throw "Recipe leg weights must sum to > 0."
    }

    $alloc = @()
    $assigned = 0
    foreach ($leg in $Legs) {
        $exact = [double]$Hands * ([double]$leg.Weight / [double]$totalWeight)
        $base = [int][Math]::Floor($exact)
        $alloc += [PSCustomObject]@{
            Leg = $leg
            Base = $base
            Fraction = $exact - [double]$base
        }
        $assigned += $base
    }

    $remaining = [int]$Hands - [int]$assigned
    if ($remaining -gt 0) {
        $priority = $alloc | Sort-Object -Property Fraction -Descending
        for ($i = 0; $i -lt $remaining; $i++) {
            $idx = $i % $priority.Count
            $priority[$idx].Base += 1
        }
    }

    foreach ($row in $alloc) {
        $row.Leg.Hands = [int]$row.Base
    }

    return @($Legs | Where-Object { [int]$_.Hands -gt 0 })
}

$legs = @()
if ($RecipePreset -eq "legacy_villain_mix") {
    $legs = @(
        (New-RecipeLeg -Name "engine_random_legacy" -Weight $EngineRandomRatio -Mode "engine_random" -StackBB 100 -PotBB 6 -MinBetBB 2 -VillainRange $wideRange),
        (New-RecipeLeg -Name "scripted_aggressive_legacy" -Weight $ScriptedAggressiveRatio -Mode "scripted_aggressive" -StackBB 100 -PotBB 6 -MinBetBB 2 -VillainRange $wideRange),
        (New-RecipeLeg -Name "scripted_tight_legacy" -Weight $ScriptedTightRatio -Mode "scripted_tight" -StackBB 100 -PotBB 6 -MinBetBB 2 -VillainRange $wideRange)
    )
} else {
    $legs = @(
        (New-RecipeLeg -Name "deep_wide_guard_prone" -Weight 0.30 -Mode "scripted_tight" -StackBB 100 -PotBB 6 -MinBetBB 2 -VillainRange $wideRange),
        (New-RecipeLeg -Name "deep_wide_engine" -Weight 0.10 -Mode "engine_random" -StackBB 100 -PotBB 6 -MinBetBB 2 -VillainRange $wideRange),
        (New-RecipeLeg -Name "mid_stack_engine" -Weight 0.25 -Mode "engine_random" -StackBB 60 -PotBB 10 -MinBetBB 2 -VillainRange $mediumRange),
        (New-RecipeLeg -Name "short_stack_aggressive" -Weight 0.20 -Mode "scripted_aggressive" -StackBB 30 -PotBB 14 -MinBetBB 2 -VillainRange $tightRange),
        (New-RecipeLeg -Name "short_stack_tight" -Weight 0.15 -Mode "scripted_tight" -StackBB 20 -PotBB 12 -MinBetBB 2 -VillainRange $tightRange)
    )
}

$legs = Set-HandAllocation -Legs $legs -Hands $TotalHands
if (-not $legs -or $legs.Count -eq 0) {
    throw "No recipe legs have >0 hands. Increase TotalHands or adjust ratios."
}

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$manifestPath = Join-Path $OutputDir "neural_collection_recipe_${RecipePreset}_${runId}.json"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Neural Collection Recipe Runner           " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "RuntimeProfile: $RuntimeProfile"
Write-Host "Preset       : $Preset"
Write-Host "RecipePreset : $RecipePreset"
Write-Host "TotalHands   : $TotalHands"
Write-Host "ArtifactDir  : $ArtifactDir"
if ($BaseSeed -gt 0) {
    Write-Host "BaseSeed     : $BaseSeed"
}
Write-Host ""

$legIndex = 0
foreach ($leg in $legs) {
    $legIndex += 1
    Write-Host ("Leg {0}: name={1}, mode={2}, hands={3}, stack={4}bb, pot={5}bb" -f $legIndex, $leg.Name, $leg.Mode, $leg.Hands, $leg.StackBB, $leg.PotBB)
}
Write-Host ""

$results = @()
$legIndex = 0
foreach ($leg in $legs) {
    $legIndex += 1
    $legSeed = 0
    if ($BaseSeed -gt 0) {
        $legSeed = [int]$BaseSeed + ([int]$legIndex * 10000)
    }

    Write-Host ("Running leg: name={0}, mode={1}, hands={2}, seed={3}" -f $leg.Name, $leg.Mode, $leg.Hands, $legSeed) -ForegroundColor DarkGray
    & $simRunner `
        -Preset $Preset `
        -RuntimeProfile $RuntimeProfile `
        -Hands $leg.Hands `
        -OutputDir $OutputDir `
        -TimeoutSec $TimeoutSec `
        -VillainMode $leg.Mode `
        -ArtifactDir $ArtifactDir `
        -StartingStackBB $leg.StackBB `
        -StartingPotBB $leg.PotBB `
        -MinimumBetBB $leg.MinBetBB `
        -VillainRange $leg.VillainRange `
        -Seed $legSeed

    if ($LASTEXITCODE -ne 0) {
        throw "Recipe leg failed: name=$($leg.Name), mode=$($leg.Mode), exit_code=$LASTEXITCODE"
    }

    $results += [PSCustomObject]@{
        name = $leg.Name
        mode = $leg.Mode
        hands = $leg.Hands
        stack_bb = $leg.StackBB
        pot_bb = $leg.PotBB
        min_bet_bb = $leg.MinBetBB
        villain_range = $leg.VillainRange
        seed = $legSeed
        status = "ok"
    }
}

$manifest = [PSCustomObject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    runtime_profile = $RuntimeProfile
    preset = $Preset
    recipe_preset = $RecipePreset
    total_hands = $TotalHands
    artifact_dir = $ArtifactDir
    output_dir = $OutputDir
    timeout_sec = $TimeoutSec
    base_seed = $BaseSeed
    legs = $results
}

$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host ""
Write-Host "Recipe completed." -ForegroundColor Green
Write-Host "Manifest: $manifestPath" -ForegroundColor Green
Write-Host "Next: python .\scripts\quality_gate_flop_distribution.py --artifact-dir $ArtifactDir --strict" -ForegroundColor Yellow
Write-Host "Then: python .\scripts\build_neural_dataset.py --response-dir $ArtifactDir --write" -ForegroundColor Yellow
exit 0
