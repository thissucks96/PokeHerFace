[CmdletBinding()]
param(
  [string]$BuildDir = "1_Engine_Core\build_ninja_vcpkg_rel",
  [int]$LaunchTimeoutSec = 4
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ResolvedBuildDir = Join-Path $Root $BuildDir

$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Name, [bool]$Pass, [string]$Details) {
  $results.Add([PSCustomObject]@{
    Name    = $Name
    Pass    = $Pass
    Details = $Details
  }) | Out-Null
}

function Check-File([string]$Name, [string]$Path) {
  if (Test-Path $Path) {
    Add-Result $Name $true $Path
  } else {
    Add-Result $Name $false ("Missing: {0}" -f $Path)
  }
}

function Resolve-Tool([string]$Name, [string[]]$FallbackGlobs) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($cmd) {
    return [PSCustomObject]@{
      Found  = $true
      InPath = $true
      Path   = $cmd.Source
    }
  }

  foreach ($glob in $FallbackGlobs) {
    if ([string]::IsNullOrWhiteSpace($glob)) {
      continue
    }
    $hits = @(Get-ChildItem -Path $glob -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
    if ($hits.Count -gt 0) {
      return [PSCustomObject]@{
        Found  = $true
        InPath = $false
        Path   = $hits[0].FullName
      }
    }
  }

  return [PSCustomObject]@{
    Found  = $false
    InPath = $false
    Path   = ""
  }
}

Write-Host ""
Write-Host "==> PokerBotV1 preflight (Windows)" -ForegroundColor Cyan
Write-Host "Root: $Root"
Write-Host "BuildDir: $ResolvedBuildDir"

# Toolchain checks
$cmake = Resolve-Tool "cmake" @(
  "C:\Program Files\CMake\bin\cmake.exe"
)
$cmakeDetail = if ($cmake.Found) {
  if ($cmake.InPath) { $cmake.Path } else { "{0} (not on PATH in this shell)" -f $cmake.Path }
} else {
  "Install CMake and add to PATH."
}
Add-Result "cmake available" $cmake.Found $cmakeDetail

$cl = Resolve-Tool "cl" @(
  "C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe",
  "C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe"
)
$clDetail = if ($cl.Found) {
  if ($cl.InPath) { $cl.Path } else { "{0} (open Developer PowerShell for VS to load PATH)" -f $cl.Path }
} else {
  "Install Visual Studio Build Tools Desktop C++ workload."
}
Add-Result "MSVC cl.exe available" $cl.Found $clDetail

$nvccFallback = @(
  "$env:CUDA_PATH\bin\nvcc.exe",
  "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*\bin\nvcc.exe"
)
$nvcc = Resolve-Tool "nvcc" $nvccFallback
$nvccDetail = if ($nvcc.Found) {
  if ($nvcc.InPath) { $nvcc.Path } else { "{0} (not on PATH in this shell)" -f $nvcc.Path }
} else {
  "Install CUDA Toolkit and ensure nvcc is available."
}
Add-Result "CUDA nvcc available" $nvcc.Found $nvccDetail

$nvidiaSmi = Resolve-Tool "nvidia-smi" @(
  "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe",
  "C:\Windows\System32\nvidia-smi.exe",
  "C:\Windows\System32\DriverStore\FileRepository\nv*\nvidia-smi.exe"
)
$nvidiaSmiDetail = if ($nvidiaSmi.Found) {
  if ($nvidiaSmi.InPath) { $nvidiaSmi.Path } else { "{0} (not on PATH in this shell)" -f $nvidiaSmi.Path }
} else {
  "Ensure NVIDIA driver tools are installed."
}
Add-Result "nvidia-smi available" $nvidiaSmi.Found $nvidiaSmiDetail

# Python + torch CUDA probe
$venvPython = Join-Path $Root ".venv\Scripts\python.exe"
if (Test-Path $venvPython) {
  try {
    $probe = & $venvPython -c "import torch; print(torch.__version__); print('cuda=' + str(torch.cuda.is_available()))" 2>$null
    $probeText = ($probe | Out-String).Trim()
    $cudaAvailable = $probeText -match "cuda=True"
    Add-Result "Python torch CUDA probe" $cudaAvailable $probeText
  } catch {
    Add-Result "Python torch CUDA probe" $false $_.Exception.Message
  }
} else {
  Add-Result "Python torch CUDA probe" $false (".venv python missing: {0}" -f $venvPython)
}

# Core workspace assets
Check-File "LibTorch TorchConfig.cmake" (Join-Path $Root "libs\libtorch\share\cmake\Torch\TorchConfig.cmake")
Check-File "shark.exe" (Join-Path $ResolvedBuildDir "shark.exe")
Check-File "torch_cuda.dll staged" (Join-Path $ResolvedBuildDir "torch_cuda.dll")
Check-File "torch.dll staged" (Join-Path $ResolvedBuildDir "torch.dll")
Check-File "c10.dll staged" (Join-Path $ResolvedBuildDir "c10.dll")
Check-File "tbb12.dll staged" (Join-Path $ResolvedBuildDir "tbb12.dll")

$modelsPath = Join-Path $Root "2_Neural_Brain\data\models"
if (Test-Path $modelsPath) {
  $models = Get-ChildItem -Path $modelsPath -Recurse -File -Include *.pt,*.tar -ErrorAction SilentlyContinue
  $modelCount = if ($models) { $models.Count } else { 0 }
  Add-Result "Neural model artifacts present" ($modelCount -gt 0) ("Found {0} model files in {1}" -f $modelCount, $modelsPath)
} else {
  Add-Result "Neural model artifacts present" $false ("Missing folder: {0}" -f $modelsPath)
}

# shark.exe launch smoke check
$sharkExe = Join-Path $ResolvedBuildDir "shark.exe"
if (Test-Path $sharkExe) {
  try {
    $p = Start-Process -FilePath $sharkExe -PassThru
    Start-Sleep -Seconds $LaunchTimeoutSec
    if ($p.HasExited) {
      Add-Result "shark.exe launch smoke test" $false ("Exited early with code {0}" -f $p.ExitCode)
    } else {
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      Add-Result "shark.exe launch smoke test" $true ("Started and stayed alive for {0}s." -f $LaunchTimeoutSec)
    }
  } catch {
    Add-Result "shark.exe launch smoke test" $false $_.Exception.Message
  }
} else {
  Add-Result "shark.exe launch smoke test" $false "shark.exe missing."
}

Write-Host ""
Write-Host "==> Results" -ForegroundColor Cyan
foreach ($r in $results) {
  $marker = if ($r.Pass) { "[PASS]" } else { "[FAIL]" }
  if ($r.Pass) {
    Write-Host ("{0} {1} - {2}" -f $marker, $r.Name, $r.Details) -ForegroundColor Green
  } else {
    Write-Host ("{0} {1} - {2}" -f $marker, $r.Name, $r.Details) -ForegroundColor Red
  }
}

$failed = $results | Where-Object { -not $_.Pass }
Write-Host ""
if ($failed.Count -eq 0) {
  Write-Host "Preflight status: PASS" -ForegroundColor Green
  exit 0
}

Write-Host ("Preflight status: FAIL ({0} checks failed)" -f $failed.Count) -ForegroundColor Red
exit 1
