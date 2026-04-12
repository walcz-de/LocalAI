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
    # The AMD vllm is a DEV/pre-release (0.16.1.dev10+rocm712) that links against
    # libtorch_hip.so — NO libcudart.so.12 needed. Never use PyPI vllm on ROCm:
    # the PyPI vllm wheel links against libcudart.so.12 (NVIDIA CUDA) which doesn't
    # exist on AMD systems.
    #
    # AMD vllm does NOT declare torch as a Requires-Dist, so we install torch
    # explicitly from AMD's GFX1151 index (torch-2.10.0+rocm7.12.0).
    # flash-attn==2.8.3 is required by AMD vllm and has an AMD-specific pure-py wheel.
    AMD_GFX1151="https://repo.amd.com/rocm/whl/gfx1151/"
    AMD_FRAMEWORKS="https://rocm.frameworks.amd.com/whl/gfx1151/"
    if [ "x${USE_PIP}" == "xtrue" ]; then
        # Step 1: AMD ROCm torch (HIP variant) — must match AMD vllm 0.16.1 ABI (torch 2.9.1)
        pip install --index-url "${AMD_GFX1151}" \
            "torch==2.9.1+rocm7.12.0"
        # Step 2: AMD ROCm vllm (pre-release, --pre required)
        pip install --index-url "${AMD_FRAMEWORKS}" \
            --extra-index-url https://pypi.org/simple/ \
            --pre vllm
        # Step 3: AMD flash-attn
        pip install --index-url "${AMD_FRAMEWORKS}" "flash-attn==2.8.3"
        # Step 4: grpcio + protobuf
        pip install "grpcio>=1.60.0" protobuf 2>/dev/null || true
    else
        # Step 1: AMD ROCm torch (HIP variant)
        # NOTE: AMD vllm 0.16.1 was built against torch 2.9.1+rocm7.12.0.
        # torch 2.10.0 changed c10_hip_check_implementation signature (ABI break).
        uv pip install --index-url "${AMD_GFX1151}" \
            --index-strategy first-match \
            "torch==2.9.1+rocm7.12.0"
        # Step 2: AMD ROCm vllm (pre-release — requires --pre; deps from PyPI fallback)
        uv pip install --index-url "${AMD_FRAMEWORKS}" \
            --extra-index-url https://pypi.org/simple/ \
            --index-strategy unsafe-first-match \
            --pre \
            vllm
        # Step 3: AMD flash-attn (pure-py wheel at AMD frameworks index)
        uv pip install --index-url "${AMD_FRAMEWORKS}" \
            --index-strategy first-match \
            "flash-attn==2.8.3"
        # Step 4: grpcio + protobuf
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

# Patch vllm platform detection for ROCm container environments (hipblas only)
# (a) __init__.py: fall back to torch.version.hip when amdsmi is unavailable
# (b) rocm.py: replace logger.warning_once with logger.debug to avoid circular import
if [ "x${BUILD_TYPE}" == "xhipblas" ]; then
    VLLM_PLATFORMS="${EDIR}/venv/lib/python3.12/site-packages/vllm/platforms"
    VLLM_INIT="${VLLM_PLATFORMS}/__init__.py"
    VLLM_ROCM="${VLLM_PLATFORMS}/rocm.py"
    export VLLM_INIT VLLM_ROCM
    "${EDIR}/venv/bin/python" -c "
import os, sys
path = os.environ['VLLM_INIT']
src = open(path).read()
old = '    except Exception as e:\n        logger.debug(\"ROCm platform is not available because: %s\", str(e))\n\n    return \"vllm.platforms.rocm.RocmPlatform\" if is_rocm else None'
new = '    except Exception as e:\n        logger.debug(\"amdsmi check failed (%s); falling back to torch.version.hip\", str(e))\n\n    if not is_rocm:\n        try:\n            import torch\n            if getattr(torch.version, \"hip\", None) is not None:\n                is_rocm = True\n                logger.debug(\"Confirmed ROCm platform via torch.version.hip.\")\n        except Exception:\n            pass\n\n    return \"vllm.platforms.rocm.RocmPlatform\" if is_rocm else None'
if old in src:
    open(path, 'w').write(src.replace(old, new, 1))
    print('Patched __init__.py: torch.version.hip fallback added')
else:
    print('__init__.py: already patched or pattern not found, skipping')
" 2>&1 || true
    "${EDIR}/venv/bin/python" -c "
import os, sys
path = os.environ['VLLM_ROCM']
src = open(path).read()
old = '        logger.warning_once(\n            \"Failed to get GCN arch via amdsmi, falling back to torch.cuda. \"\n            \"This will initialize CUDA and may cause \"\n            \"issues if CUDA_VISIBLE_DEVICES is not set yet.\"\n        )'
new = '        logger.debug(\n            \"Failed to get GCN arch via amdsmi; falling back to torch.cuda.\"\n        )'
if old in src:
    open(path, 'w').write(src.replace(old, new, 1))
    print('Patched rocm.py: warning_once replaced with debug')
else:
    print('rocm.py: already patched or pattern not found, skipping')
" 2>&1 || true
    # Patch (c): torch_c_dlpack_ext — use cpu variant on AMD ROCm
    DLPACK_CORE="${EDIR}/venv/lib/python3.12/site-packages/torch_c_dlpack_ext/core.py"
    export DLPACK_CORE
    if [ -f "${DLPACK_CORE}" ]; then
        "${EDIR}/venv/bin/python" -c "
import os
path = os.environ['DLPACK_CORE']
src = open(path).read()
old = '    suffix = \"cuda\" if torch.cuda.is_available() else \"cpu\"'
new = '    is_rocm = getattr(torch.version, \"hip\", None) is not None\n    suffix = \"cpu\" if is_rocm else (\"cuda\" if torch.cuda.is_available() else \"cpu\")'
if old in src:
    open(path, 'w').write(src.replace(old, new, 1))
    print('Patched torch_c_dlpack_ext/core.py: use cpu variant on AMD ROCm')
else:
    print('torch_c_dlpack_ext/core.py: already patched or pattern not found, skipping')
" 2>&1 || true
    fi
    # Create libtorch_cuda.so / libc10_cuda.so symlinks pointing to HIP equivalents
    TORCH_LIB="${EDIR}/venv/lib/python3.12/site-packages/torch/lib"
    ln -sf "${TORCH_LIB}/libtorch_hip.so" "${TORCH_LIB}/libtorch_cuda.so" 2>/dev/null || true
    ln -sf "${TORCH_LIB}/libc10_hip.so"   "${TORCH_LIB}/libc10_cuda.so"   2>/dev/null || true
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
