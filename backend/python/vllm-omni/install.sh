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
    # ROCm / HIP build for gfx1151 (Strix Halo):
    #
    # AMD provides ROCm-native vllm wheels at rocm.frameworks.amd.com/whl/gfx1151/.
    # The PyPI vllm wheel is CUDA-only (_C.abi3.so links against libcudart.so.12
    # which does NOT exist on ROCm systems) — never use PyPI for vllm on ROCm!
    #
    # Install order:
    # 1. AMD gfx1151-native torch (repo.amd.com) — must come first
    # 2. AMD ROCm vllm (rocm.frameworks.amd.com) — includes ROCm _C.abi3.so
    #    Use unsafe-first-match so AMD's index is preferred over PyPI
    # 3. Set PYTHONPATH for amdsmi (needed for vllm ROCm platform detection)
    AMD_GFX1151="https://repo.amd.com/rocm/whl/gfx1151/"
    AMD_FRAMEWORKS="https://rocm.frameworks.amd.com/whl/gfx1151/"
    if [ "x${USE_PIP}" == "xtrue" ]; then
        # Step 1: AMD gfx1151-native torch
        pip install --index-url "${AMD_GFX1151}" --extra-index-url https://pypi.org/simple/ \
            "torch==2.9.1" "torchaudio==2.9.1"
        # Step 2: AMD ROCm vllm wheel (includes ROCm-compiled _C.abi3.so — NOT PyPI CUDA wheel)
        pip install vllm --index-url "${AMD_FRAMEWORKS}" --extra-index-url https://pypi.org/simple/
        # Step 3: grpcio + protobuf (vllm may have updated versions)
        pip install "grpcio>=1.60.0" protobuf 2>/dev/null || true
    else
        # Step 1: AMD gfx1151-native torch
        uv pip install --index-url "${AMD_GFX1151}" \
            --extra-index-url https://pypi.org/simple/ \
            --index-strategy unsafe-best-match \
            "torch==2.9.1" "torchaudio==2.9.1"
        # Step 2: AMD ROCm vllm wheel (includes ROCm-compiled _C.abi3.so — NOT PyPI CUDA wheel)
        # unsafe-first-match: take from AMD index first, fall back to PyPI for non-vllm deps
        uv pip install --index-url "${AMD_FRAMEWORKS}" \
            --extra-index-url https://pypi.org/simple/ \
            --index-strategy unsafe-first-match \
            vllm
        # Step 3: grpcio + protobuf (vllm may have updated versions)
        uv pip install "grpcio>=1.60.0" protobuf 2>/dev/null || true
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
