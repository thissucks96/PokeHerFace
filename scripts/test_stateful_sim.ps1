<#
.SYNOPSIS
Runs the passive-villain stateful hand simulation against the local bridge server and outputs a summary report.

.DESCRIPTION
This script wraps the Python `run_stateful_sim.py` tool. It simulates N hands of Flop -> Turn -> River back-to-back, managing pot and stack geometry automatically against a dummy "call station" villain. It does not use computer vision or OCR timeouts.

.PARAMETER Preset
The LLM config preset to pass to the bridge (default "local_qwen3_coder_30b").

.PARAMETER RuntimeProfile
The runtime latency profile "fast" or "normal" (default "fast").

.PARAMETER Hands
Number of hands to simulate (default 20).

.PARAMETER OutputDir
Directory to write the output JSON report. Defaults to `4_LLM_Bridge\examples\synthetic_hands\`.

.PARAMETER TimeoutSec
Maximum seconds to wait for a single bridge /solve request (default 60).
#>
[CmdletBinding()]
param (
    [string]$Preset = "local_qwen3_coder_30b",
    [ValidateSet("fast", "fast_live", "normal")]
    [string]$RuntimeProfile = "fast",
    [int]$Hands = 20,
    [string]$OutputDir = "$PSScriptRoot\..\4_LLM_Bridge\examples\synthetic_hands",
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = "Stop"

$workspaceRoot = (Resolve-Path "$PSScriptRoot\..").Path
$bridgeServerDir = Join-Path $workspaceRoot "4_LLM_Bridge"
$simScript = Join-Path $bridgeServerDir "run_stateful_sim.py"

if (-not (Test-Path $simScript)) {
    Write-Error "Cannot find stateful simulator python script: $simScript"
    exit 1
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$outputFile = Join-Path $OutputDir "stateful_sim_report.${RuntimeProfile}_${Hands}hands.${timestamp}.json"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Passive-Villain Stateful Simulator       " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target Profile : $RuntimeProfile"
Write-Host "Target LLM     : $Preset"
Write-Host "Hands Count    : $Hands"
Write-Host "Output Target  : $outputFile"
Write-Host ""
Write-Host "IMPORTANT: Ensure bridge_server.py is running on :8000" -ForegroundColor Yellow
Write-Host ""

$pythonArgs = @(
    $simScript,
    "--hands", $Hands,
    "--preset", $Preset,
    "--runtime-profile", $RuntimeProfile,
    "--timeout", $TimeoutSec,
    "--output", $outputFile
)

Write-Host "Executing python harness..." -ForegroundColor DarkGray
try {
    $proc = Start-Process -FilePath "python" -ArgumentList $pythonArgs -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Error "Python simulator exited with code $($proc.ExitCode)"
        exit $proc.ExitCode
    }
}
catch {
    Write-Error "Failed to execute python simulator: $_"
    exit 1
}

if (Test-Path $outputFile) {
    Write-Host ""
    Write-Host "SUCCESS: Simulator completed!" -ForegroundColor Green
    Write-Host "Report saved: $outputFile" -ForegroundColor Green
    
    # Read the summary stats and print a quick sanity check
    try {
        $json = Get-Content $outputFile -Raw | ConvertFrom-Json
        $actualHands = $json.hands.Count
        Write-Host "Processed hands: $actualHands" -ForegroundColor DarkGray
    } catch {}
} else {
    Write-Error "Python script completed but $outputFile was not generated."
    exit 1
}

exit 0
