[CmdletBinding()]
param(
  [switch]$InstallTools,
  [switch]$SkipPython,
  [switch]$SkipModelCheck,
  [switch]$SkipLibTorchCheck
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Write-Step([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
  Write-Host "[ok] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
  Write-Host "[warn] $Message" -ForegroundColor Yellow
}

function Has-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-CMake() {
  if (Has-Command "cmake") {
    return "cmake"
  }
  $DefaultCMake = "C:\Program Files\CMake\bin\cmake.exe"
  if (Test-Path $DefaultCMake) {
    return $DefaultCMake
  }
  return $null
}

function Install-WithWinget([string]$PackageId) {
  $CommonArgs = @(
    "--accept-package-agreements",
    "--accept-source-agreements",
    "-e",
    "--no-upgrade",
    "--silent",
    "--disable-interactivity"
  )
  $Output = winget install --id $PackageId @CommonArgs 2>&1
  $ExitCode = $LASTEXITCODE
  if ($ExitCode -ne 0) {
    $Text = ($Output | Out-String)
    if ($Text -match "No available upgrade found|No newer package versions are available|already installed|Installation cancelled") {
      Write-Ok "Package already current: $PackageId"
      return
    }
    $Output | Write-Host
    throw "winget install failed for package id: $PackageId"
  }
}

Write-Step "PokerBotV1 Windows bootstrap"
Write-Host "Root: $Root"

Write-Step "Checking required workspace folders"
$RequiredFolders = @(
  "1_Engine_Core",
  "2_Neural_Brain",
  "3_Hand_Histories",
  "4_LLM_Bridge",
  "libs"
)

foreach ($Folder in $RequiredFolders) {
  $Path = Join-Path $Root $Folder
  if (Test-Path $Path) {
    Write-Ok $Folder
  } else {
    throw "Missing folder: $Path"
  }
}

Write-Step "Checking toolchain"
if ($InstallTools) {
  if (-not (Has-Command "winget")) {
    throw "winget is required for -InstallTools but was not found."
  }

  Write-Host "Installing CMake, Git, and Git LFS with winget..."
  Install-WithWinget "Kitware.CMake"
  Install-WithWinget "Git.Git"
  Install-WithWinget "GitHub.GitLFS"

  $DefaultCMakeBin = "C:\Program Files\CMake\bin"
  if ((Test-Path "$DefaultCMakeBin\cmake.exe") -and ($env:Path -notlike "*$DefaultCMakeBin*")) {
    $env:Path = "$DefaultCMakeBin;$env:Path"
    Write-Ok "Added CMake bin to current session PATH: $DefaultCMakeBin"
  }

  if (Has-Command "git-lfs") {
    git lfs install | Out-Null
    Write-Ok "Initialized Git LFS"
  }
}

$CMakeExe = Resolve-CMake
if ($null -ne $CMakeExe) {
  if ($CMakeExe -eq "cmake") {
    Write-Ok "cmake found in PATH"
  } else {
    Write-Ok "cmake found at $CMakeExe (PATH may update in new shell)"
  }
} else {
  Write-Warn "cmake missing (required for engine builds)"
}
if (Has-Command "git") { Write-Ok "git found" } else { Write-Warn "git missing" }
if (Has-Command "git-lfs") { Write-Ok "git-lfs found" } else { Write-Warn "git-lfs missing (needed for large model/data pulls)" }
if (Has-Command "cl") { Write-Ok "MSVC cl.exe found" } else { Write-Warn "MSVC compiler not found in PATH (install Visual Studio Build Tools + C++ workload)" }
if (Has-Command "nmake") { Write-Ok "nmake found" } else { Write-Warn "nmake not found (configure from a VS Developer shell, or use Ninja + MSVC)" }

Write-Step "Checking NVIDIA GPU access"
if (Has-Command "nvidia-smi") {
  Write-Ok "nvidia-smi found"
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
} else {
  Write-Warn "nvidia-smi missing. GPU runtime/driver may not be available in PATH."
}

if (-not $SkipPython) {
  Write-Step "Setting up Python virtual environment"

  $PythonExe = $null
  if (Has-Command "py") {
    $PythonExe = "py"
  } elseif (Has-Command "python") {
    $PythonExe = "python"
  } else {
    throw "Python launcher not found. Install Python 3.10+."
  }

  $VenvPath = Join-Path $Root ".venv"
  if (-not (Test-Path $VenvPath)) {
    Write-Host "Creating venv at $VenvPath"
    if ($PythonExe -eq "py") {
      py -3 -m venv $VenvPath
    } else {
      python -m venv $VenvPath
    }
  } else {
    Write-Ok ".venv already exists"
  }

  $VenvPython = Join-Path $VenvPath "Scripts\python.exe"
  if (-not (Test-Path $VenvPython)) {
    throw "Virtualenv python not found at $VenvPython"
  }

  & $VenvPython -m pip install --upgrade pip
  & $VenvPython -m pip install -r (Join-Path $Root "requirements.txt")
  Write-Ok "Python requirements installed"

  $PrevNativeErrorMode = $PSNativeCommandUseErrorActionPreference
  $PSNativeCommandUseErrorActionPreference = $false
  try {
    $CudaProbe = (& $VenvPython -c "import torch; import sys; sys.stdout.write('1' if torch.cuda.is_available() else '0')" 2>&1 | Out-String).Trim()
    $CudaExit = $LASTEXITCODE
  } finally {
    $PSNativeCommandUseErrorActionPreference = $PrevNativeErrorMode
  }

  if ($CudaExit -eq 0 -and $CudaProbe -match "1") {
    Write-Ok "PyTorch CUDA is available in this environment"
  } else {
    Write-Warn "PyTorch CUDA is NOT available. Install a CUDA-enabled torch build from pytorch.org for RTX 4090 usage."
  }
}

if (-not $SkipModelCheck) {
  Write-Step "Checking neural model artifacts"
  $ModelRoot = Join-Path $Root "2_Neural_Brain\data\models"
  if (-not (Test-Path $ModelRoot)) {
    Write-Warn "Model folder not found: $ModelRoot"
  } else {
    $ModelFiles = Get-ChildItem -Path $ModelRoot -Recurse -File -Include *.pt,*.tar -ErrorAction SilentlyContinue
    if ($ModelFiles.Count -gt 0) {
      Write-Ok ("Found {0} model files (.pt/.tar)" -f $ModelFiles.Count)
    } else {
      Write-Warn "No .pt or .tar model files found under $ModelRoot"
    }
  }
}

if (-not $SkipLibTorchCheck) {
  Write-Step "Checking LibTorch folder"
  $TorchConfig = Join-Path $Root "libs\libtorch\share\cmake\Torch\TorchConfig.cmake"
  if (Test-Path $TorchConfig) {
    Write-Ok "LibTorch detected"
  } else {
    Write-Warn "LibTorch not detected. Extract CUDA LibTorch to: $($Root)\libs\libtorch"
  }
}

Write-Step "Next command for C++ GPU bridge configure"
$CMakeForCmd = if ($null -ne $CMakeExe) { "`"$CMakeExe`"" } else { "cmake" }
$BridgeCmd = @"
$CMakeForCmd -S $Root\1_Engine_Core -B $Root\1_Engine_Core\build -DENABLE_LIBTORCH=ON -DLIBTORCH_ROOT=$Root\libs\libtorch
"@
Write-Host $BridgeCmd

Write-Step "Bootstrap complete"
