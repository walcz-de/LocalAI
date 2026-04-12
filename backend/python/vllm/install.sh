#!/bin/bash
set -e

EXTRA_PIP_INSTALL_FLAGS="--no-build-isolation"

# Avoid to overcommit the CPU during build
# https://github.com/vllm-project/vllm/issues/20079
# https://docs.vllm.ai/en/v0.8.3/serving/env_vars.html
# https://docs.redhat.com/it/documentation/red_hat_ai_inference_server/3.0/html/vllm_server_arguments/environment_variables-server-arguments
export NVCC_THREADS=2
export MAX_JOBS=1

# For ROCm: vllm's official ROCm wheels are built for Python 3.12 only.
# Switch the portable Python to 3.12 so we can use the pre-built ROCm wheel.
if [ "x${BUILD_TYPE}" == "xhipblas" ]; then
    PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
    PYTHON_PATCH="${PYTHON_PATCH:-13}"
    PY_STANDALONE_TAG="${PY_STANDALONE_TAG:-20250818}"
fi

backend_dir=$(dirname $0)

if [ -d $backend_dir/common ]; then
    source $backend_dir/common/libbackend.sh
else
    source $backend_dir/../common/libbackend.sh
fi

# This is here because the Intel pip index is broken and returns 200 status codes for every package name, it just doesn't return any package links.
# This makes uv think that the package exists in the Intel pip index, and by default it stops looking at other pip indexes once it finds a match.
# We need uv to continue falling through to the pypi default index to find optimum[openvino] in the pypi index
# the --upgrade actually allows us to *downgrade* torch to the version provided in the Intel pip index
if [ "x${BUILD_PROFILE}" == "xintel" ]; then
    EXTRA_PIP_INSTALL_FLAGS+=" --upgrade --index-strategy=unsafe-first-match"
fi

# We don't embed this into the images as it is a large dependency and not always needed.
# Besides, the speed inference are not actually usable in the current state for production use-cases.
if [ "x${BUILD_TYPE}" == "x" ] && [ "x${FROM_SOURCE:-}" == "xtrue" ]; then
        ensureVenv
        # https://docs.vllm.ai/en/v0.6.1/getting_started/cpu-installation.html
        if [ ! -d vllm ]; then
            git clone https://github.com/vllm-project/vllm
        fi
        pushd vllm
            uv pip install wheel packaging ninja "setuptools>=49.4.0" numpy typing-extensions pillow setuptools-scm grpcio==1.68.1 protobuf bitsandbytes
            uv pip install -v -r requirements-cpu.txt --extra-index-url https://download.pytorch.org/whl/cpu
            VLLM_TARGET_DEVICE=cpu python setup.py install
        popd
        rm -rf vllm
elif [ "x${BUILD_TYPE}" == "xhipblas" ]; then
        # ROCm / HIP build for gfx1151 (Strix Halo):
        #
        # Step 1: Install AMD's gfx1151-native torch (rocm7.12.0rc1) first.
        #   AMD provides pre-built cp312 wheels at rocm.prereleases.amd.com/whl/gfx1151/.
        #   This is the correct, hardware-native torch — better than the generic rocm7.x wheels.
        #
        # Step 2: Install vllm 0.19.0 ROCm wheel from wheels.vllm.ai with --no-deps
        #   so it does NOT pull its own torch. The AMD gfx1151 torch already installed
        #   satisfies vllm's Requires-Dist: torch==2.10.0 (PEP 440: local versions excluded
        #   from version comparisons, so 2.10.0+rocm7.12.0rc1 == 2.10.0 is TRUE).
        #
        # The PyPI vllm wheel is CUDA-only. vllm C extensions from wheels.vllm.ai/rocm721
        # link against libtorch_hip and ROCm runtime libs — ABI-compatible with AMD's torch.
        ensureVenv
        runProtogen
        AMD_GFX1151="https://rocm.prereleases.amd.com/whl/gfx1151/"
        ROCM_VLLM_INDEX="https://wheels.vllm.ai/rocm/0.19.0/rocm721"
        # Step 1: AMD gfx1151-native torch
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${AMD_GFX1151}" \
            --extra-index-url https://pypi.org/simple/ \
            "torch==2.10.0+rocm7.12.0rc1" \
            "torchaudio==2.10.0+rocm7.12.0rc1"
        # Step 2: non-torch/vllm deps from PyPI
        uv pip install --python "${EDIR}/venv/bin/python" \
            grpcio==1.80.0 protobuf certifi setuptools \
            accelerate transformers bitsandbytes amdsmi
        # Step 3: vllm ROCm wheel WITHOUT deps (preserves AMD torch, not the vllm-bundled torch)
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${ROCM_VLLM_INDEX}" \
            --no-deps \
            vllm
        # Step 4: vllm's non-torch deps (flash-attn, triton, etc.) from the ROCm index
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${ROCM_VLLM_INDEX}" \
            --extra-index-url https://pypi.org/simple/ \
            --no-binary vllm \
            amd-aiter flash-attn triton 2>/dev/null || \
        echo "Optional ROCm deps (flash-attn/triton) not available, skipping"
    else
        installRequirements
fi
