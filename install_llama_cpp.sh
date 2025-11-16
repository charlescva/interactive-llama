#!/usr/bin/env bash
#
# install_llama_cpp.sh
#
# 1. Clone the latest tagged (stable) llama.cpp from GitHub
# 2. Install C/C++ build tools via apt
# 3. Configure & build llama.cpp with CUDA (for NVIDIA GPUs, e.g. GTX 1070) in Release mode
# 4. Add llama.cpp build/bin to PATH and set env vars useful for future Rust/Python bindings

set -euo pipefail

#########################
# User-configurable vars
#########################

# Where to clone llama.cpp (change if you want it elsewhere)
LLAMA_CPP_ROOT="${LLAMA_CPP_ROOT:-$HOME/src/llama.cpp}"

# CUDA compute capability for GTX 1070 is 6.1 → 61
# If you use a different GPU later, adjust this or remove the flag.
CUDA_ARCHS="${CUDA_ARCHS:-61}"

#########################
# Helper functions
#########################

log() {
  printf '\n[llama-cpp] %s\n' "$*" >&2
}

#########################
# Step 1: Install build tools
#########################

if ! command -v apt-get >/dev/null 2>&1; then
  log "This script expects an apt-based system (Debian/Ubuntu). Aborting."
  exit 1
fi

log "Installing C/C++ build tools and git via apt..."
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  cmake \
  git \
  pkg-config

log "Core build tools installed."

#########################
# Step 2: Check for CUDA toolkit (optional but recommended)
#########################

if ! command -v nvcc >/dev/null 2>&1; then
  log "WARNING: 'nvcc' (CUDA toolkit) not found in PATH."
  log "llama.cpp with CUDA (-DGGML_CUDA=ON) requires the NVIDIA CUDA toolkit."
  log "If CMake fails later, install CUDA from NVIDIA or your distro and re-run this script."
else
  log "Detected CUDA toolkit:"
  nvcc --version || true
fi

#########################
# Step 3: Clone or update llama.cpp and checkout latest tag
#########################

log "Preparing llama.cpp directory at: $LLAMA_CPP_ROOT"

if [ -d "$LLAMA_CPP_ROOT/.git" ]; then
  log "Existing repo detected. Fetching latest changes and tags..."
  git -C "$LLAMA_CPP_ROOT" fetch --all --tags
else
  log "Cloning llama.cpp from GitHub..."
  mkdir -p "$(dirname "$LLAMA_CPP_ROOT")"
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_ROOT"
fi

cd "$LLAMA_CPP_ROOT"

log "Determining latest stable tag..."
LATEST_TAG="$(git tag --sort=-creatordate | head -n 1 || true)"

if [ -z "$LATEST_TAG" ]; then
  log "No tags found. Staying on default branch (master/main)."
else
  log "Checking out latest tag: $LATEST_TAG"
  git checkout "$LATEST_TAG"
fi

#########################
# Step 4: Configure & build with CUDA in Release mode
#########################

log "Configuring CMake build (Release, CUDA enabled, arch=${CUDA_ARCHS})..."

# Single-config generator (Unix Makefiles) → CMAKE_BUILD_TYPE used
# GGML_CUDA=ON enables NVIDIA GPU support
cmake -B build \
  -DLLAMA_CURL=OFF \
  -DGGML_CUDA=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}"

log "Building llama.cpp (this may take a while)..."

cmake --build build --config Release -- -j"$(nproc)"

log "Build finished. Binaries should be in: $LLAMA_CPP_ROOT/build/bin"

#########################
# Step 5: Add to PATH and set env vars for future use
#########################

BASHRC="$HOME/.bashrc"
ENV_MARKER="# >>> llama.cpp environment (added by install_llama_cpp.sh) >>>"
ENV_MARKER_END="# <<< llama.cpp environment <<<"

if grep -q "$ENV_MARKER" "$BASHRC" 2>/dev/null; then
  log "Environment block already present in $BASHRC. Skipping append."
else
  log "Adding llama.cpp environment block to $BASHRC..."

  {
    echo ""
    echo "$ENV_MARKER"
    echo "export LLAMA_CPP_ROOT=\"$LLAMA_CPP_ROOT\""
    echo "export PATH=\"\$LLAMA_CPP_ROOT/build/bin:\$PATH\""
    echo "export LD_LIBRARY_PATH=\"\$LLAMA_CPP_ROOT/build:\${LD_LIBRARY_PATH:-}\""
    # Generic library dir for Rust/Python bindings that expect a lib directory
    echo "export LLAMA_CPP_LIB_DIR=\"\$LLAMA_CPP_ROOT/build\""
    echo "$ENV_MARKER_END"
  } >> "$BASHRC"
fi

log "Setup complete."

cat <<EOF

======================================================================
llama.cpp has been cloned and built with CUDA (GGML_CUDA=ON) in Release.

Repo:      $LLAMA_CPP_ROOT
Binaries:  $LLAMA_CPP_ROOT/build/bin
Library:   $LLAMA_CPP_ROOT/build (libllama.*

Environment entries were added to: $BASHRC

To start using these settings in your current shell, run:

  source "$BASHRC"

You can then, for example:

  llama-server -h
  llama-cli -h

Rust/Python bindings can use:
  - LLAMA_CPP_ROOT
  - LLAMA_CPP_LIB_DIR
  - PATH / LD_LIBRARY_PATH pointing at the build outputs.
======================================================================
EOF

