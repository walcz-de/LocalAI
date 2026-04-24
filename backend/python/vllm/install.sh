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

# CPU builds need unsafe-best-match to pull torch==2.10.0+cpu from the
# pytorch test channel while still resolving transformers/vllm from pypi.
if [ "x${BUILD_PROFILE}" == "xcpu" ]; then
    EXTRA_PIP_INSTALL_FLAGS+=" --index-strategy=unsafe-best-match"
fi

# FROM_SOURCE=true on a CPU build skips the prebuilt vllm wheel in
# requirements-cpu-after.txt and compiles vllm locally against the host's
# actual CPU. Not used by default because it takes ~30-40 minutes, but
# kept here for hosts where the prebuilt wheel SIGILLs (CPU without the
# required SIMD baseline, e.g. AVX-512 VNNI/BF16). Default CI uses a
# bigger-runner with compatible hardware instead.
if [ "x${BUILD_TYPE}" == "x" ] && [ "x${FROM_SOURCE:-}" == "xtrue" ]; then
    # Temporarily hide the prebuilt wheel so installRequirements doesn't
    # pull it — the rest of the requirements files (base deps, torch,
    # transformers) are still installed normally.
    _cpu_after="${backend_dir}/requirements-cpu-after.txt"
    _cpu_after_bak=""
    if [ -f "${_cpu_after}" ]; then
        _cpu_after_bak="${_cpu_after}.from-source.bak"
        mv "${_cpu_after}" "${_cpu_after_bak}"
    fi
    installRequirements
    if [ -n "${_cpu_after_bak}" ]; then
        mv "${_cpu_after_bak}" "${_cpu_after}"
    fi

    # Build vllm from source against the installed torch.
    # https://docs.vllm.ai/en/latest/getting_started/installation/cpu/
    _vllm_src=$(mktemp -d)
    trap 'rm -rf "${_vllm_src}"' EXIT
    git clone --depth 1 https://github.com/vllm-project/vllm "${_vllm_src}/vllm"
    pushd "${_vllm_src}/vllm"
        uv pip install ${EXTRA_PIP_INSTALL_FLAGS:-} wheel packaging ninja "setuptools>=49.4.0" numpy typing-extensions pillow setuptools-scm
        # Respect pre-installed torch version — skip vllm's own requirements-build.txt torch pin.
        VLLM_TARGET_DEVICE=cpu uv pip install ${EXTRA_PIP_INSTALL_FLAGS:-} --no-deps .
    popd
elif [ "x${BUILD_TYPE}" == "xhipblas" ]; then
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
        ensureVenv
        runProtogen
        AMD_GFX1151="https://repo.amd.com/rocm/whl/gfx1151/"
        AMD_FRAMEWORKS="https://rocm.frameworks.amd.com/whl/gfx1151/"
        # Step 1: AMD ROCm torch (HIP variant, links libtorch_hip.so / libc10_hip.so)
        # NOTE: AMD vllm 0.16.1 was built against torch 2.9.1, NOT 2.10.0.
        # torch 2.10.0 changed c10_hip_check_implementation signature (int→unsigned int),
        # causing ABI mismatch: vllm._C.abi3.so expects _ZN3c103hip28c10_hip_check_implementationEiPKcS2_ib
        # but torch 2.10.0 exports _ZN3c103hip28c10_hip_check_implementationEiPKcS2_jb.
        # Use torch 2.9.1+rocm7.12.0 + matching torchvision 0.24.0.
        pip3 install \
            --target="${EDIR}/venv/lib/python3.12/site-packages/" \
            --upgrade \
            --index-url "${AMD_GFX1151}" \
            --extra-index-url "https://pypi.org/simple/" \
            "torch==2.9.1+rocm7.12.0" \
            "torchvision==0.24.0+rocm7.12.0"
        # Step 2: AMD ROCm vllm (pre-release — requires --pre; deps from PyPI fallback)
        # unsafe-first-match: AMD frameworks index first, PyPI fallback for other packages
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${AMD_FRAMEWORKS}" \
            --extra-index-url https://pypi.org/simple/ \
            --index-strategy unsafe-first-match \
            --pre \
            vllm
        # Step 3: AMD flash-attn (pure-py wheel at AMD frameworks index)
        # Note: use uv with --no-build-isolation since flash-attn tries to build
        # from source when resolved via PyPI; the AMD index has a pre-built pure-py wheel
        uv pip install --python "${EDIR}/venv/bin/python" \
            --index-url "${AMD_FRAMEWORKS}" \
            --index-strategy first-match \
            --no-build-isolation \
            "flash-attn==2.8.3"
        # Step 3b: Patch flash_attn_interface.py to survive missing C-extension.
        # AMD's pre-built flash-attn wheel at rocm.frameworks.amd.com is pure-py
        # (no flash_attn_2_cuda .so bundled), but upstream's interface module
        # imports it unconditionally → ModuleNotFoundError breaks every vllm
        # engine init that imports any flash_attn submodule (observed with
        # Qwen3MoE rotary_embedding which pulls in the Triton-only ops path).
        # The Triton paths don't need the C-extension; the import just has
        # to not explode.
        FLASH_INTERFACE="${EDIR}/venv/lib/python3.12/site-packages/flash_attn/flash_attn_interface.py"
        export FLASH_INTERFACE
        if [ -f "${FLASH_INTERFACE}" ]; then
            "${EDIR}/venv/bin/python" -c "
import os
path = os.environ['FLASH_INTERFACE']
src = open(path).read()
old = '    import flash_attn_2_cuda as flash_attn_gpu'
new = '    try:\n        import flash_attn_2_cuda as flash_attn_gpu\n    except ImportError:\n        flash_attn_gpu = None  # AMD ROCm pure-py wheel ships no C-extension; Triton paths still work'
if old in src and new not in src:
    open(path, 'w').write(src.replace(old, new, 1))
    print('Patched flash_attn_interface.py: optional flash_attn_2_cuda import')
else:
    print('flash_attn_interface.py: already patched or pattern not found, skipping')
" 2>&1 || true
        fi
        # Step 4: grpcio + protobuf for LocalAI gRPC backend protocol
        uv pip install --python "${EDIR}/venv/bin/python" \
            "grpcio>=1.60.0" protobuf 2>/dev/null || true
        # Step 5: Patch vllm platform detection for ROCm container environments
        # (a) __init__.py: fall back to torch.version.hip when amdsmi is unavailable
        #     (amdsmi is NOT installed in the LocalAI backend container)
        # (b) rocm.py: replace logger.warning_once with logger.debug to avoid
        #              circular import at module load (warning_once pulls in
        #              vllm.distributed.parallel_state before current_platform resolves)
        VLLM_PLATFORMS="${EDIR}/venv/lib/python3.12/site-packages/vllm/platforms"
        VLLM_INIT="${VLLM_PLATFORMS}/__init__.py"
        VLLM_ROCM="${VLLM_PLATFORMS}/rocm.py"
        export VLLM_INIT VLLM_ROCM
        # Patch (a): __init__.py — torch.version.hip fallback when amdsmi absent
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
        # Patch (b): rocm.py — warning_once → debug to avoid circular import at module load
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
        # flashinfer autotuner calls torch_c_dlpack_ext which selects "cuda" when
        # torch.cuda.is_available() is True (it is on AMD ROCm), but the cuda variant
        # uses c10::cuda::getCurrentCUDAStream which doesn't exist in AMD HIP.
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
        # Create libtorch_cuda.so / libc10_cuda.so symlinks pointing to HIP equivalents.
        # Some code paths (e.g. subprocess LD_LIBRARY_PATH resolution in EngineCore_DP0)
        # look for CUDA-named libs; AMD torch only ships libtorch_hip.so / libc10_hip.so.
        # Step 6: Force-reinstall AMD ROCm torch as the LAST install step.
        # Earlier Step 2 (vllm) pulls torch 2.10.0+cu128 from PyPI as a
        # transitive dependency, overwriting Step 1's 2.9.1+rocm7.12.0. We
        # wait until after flash-attn (Step 3) and all patches (Steps 4-5) are
        # done so those steps resolve against the already-present CUDA torch
        # metadata. Only now do we swap in the HIP variant with --force-reinstall
        # --no-deps. Without this swap the image ships pure NVIDIA CUDA torch
        # and ROCm runtime is dead.
        pip3 install \
            --target="${EDIR}/venv/lib/python3.12/site-packages/" \
            --upgrade --force-reinstall --no-deps \
            --index-url "${AMD_GFX1151}" \
            --extra-index-url "https://pypi.org/simple/" \
            "torch==2.9.1+rocm7.12.0"
        # Relative symlinks, NOT absolute: at build time EDIR=/vllm, so absolute
        # symlinks become /vllm/venv/.../libtorch_hip.so and are dangling once
        # the backend is extracted to /backends/rocm7-vllm/. Relative links stay
        # valid because the target sits in the same directory.
        #
        # NO `|| true` here: if we can't create the CUDA-named symlinks the
        # backend is broken (vllm subprocesses dlopen libtorch_cuda.so at engine
        # init — observed in EngineCore_DP0 spawn). Fail loud at build time
        # instead of shipping a dead image.
        TORCH_LIB="${EDIR}/venv/lib/python3.12/site-packages/torch/lib"
        if [ ! -f "${TORCH_LIB}/libtorch_hip.so" ] || [ ! -f "${TORCH_LIB}/libc10_hip.so" ]; then
            echo "FATAL: Step 6 force-reinstall didn't produce HIP torch libs at ${TORCH_LIB}" >&2
            ls -la "${TORCH_LIB}" >&2
            exit 1
        fi
        ( cd "${TORCH_LIB}" \
          && ln -sf libtorch_hip.so libtorch_cuda.so \
          && ln -sf libc10_hip.so   libc10_cuda.so )
        echo "Created CUDA-named symlinks: libtorch_cuda.so, libc10_cuda.so -> libtorch_hip.so, libc10_hip.so"

        # torchvision ABI-Mismatch: AMD's repo ships torchvision==0.24.0+rocm7.12.0
        # compiled against torch 2.10.0, but we force-installed torch 2.9.1 above.
        # torchvision._meta_registrations.py crashes at import with
        # "RuntimeError: operator torchvision::nms does not exist" because the
        # registered dispatcher kernels don't match torch 2.9.1's ABI. vllm-text
        # models don't need torchvision at all — transformers imports it
        # unconditionally via image_processing_auto, so simply removing it
        # avoids the crash while letting text inference work. Remove the package
        # metadata AND the shipped .libs so there's no trace left.
        PKGS="${EDIR}/venv/lib/python3.12/site-packages"
        if [ -d "${PKGS}/torchvision" ]; then
            rm -rf "${PKGS}/torchvision" "${PKGS}/torchvision-"*".dist-info" "${PKGS}/torchvision.libs"
            echo "Removed torchvision (ABI-mismatch with force-installed torch 2.9.1)"
        fi
else
    installRequirements
fi
