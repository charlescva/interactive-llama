#!/usr/bin/env bash
# install_cuda_debian_gtx1070.sh
#
# Installs the NVIDIA CUDA toolkit on a Debian (apt-based) system,
# ensuring a CUDA version that supports GeForce GTX 1070 Mobile (Pascal, sm_61),
# and sets environment variables for future builds (e.g., llama.cpp, Rust/Python bindings).

set -euo pipefail

log() {
  printf "\n[cuda-setup] %s\n" "$*" >&2
}

#########################
# 0. Basic sanity checks
#########################

if ! command -v apt-get >/dev/null 2>&1; then
  log "This script expects an apt-based system (Debian). Aborting."
  exit 1
fi

OS_ID="unknown"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  log "Detected OS: ID=${OS_ID}, PRETTY_NAME=${PRETTY_NAME:-unknown}"
else
  log "WARNING: /etc/os-release not found; proceeding assuming Debian-like system."
fi

if [ "$OS_ID" != "debian" ]; then
  log "WARNING: OS ID is '${OS_ID}', not 'debian'. Proceeding anyway, but this script was written for Debian."
fi

#########################
# 1. If nvcc already exists, just validate
#########################

if command -v nvcc >/dev/null 2>&1; then
  log "CUDA toolkit already detected on this system."
  nvcc --version || true

  NVCC_VER_STR="$(nvcc --version | grep -i 'release' || true)"
  if [ -n "$NVCC_VER_STR" ]; then
    CUDA_MAJOR="$(echo "$NVCC_VER_STR" | sed -E 's/.*release ([0-9]+)\..*/\1/')"
    log "Detected CUDA major version: $CUDA_MAJOR"
    if [ "$CUDA_MAJOR" -lt 8 ]; then
      log "WARNING: CUDA version appears to be < 8. Pascal (GTX 1070) support starts with CUDA 8."
      log "Consider upgrading CUDA to a newer version (e.g., 11 or 12)."
    else
      log "CUDA version is >= 8, which supports GeForce GTX 1070 Mobile (Pascal, sm_61)."
    fi
  else
    log "WARNING: Could not parse CUDA version from nvcc output."
  fi

  log "No further CUDA installation needed. If you want to force reinstall, remove nvcc and rerun."
  exit 0
fi

#########################
# 2. Inform about NVIDIA driver (not installed here)
#########################

log "NOTE: This script does NOT install the NVIDIA driver on Debian."
log "      Make sure you have a suitable NVIDIA driver installed for the GTX 1070 Mobile."
log "      On Debian, that is typically from the 'nvidia-driver' package in non-free/non-free-firmware."

#########################
# 3. Install CUDA toolkit from apt
#########################

log "Installing CUDA toolkit via apt (nvidia-cuda-toolkit)..."
sudo apt-get update
sudo apt-get install -y nvidia-cuda-toolkit

if ! command -v nvcc >/dev/null 2>&1; then
  log "ERROR: nvcc still not found after installing nvidia-cuda-toolkit."
  log "You may need to add CUDA to PATH manually or install CUDA from NVIDIA's official packages."
  exit 1
fi

log "nvcc detected after installation:"
nvcc --version || true

#########################
# 4. Validate CUDA version for GTX 1070 Mobile (Pascal, sm_61)
#########################

NVCC_VER_STR="$(nvcc --version | grep -i 'release' || true)"
CUDA_MAJOR=""
if [ -n "$NVCC_VER_STR" ]; then
  CUDA_MAJOR="$(echo "$NVCC_VER_STR" | sed -E 's/.*release ([0-9]+)\..*/\1/')"
  log "Detected CUDA major version: $CUDA_MAJOR"
else
  log "WARNING: Could not parse CUDA version from nvcc output."
fi

if [ -n "$CUDA_MAJOR" ] && [ "$CUDA_MAJOR" -lt 8 ]; then
  log "WARNING: CUDA version appears to be < 8. Pascal (GTX 1070) support starts with CUDA 8."
  log "The GTX 1070 Mobile may not be fully supported by this CUDA version."
else
  log "CUDA version is >= 8, which supports GeForce GTX 1070 Mobile (Pascal, compute capability 6.1)."
fi

#########################
# 5. Add CUDA environment variables
#########################

BASHRC="$HOME/.bashrc"
ENV_MARKER="# >>> CUDA environment (added by install_cuda_debian_gtx1070.sh) >>>"
ENV_MARKER_END="# <<< CUDA environment <<<"

if grep -q "$ENV_MARKER" "$BASHRC" 2>/dev/null; then
  log "CUDA environment block already present in $BASHRC. Skipping append."
else
  log "Adding CUDA environment block to $BASHRC..."

  # On Debian, nvidia-cuda-toolkit typically installs binaries in /usr/bin
  # and libraries into /usr/lib/x86_64-linux-gnu, plus some CUDA-specific dirs.
  CUDA_DEFAULT_HOME="/usr"

  {
    echo ""
    echo "$ENV_MARKER"
    echo "# Base path where CUDA binaries and libs are expected on Debian"
    echo "export CUDA_HOME=\"$CUDA_DEFAULT_HOME\""
    echo "export PATH=\"\$CUDA_HOME/bin:\$PATH\""
    echo "export LD_LIBRARY_PATH=\"/usr/lib/x86_64-linux-gnu:\$CUDA_HOME/lib:\$CUDA_HOME/lib64:\${LD_LIBRARY_PATH:-}\""
    echo "# For future builds (e.g., llama.cpp) targeting GTX 1070 (Pascal, sm_61):"
    echo "export LLAMA_CUDA_ARCHS=\"61\""
    echo "$ENV_MARKER_END"
  } >> "$BASHRC"
fi

log "CUDA toolkit setup complete."

cat <<EOF

======================================================================
CUDA toolkit installation finished for Debian.

nvcc location:  $(command -v nvcc || echo "not found in PATH")
nvcc version:   $(nvcc --version 2>/dev/null | grep -i "release" || echo "unknown")

Environment entries were added to: $BASHRC

To start using these settings in your current shell, run:

  source "$BASHRC"

Notes:
- GeForce GTX 1070 Mobile is a Pascal GPU (compute capability 6.1, sm_61).
- Pascal GPUs are supported by CUDA versions >= 8.
- When building llama.cpp with CUDA for this GPU, you can use:
    -DCMAKE_CUDA_ARCHITECTURES=61

Next step:
- Once this is done and the NVIDIA driver is working, run your llama.cpp install script
  to build llama.cpp with CUDA support.
======================================================================
EOF

