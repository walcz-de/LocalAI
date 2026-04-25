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
        # ROCm / HIP build for gfx1151 (Strix Halo) — 100% ROCm 7.2 stack.
        #
        # As of 2026-04-25 we abandoned the AMD gfx1151 pre-release wheels
        # (rocm7.11/7.12) because:
        #  - AMD vllm wheel ships no _rocm_C native kernels → silu_and_mul missing
        #  - rocm-sdk-libraries-gfx1151 only published for 7.10/7.11/7.12 preview
        #  - 7.12-preview base lacks libhipsolver_fortran etc → vllm cmake fails
        #
        # Switching to the official ROCm 7.2.2 stack:
        #  - torch 2.11.0+rocm7.2 from pytorch.org (compiled for all GFX arches incl. gfx1151)
        #  - vllm v0.20.0 from source (latest, knows qwen3_5_moe / Qwen3.6 architecture)
        #  - flash-attn 2.8.3 from AMD frameworks gfx1151 index (pure-py, arch-agnostic)
        #  - rocm/dev-ubuntu-24.04:7.2.2-complete base provides libs at /opt/rocm
        #
        # Build is gated on VLLM_FROM_SOURCE=true (default for gfx1151 in Dockerfile.python)
        # since no official vllm wheel exists for ROCm 7.2 on PyPI.
        ensureVenv
        runProtogen
        TORCH_ROCM72="https://download.pytorch.org/whl/rocm7.2"
        AMD_FRAMEWORKS="https://rocm.frameworks.amd.com/whl/gfx1151/"
        # Step 1: torch 2.11.0+rocm7.2 from pytorch.org official.
        # This is the upstream PyTorch ROCm 7.2 build, compiled for all GFX arches
        # (gfx906/908/90a/942/950/1030/1100/1101/1200/1201/1150/gfx1151).
        pip3 install \
            --target="${EDIR}/venv/lib/python3.12/site-packages/" \
            --upgrade \
            --index-url "${TORCH_ROCM72}" \
            --extra-index-url "https://pypi.org/simple/" \
            "torch==2.11.0+rocm7.2"
        # Step 2: vllm — either AMD pre-release wheel OR source build.
        # The AMD pre-release wheel (0.16.1.devXX+rocm712) at AMD_FRAMEWORKS
        # ships neither vllm._C (CUDA) nor vllm._rocm_C (ROCm) native kernels.
        # Engine init crashes at silu_and_mul lookup on any text model load.
        # Source-build gate: VLLM_FROM_SOURCE=true compiles vllm against the
        # already-pinned torch 2.9.1+rocm7.12.0 and produces _rocm_C locally.
        if [ "${VLLM_FROM_SOURCE:-}" = "true" ]; then
            echo "=== vllm from source for gfx1151 ==="
            # Build-only deps. --no-build-isolation below means uv can't resolve
            # build-deps in an isolated env, so pre-install everything the
            # vllm + fastsafetensors + xformers source trees need at build time.
            uv pip install --python "${EDIR}/venv/bin/python" \
                ninja cmake packaging setuptools wheel build \
                pybind11 numpy \
                "setuptools-scm>=8" vcs_versioning \
                cython "typing_extensions>=4.8" \
                "jinja2>=3.1.2" regex
            # Clone target version — pin explicit so the build is reproducible
            VLLM_SRC_DIR="${EDIR}/vllm-src"
            VLLM_VERSION="${VLLM_VERSION:-v0.20.0}"
            rm -rf "${VLLM_SRC_DIR}"
            git clone --depth 1 --branch "${VLLM_VERSION}" \
                https://github.com/vllm-project/vllm "${VLLM_SRC_DIR}"
            pushd "${VLLM_SRC_DIR}"
                # Source-build needs: hipcc (present in rocm base), cmake, ninja,
                # gcc (installed in Dockerfile.python for BACKEND=vllm).
                # Use use_existing_torch.py to strip vllm's torch pin from
                # requirements so our 2.9.1+rocm7.12.0 isn't downgraded.
                "${EDIR}/venv/bin/python" use_existing_torch.py
                export VLLM_TARGET_DEVICE=rocm
                export PYTORCH_ROCM_ARCH=gfx1151
                export MAX_JOBS="${MAX_JOBS:-4}"
                export NVCC_THREADS="${NVCC_THREADS:-2}"
                # Install without build-isolation so the build sees our torch.
                # Use uv pip (portable Python backend has no pip in venv/bin).
                # use_existing_torch.py strips torch pin from rocm.txt — but rocm.txt
                # might still try to overwrite torch via transitive deps. Use --no-deps
                # on both calls to keep our 2.11.0+rocm7.2 from pytorch.org untouched.
                uv pip install --python "${EDIR}/venv/bin/python" \
                    --no-build-isolation --no-deps -r requirements/rocm.txt || true
                uv pip install --python "${EDIR}/venv/bin/python" \
                    --no-build-isolation -v .
            popd
            rm -rf "${VLLM_SRC_DIR}"
        else
            # Default: AMD pre-release wheel (broken on text models due to missing _rocm_C).
            # unsafe-first-match: AMD frameworks index first, PyPI fallback for other packages
            uv pip install --python "${EDIR}/venv/bin/python" \
                --index-url "${AMD_FRAMEWORKS}" \
                --extra-index-url https://pypi.org/simple/ \
                --index-strategy unsafe-first-match \
                --pre \
                vllm
        fi
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
        # Step 6: Force-reinstall ROCm 7.2 torch as the LAST install step.
        # Earlier Step 2 (vllm source build dependencies) may pull torch from
        # PyPI as a transitive dep, overwriting Step 1's 2.11.0+rocm7.2. We
        # wait until after flash-attn (Step 3) and all patches (Steps 4-5) are
        # done so those steps resolve against the already-present torch
        # metadata. Only now do we swap back to the ROCm 7.2 variant with
        # --force-reinstall --no-deps.
        pip3 install \
            --target="${EDIR}/venv/lib/python3.12/site-packages/" \
            --upgrade --force-reinstall --no-deps \
            --index-url "${TORCH_ROCM72}" \
            --extra-index-url "https://pypi.org/simple/" \
            "torch==2.11.0+rocm7.2"
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
