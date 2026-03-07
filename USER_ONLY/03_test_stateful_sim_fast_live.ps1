Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if ($args.Count -gt 0) {
    & ".\scripts\test_stateful_sim.ps1" @args
} else {
    & ".\scripts\test_stateful_sim.ps1" -Hands 50 -RuntimeProfile fast_live -VillainMode scripted_aggressive
}
