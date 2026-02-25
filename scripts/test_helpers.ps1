[CmdletBinding()]
param()

Set-StrictMode -Version Latest

function Get-RepoRoot {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptRoot
  )
  return (Resolve-Path (Join-Path $ScriptRoot "..")).Path
}

function Get-PythonExe {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot
  )
  $venvPython = Join-Path $RepoRoot ".venv\Scripts\python.exe"
  if (Test-Path $venvPython) {
    return $venvPython
  }
  return "python"
}

function Test-Endpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = 3
  )
  try {
    Invoke-RestMethod -Method Get -Uri $Uri -TimeoutSec $TimeoutSec | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

function Wait-Endpoint {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = 3,
    [int]$Attempts = 40,
    [int]$SleepMs = 500
  )
  for ($i = 0; $i -lt $Attempts; $i++) {
    if (Test-Endpoint -Uri $Uri -TimeoutSec $TimeoutSec) {
      return $true
    }
    Start-Sleep -Milliseconds $SleepMs
  }
  return $false
}

function Get-IsCloudPreset {
  param(
    [Parameter(Mandatory = $true)][string]$Preset
  )
  return $Preset -like "openai*"
}

function Ensure-TestServices {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PythonExe,
    [bool]$IsCloudPreset = $false
  )
  $state = @{
    StartedOllama = $false
    StartedBridge = $false
  }

  if (-not $IsCloudPreset) {
    if (-not (Test-Endpoint -Uri "http://127.0.0.1:11434/api/tags")) {
      Write-Host "Starting Ollama..."
      Start-Process -FilePath "ollama" -ArgumentList "serve" -WorkingDirectory $RepoRoot | Out-Null
      if (-not (Wait-Endpoint -Uri "http://127.0.0.1:11434/api/tags" -Attempts 60 -SleepMs 500)) {
        throw "Failed to start Ollama at http://127.0.0.1:11434"
      }
      $state.StartedOllama = $true
    }
  }

  if (-not (Test-Endpoint -Uri "http://127.0.0.1:8000/health")) {
    Write-Host "Starting bridge server..."
    Start-Process -FilePath $PythonExe -ArgumentList (Join-Path $RepoRoot "4_LLM_Bridge\bridge_server.py") -WorkingDirectory $RepoRoot | Out-Null
    if (-not (Wait-Endpoint -Uri "http://127.0.0.1:8000/health" -Attempts 60 -SleepMs 500)) {
      throw "Failed to start bridge server at http://127.0.0.1:8000"
    }
    $state.StartedBridge = $true
  }

  return $state
}

function Stop-TestServices {
  param(
    [Parameter(Mandatory = $true)][hashtable]$State
  )
  if ($State.StartedBridge) {
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*4_LLM_Bridge\\bridge_server.py*" } | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  if ($State.StartedOllama) {
    Get-CimInstance Win32_Process | Where-Object { $_.Name -like "ollama*" -and $_.CommandLine -like "*serve*" } | ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
}
