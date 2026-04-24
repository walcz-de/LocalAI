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

# Triton JIT needs a C compiler at runtime to build specialized kernels. The
# FROM scratch runtime image has no system gcc/cc. The AMD ROCm SDK Python
# wheel (_rocm_sdk_core) bundles clang at venv/.../_rocm_sdk_core/lib/llvm/bin/clang.
# Point CC there so Triton can shell out to it when compiling a kernel on-demand.
for _clang in "$(dirname "$0")"/venv/lib/python*/site-packages/_rocm_sdk_core/lib/llvm/bin/clang; do
    if [ -x "${_clang}" ]; then
        export CC="${_clang}"
        export TRITON_CC="${_clang}"
        echo "Set CC + TRITON_CC to ${_clang} for Triton JIT"
        break
    fi
done
unset _clang

# Resolve EDIR so we can add torch lib to LD_LIBRARY_PATH before exec.
# libbackend.sh only adds ${EDIR}/lib; vllm's spawn subprocess also needs torch .so files.
ensureVenv
for _torch_lib in "${EDIR}"/venv/lib/python*/site-packages/torch/lib; do
    if [ -d "${_torch_lib}" ]; then
        export LD_LIBRARY_PATH="${_torch_lib}:${LD_LIBRARY_PATH:-}"
        echo "Added ${_torch_lib} to LD_LIBRARY_PATH for vllm torch libs"
        break
    fi
done
unset _torch_lib

startBackend $@