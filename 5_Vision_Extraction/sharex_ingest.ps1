[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ImagePath,
  [string]$Endpoint = "http://127.0.0.1:8000/vision/ingest",
  [ValidateSet("general", "cards", "numeric")]
  [string]$Profile = "general",
  [int]$BridgeStartTimeoutSec = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-RepoRoot {
  param([Parameter(Mandatory = $true)][string]$ScriptPath)
  return (Resolve-Path (Join-Path (Split-Path $ScriptPath -Parent) "..")).Path
}

function Get-PythonExe {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)
  $venvPython = Join-Path $RepoRoot ".venv\Scripts\python.exe"
  if (Test-Path $venvPython) {
    return $venvPython
  }
  return "python"
}

function Test-BridgeHealth {
  param([Parameter(Mandatory = $true)][string]$HealthUri)
  try {
    return (Invoke-RestMethod -Method Get -Uri $HealthUri -TimeoutSec 3)
  }
  catch {
    return $null
  }
}

function Stop-BridgeProcesses {
  $procs = Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -like "python*") -and $_.CommandLine -and (
      $_.CommandLine -like "*4_LLM_Bridge\\bridge_server.py*" -or
      $_.CommandLine -like "*4_LLM_Bridge/bridge_server.py*"
    )
  }
  foreach ($proc in $procs) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-BridgeRunning {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [Parameter(Mandatory = $true)][string]$HealthUri,
    [int]$TimeoutSec = 30
  )
  $health = Test-BridgeHealth -HealthUri $HealthUri
  if ($health -and ($health.PSObject.Properties.Name -contains "vision_root")) {
    return
  }
  if ($health) {
    # Bridge is up but stale build without vision endpoint metadata; bounce it.
    Stop-BridgeProcesses
    Start-Sleep -Milliseconds 500
  }
  $bridgeScript = Join-Path $RepoRoot "4_LLM_Bridge\bridge_server.py"
  Start-Process -FilePath $PythonExe -ArgumentList $bridgeScript -WorkingDirectory $RepoRoot | Out-Null

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $probe = Test-BridgeHealth -HealthUri $HealthUri
    if ($probe -and ($probe.PSObject.Properties.Name -contains "vision_root")) {
      return
    }
  }
  throw "Bridge server did not start within ${TimeoutSec}s."
}

$repoRoot = Get-RepoRoot -ScriptPath $PSCommandPath
$pythonExe = Get-PythonExe -RepoRoot $repoRoot

if (-not (Test-Path -LiteralPath $ImagePath)) {
  throw "Image path not found: $ImagePath"
}
$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path

$visionRoot = Join-Path $repoRoot "5_Vision_Extraction"
$incomingDir = Join-Path $visionRoot "incoming"
$outDir = Join-Path $visionRoot "out"
$processedDir = Join-Path $visionRoot "processed"
$failedDir = Join-Path $visionRoot "failed"
foreach ($d in @($incomingDir, $outDir, $processedDir, $failedDir)) {
  New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$healthUri = ($Endpoint -replace "/vision/ingest/?$", "") + "/health"
Ensure-BridgeRunning -RepoRoot $repoRoot -PythonExe $pythonExe -HealthUri $healthUri -TimeoutSec $BridgeStartTimeoutSec

$body = @{
  image_path = $resolvedImage
  source = "sharex"
  profile = $Profile
  save_copy = $true
}

$response = Invoke-RestMethod `
  -Method Post `
  -Uri $Endpoint `
  -ContentType "application/json" `
  -Body ($body | ConvertTo-Json -Depth 10 -Compress) `
  -TimeoutSec 120

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss_fff")
$logPath = Join-Path $outDir ("sharex_ingest_response.{0}.json" -f $stamp)
$latestPath = Join-Path $outDir "latest_sharex_ingest_response.json"
$response | ConvertTo-Json -Depth 20 | Set-Content -Path $logPath -Encoding UTF8
$response | ConvertTo-Json -Depth 20 | Set-Content -Path $latestPath -Encoding UTF8

Write-Host ("sharex_ingest ok: image={0}" -f $resolvedImage)
Write-Host ("record={0}" -f $response.record_path)
Write-Host ("preview={0}" -f $response.ocr_text_preview)
Write-Host ("response_log={0}" -f $logPath)
