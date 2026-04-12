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
    PYTHON_PATCH="${PYTHON_PATCH:-12}"
    PY_STANDALONE_TAG="${PY_STANDALONE_TAG:-20251120}"
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
        # AMD provides ROCm-native vllm wheels at rocm.frameworks.amd.com/whl/gfx1151/.
        # The PyPI vllm wheel is CUDA-only (_C.abi3.so links against libcudart.so.12
        # which does NOT exist on ROCm systems) — never use PyPI for vllm on ROCm!
        #
        # CRITICAL: AMD vllm requires torch==2.10.0. AMD's GFX1151 index has
        # torch-2.10.0+rocm7.12.0 (ROCm). PyPI also has torch==2.10.0+cu128 (CUDA).
        # Install order matters: install vllm first (gets CUDA torch from PyPI),
        # then REINSTALL torch from AMD's GFX1151 index to force the ROCm variant.
        # Without --reinstall the ROCm torch would be skipped (already "satisfied").
        ensureVenv
        runProtogen
        AMD_GFX1151="https://repo.amd.com/rocm/whl/gfx1151/"
        AMD_FRAMEWORKS="https://rocm.frameworks.amd.com/whl/gfx1151/"
        # Step 1: AMD ROCm vllm wheel + all deps (torch==2.10.0 gets CUDA here — fixed in Step 2)
        # unsafe-first-match: AMD index first, fall back to PyPI for non-vllm deps
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${AMD_FRAMEWORKS}" \
            --extra-index-url "${AMD_GFX1151}" \
            --extra-index-url https://pypi.org/simple/ \
            --index-strategy unsafe-first-match \
            vllm
        # Step 2: Force-reinstall torch from AMD's ROCm GFX1151 index (replaces CUDA torch)
        # AMD has torch-2.10.0+rocm7.12.0 at repo.amd.com/rocm/whl/gfx1151/
        # --reinstall is required because torch==2.10.0 is already "satisfied" by +cu128
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${AMD_GFX1151}" \
            --index-strategy first-match \
            --reinstall \
            "torch==2.10.0" \
            "torchaudio==2.10.0"
        # Step 3: grpcio + protogen re-run (vllm may have updated grpcio version)
        uv pip install --python "${EDIR}/venv/bin/python" \
            "grpcio>=1.60.0" protobuf 2>/dev/null || true
    else
        installRequirements
fi
