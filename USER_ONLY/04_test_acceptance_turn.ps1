Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

& ".\scripts\test_acceptance.ps1" -Suite turn_class1 -Preset local_qwen3_coder_30b @args
