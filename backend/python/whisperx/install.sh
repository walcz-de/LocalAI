#!/bin/bash
set -e

backend_dir=$(dirname $0)
if [ -d $backend_dir/common ]; then
    source $backend_dir/common/libbackend.sh
else
    source $backend_dir/../common/libbackend.sh
fi

if [ "x${BUILD_PROFILE}" == "xl4t13" ]; then
  PYTHON_VERSION="3.12"
  PYTHON_PATCH="12"
  PY_STANDALONE_TAG="20251120"
fi

if [ "x${BUILD_PROFILE}" == "xl4t12" ]; then
    USE_PIP=true
fi

# --index-strategy is a uv-only flag; skip it when using pip
if [ "x${USE_PIP}" != "xtrue" ]; then
    if [ "x${BUILD_PROFILE}" != "xmetal" ] && [ "x${BUILD_PROFILE}" != "xmps" ]; then
        EXTRA_PIP_INSTALL_FLAGS+=" --index-strategy unsafe-best-match"
    fi
fi

# ROCm: torch per GPU arch, BEFORE installRequirements (same pattern as the
# diffusers and rerankers backends).
#
# There was NO hipblas profile at all until 2026-08-31 -- no requirements-hipblas.txt
# existed, so a BUILD_TYPE=hipblas build installed only requirements.txt (grpcio,
# protobuf, grpcio-tools) and produced a backend whose venv held exactly
# google/grpc/grpc_tools/setuptools: no torch, no whisperx, nothing that can
# transcribe. It started, answered gRPC, and could never do its job.
#
# Index: stable.repo.amd.com/rocm/whl-next (ROCm 10), the one AMD's own ROCm 10
# container carries as PIP_EXTRA_INDEX_URL. torchvision tracks torch: 2.11->0.26.
#
# KNOWN LIMIT: whisperX's fast path is faster-whisper/ctranslate2, which has no
# ROCm backend -- that part stays on CPU. torch here covers alignment and
# diarization. Do not read "hipblas profile exists" as "fully GPU accelerated".
if [ "x${BUILD_PROFILE}" == "xhipblas" ]; then
    _gpu_arch="${AMDGPU_TARGETS:-gfx1151}"; _gpu_arch="${_gpu_arch%%;*}"; _gpu_arch="${_gpu_arch%% *}"
    ensureVenv
    uv pip install --index-url https://stable.repo.amd.com/rocm/whl-next \
        "torch[device-${_gpu_arch}]==2.11.0+rocm10.0.0" \
        "torchvision==0.26.0+rocm10.0.0"
fi

installRequirements
