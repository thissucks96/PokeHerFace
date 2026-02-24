#!/usr/bin/env bash
set -euo pipefail

INSTALL_TOOLS=0
SKIP_PYTHON=0
SKIP_MODEL_CHECK=0
SKIP_LIBTORCH_CHECK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-tools) INSTALL_TOOLS=1; shift ;;
    --skip-python) SKIP_PYTHON=1; shift ;;
    --skip-model-check) SKIP_MODEL_CHECK=1; shift ;;
    --skip-libtorch-check) SKIP_LIBTORCH_CHECK=1; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

step() {
  echo
  echo "==> $1"
}

ok() {
  echo "[ok] $1"
}

warn() {
  echo "[warn] $1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

step "PokerBotV1 WSL/Linux bootstrap"
echo "Root: $ROOT_DIR"

step "Checking required workspace folders"
required_folders=(
  "1_Engine_Core"
  "2_Neural_Brain"
  "3_Hand_Histories"
  "4_LLM_Bridge"
  "libs"
)

for folder in "${required_folders[@]}"; do
  if [[ -d "$ROOT_DIR/$folder" ]]; then
    ok "$folder"
  else
    echo "Missing folder: $ROOT_DIR/$folder"
    exit 1
  fi
done

if [[ "$INSTALL_TOOLS" -eq 1 ]]; then
  step "Installing system packages"
  sudo apt-get update
  sudo apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    python3 \
    python3-venv \
    python3-pip \
    git \
    git-lfs \
    curl
  git lfs install
fi

step "Checking toolchain"
if has_cmd cmake; then ok "cmake found"; else warn "cmake missing (required for engine builds)"; fi
if has_cmd git; then ok "git found"; else warn "git missing"; fi
if has_cmd git-lfs; then ok "git-lfs found"; else warn "git-lfs missing"; fi
if has_cmd python3; then ok "python3 found"; else warn "python3 missing"; fi

step "Checking NVIDIA runtime visibility"
if has_cmd nvidia-smi; then
  ok "nvidia-smi found"
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
else
  warn "nvidia-smi missing. If using WSL GPU, ensure NVIDIA driver + WSL CUDA support are installed."
fi

if [[ "$SKIP_PYTHON" -eq 0 ]]; then
  step "Setting up Python virtual environment"
  VENV_PATH="$ROOT_DIR/.venv"
  if [[ ! -d "$VENV_PATH" ]]; then
    python3 -m venv "$VENV_PATH"
    ok "Created venv at $VENV_PATH"
  else
    ok ".venv already exists"
  fi

  "$VENV_PATH/bin/python" -m pip install --upgrade pip
  "$VENV_PATH/bin/python" -m pip install -r "$ROOT_DIR/requirements.txt"
  ok "Python requirements installed"

  if "$VENV_PATH/bin/python" -c "import torch; import sys; sys.exit(0 if torch.cuda.is_available() else 1)"; then
    ok "PyTorch CUDA is available in this environment"
  else
    warn "PyTorch CUDA is NOT available. Install a CUDA-enabled torch build from pytorch.org for RTX 4090 usage."
  fi
fi

if [[ "$SKIP_MODEL_CHECK" -eq 0 ]]; then
  step "Checking neural model artifacts"
  MODEL_ROOT="$ROOT_DIR/2_Neural_Brain/data/models"
  if [[ ! -d "$MODEL_ROOT" ]]; then
    warn "Model folder not found: $MODEL_ROOT"
  else
    count="$(find "$MODEL_ROOT" -type f \( -name '*.pt' -o -name '*.tar' \) | wc -l | tr -d ' ')"
    if [[ "$count" -gt 0 ]]; then
      ok "Found $count model files (.pt/.tar)"
    else
      warn "No .pt or .tar model files found under $MODEL_ROOT"
    fi
  fi
fi

if [[ "$SKIP_LIBTORCH_CHECK" -eq 0 ]]; then
  step "Checking LibTorch folder"
  TORCH_CONFIG="$ROOT_DIR/libs/libtorch/share/cmake/Torch/TorchConfig.cmake"
  if [[ -f "$TORCH_CONFIG" ]]; then
    ok "LibTorch detected"
  else
    warn "LibTorch not detected. Extract CUDA LibTorch to: $ROOT_DIR/libs/libtorch"
  fi
fi

step "Next command for C++ GPU bridge configure"
echo "cmake -S $ROOT_DIR/1_Engine_Core -B $ROOT_DIR/1_Engine_Core/build -DENABLE_LIBTORCH=ON -DLIBTORCH_ROOT=$ROOT_DIR/libs/libtorch"

step "Bootstrap complete"
