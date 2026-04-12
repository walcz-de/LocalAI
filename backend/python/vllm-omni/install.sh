#!/bin/bash
set -e

PYTHON_VERSION="3.12"
PYTHON_PATCH="12"
PY_STANDALONE_TAG="20251120"

backend_dir=$(dirname $0)
if [ -d $backend_dir/common ]; then
    source $backend_dir/common/libbackend.sh
else
    source $backend_dir/../common/libbackend.sh
fi

# Handle l4t build profiles (Python 3.12, pip fallback) if needed
if [ "x${BUILD_PROFILE}" == "xl4t13" ]; then
  PYTHON_VERSION="3.12"
  PYTHON_PATCH="12"
  PY_STANDALONE_TAG="20251120"
fi

if [ "x${BUILD_PROFILE}" == "xl4t12" ]; then
    USE_PIP=true
fi

# Install base requirements first
installRequirements

# Install vllm based on build type
if [ "x${BUILD_TYPE}" == "xhipblas" ]; then
    # ROCm: AMD gfx1151-native torch first, then vllm ROCm wheel without deps.
    AMD_GFX1151="https://rocm.prereleases.amd.com/whl/gfx1151/"
    ROCM_VLLM_INDEX="https://wheels.vllm.ai/rocm/0.19.0/rocm721"
    if [ "x${USE_PIP}" == "xtrue" ]; then
        pip install --index-url "${AMD_GFX1151}" --extra-index-url https://pypi.org/simple/ \
            "torch==2.10.0+rocm7.12.0rc1" "torchaudio==2.10.0+rocm7.12.0rc1"
        pip install vllm --index-url "${ROCM_VLLM_INDEX}" --no-deps
        pip install amd-aiter flash-attn triton --index-url "${ROCM_VLLM_INDEX}" \
            --extra-index-url https://pypi.org/simple/ 2>/dev/null || true
    else
        uv pip install --index-url "${AMD_GFX1151}" --extra-index-url https://pypi.org/simple/ \
            "torch==2.10.0+rocm7.12.0rc1" "torchaudio==2.10.0+rocm7.12.0rc1"
        uv pip install vllm --index-url "${ROCM_VLLM_INDEX}" --no-deps
        uv pip install amd-aiter flash-attn triton --index-url "${ROCM_VLLM_INDEX}" \
            --extra-index-url https://pypi.org/simple/ 2>/dev/null || true
    fi
elif [ "x${BUILD_TYPE}" == "xcublas" ] || [ "x${BUILD_TYPE}" == "x" ]; then
    # CUDA (default) or CPU
    if [ "x${USE_PIP}" == "xtrue" ]; then
        pip install vllm==0.14.0 --torch-backend=auto
    else
        uv pip install vllm==0.14.0 --torch-backend=auto
    fi
else
    echo "Unsupported build type: ${BUILD_TYPE}" >&2
    exit 1
fi

# Clone and install vllm-omni from source
if [ ! -d vllm-omni ]; then
    git clone https://github.com/vllm-project/vllm-omni.git
fi

cd vllm-omni/

if [ "x${USE_PIP}" == "xtrue" ]; then
    pip install ${EXTRA_PIP_INSTALL_FLAGS:-} -e .
else
    uv pip install ${EXTRA_PIP_INSTALL_FLAGS:-} -e .
fi

cd ..
