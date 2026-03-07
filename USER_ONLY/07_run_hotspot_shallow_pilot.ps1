Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

try {
    & ".\scripts\run_hotspot_shallow_pilot.ps1" @args
    Write-Host ""
    Write-Host "Launcher finished. The hotspot shallow pilot should now be active."
    Write-Host "Visible progress windows should stay open separately."
} catch {
    Write-Host ""
    Write-Host "Launcher failed: $($_.Exception.Message)"
    throw
} finally {
    Write-Host ""
    Read-Host "Press Enter to close this launcher window"
}
