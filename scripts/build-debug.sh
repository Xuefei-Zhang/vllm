#!/usr/bin/env bash
# Build vLLM from source with debug symbols + line info for runtime tracing.
#
# Strategy notes (read before running):
#   - CMAKE_BUILD_TYPE=RelWithDebInfo, NOT Debug.
#       * Debug forces nvcc -G (device debug) -> kernels 10x+ slower, may break
#         3rd-party kernels (cutlass / flashinfer / deep_gemm).
#       * RelWithDebInfo gives full symbols + line numbers, keeps optimization.
#   - We add -lineinfo (host-visible source line mapping for cuda-gdb / Nsight)
#     and -g (host-side C++ symbols) via CMAKE_ARGS.
#   - 4 parallel jobs, NVCC_THREADS=2 -> peak parallelism = 4*2 = 8 nvcc threads.
#     Safe for 30 GiB RAM if TORCH_CUDA_ARCH_LIST is restricted.
#   - TORCH_CUDA_ARCH_LIST="12.0" -> only Blackwell (RTX PRO 6000). Drops build
#     time + memory dramatically.
#   - VLLM_DISABLE_SCCACHE=1 unnecessary here (sccache not installed), kept
#     commented for awareness.
#
# Usage:
#   bash scripts/build-debug.sh           # full build
#   bash scripts/build-debug.sh clean     # wipe build/ first

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "clean" ]]; then
  echo "[build-debug] cleaning build/ and *.so artifacts..."
  rm -rf build/ vllm/_C*.so vllm/_moe_C*.so vllm/cumem_allocator*.so 2>/dev/null || true
fi

# --- Compile-time env vars ---
export CMAKE_BUILD_TYPE=RelWithDebInfo
export VERBOSE=1
export MAX_JOBS=4
export NVCC_THREADS=2
export CUDA_HOME=/usr/local/cuda
export TORCH_CUDA_ARCH_LIST="12.0"        # Blackwell only
# export VLLM_DISABLE_SCCACHE=1           # sccache not installed; uncomment if you install it

# Inject debug flags. -lineinfo for nvcc gives source-line mapping in cuda-gdb /
# Nsight without disabling optimizations. -g for host C++ keeps backtraces.
export CMAKE_ARGS="-DCMAKE_CUDA_FLAGS=-lineinfo -DCMAKE_CXX_FLAGS=-g"

# Activate venv (AGENTS.md mandates uv + .venv, never system python)
source .venv/bin/activate

echo "[build-debug] CMAKE_BUILD_TYPE=$CMAKE_BUILD_TYPE  MAX_JOBS=$MAX_JOBS  NVCC_THREADS=$NVCC_THREADS"
echo "[build-debug] TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"
echo "[build-debug] CMAKE_ARGS=$CMAKE_ARGS"
echo "[build-debug] starting editable install (this will take a while)..."

uv pip install -e . --torch-backend=auto 2>&1 | tee /tmp/vllm-build.log
