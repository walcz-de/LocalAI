#!/bin/bash

backend_dir=$(dirname $0)

if [ -d $backend_dir/common ]; then
    source $backend_dir/common/libbackend.sh
else
    source $backend_dir/../common/libbackend.sh
fi

# AMD ROCm: use Triton flash attention backend instead of the (missing) CUDA extension.
# This env var is AMD-specific and is a no-op on NVIDIA CUDA builds.
export FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE

# Resolve EDIR so we can add torch lib to LD_LIBRARY_PATH before exec.
# libbackend.sh only adds ${EDIR}/lib; vllm's spawn subprocess also needs torch .so files.
ensureVenv

# Portable Python from libbackend.sh installs to ${EDIR}/python/ but the
# venv/bin/python symlink has hardcoded sys.prefix=/install (build-time path).
# Force PYTHONHOME so all venv python invocations (including EngineCore
# subprocess spawn) find stdlib at runtime.
export PYTHONHOME="${EDIR}/python"

# Triton JIT needs a C compiler at runtime to build specialized kernels. The
# FROM scratch runtime image has no system gcc/cc. Search for clang in two
# possible locations:
#   1. _rocm_sdk_core/lib/llvm/bin/clang (rocm-sdk-libraries-gfx1151 layout)
#   2. /opt/rocm/lib/llvm/bin/clang (mounted from base via gpu-libs script)
for _clang in \
    "${EDIR}"/venv/lib/python*/site-packages/_rocm_sdk_core/lib/llvm/bin/clang \
    "${EDIR}"/lib/llvm/bin/clang \
    /opt/rocm/lib/llvm/bin/clang; do
    if [ -x "${_clang}" ]; then
        export CC="${_clang}"
        export TRITON_CC="${_clang}"
        echo "Set CC + TRITON_CC to ${_clang} for Triton JIT"
        break
    fi
done
unset _clang

for _torch_lib in "${EDIR}"/venv/lib/python*/site-packages/torch/lib; do
    if [ -d "${_torch_lib}" ]; then
        export LD_LIBRARY_PATH="${_torch_lib}:${LD_LIBRARY_PATH:-}"
        echo "Added ${_torch_lib} to LD_LIBRARY_PATH for vllm torch libs"
        break
    fi
done
unset _torch_lib

startBackend $@