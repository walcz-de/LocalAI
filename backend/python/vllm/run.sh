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
for _torch_lib in "${EDIR}"/venv/lib/python*/site-packages/torch/lib; do
    if [ -d "${_torch_lib}" ]; then
        export LD_LIBRARY_PATH="${_torch_lib}:${LD_LIBRARY_PATH:-}"
        echo "Added ${_torch_lib} to LD_LIBRARY_PATH for vllm torch libs"
        break
    fi
done
unset _torch_lib

startBackend $@