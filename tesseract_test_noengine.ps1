[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$priorAutoStart = $null
$hadPriorAutoStart = $false
try {
  if (Test-Path Env:\BACKEND_AUTOSTART) {
    $hadPriorAutoStart = $true
    $priorAutoStart = [string]$env:BACKEND_AUTOSTART
  }
  $env:BACKEND_AUTOSTART = "0"
  & (Join-Path $PSScriptRoot "tesseract_test.ps1")
}
finally {
  if ($hadPriorAutoStart) {
    $env:BACKEND_AUTOSTART = $priorAutoStart
  }
  else {
    Remove-Item Env:\BACKEND_AUTOSTART -ErrorAction SilentlyContinue
  }
}
