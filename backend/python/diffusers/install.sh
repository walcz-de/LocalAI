#!/bin/bash
set -e

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

if [ "x${BUILD_PROFILE}" == "xl4t12" ]; then
    USE_PIP=true
fi

# Use python 3.12 for l4t
if [ "x${BUILD_PROFILE}" == "xl4t13" ]; then
  PYTHON_VERSION="3.12"
  PYTHON_PATCH="12"
  PY_STANDALONE_TAG="20251120"
fi

# ROCm/gfx1151: the community whl/rocm7.0 torch wheels do not enumerate Strix
# Halo (device_count == 0). AMD ships per-GPU builds selected with the
# torch[device-gfx<arch>] extra. Install torch + torchvision (the same pinned
# versions, from that index) in an isolated step: uv aborts on that index's
# 403-for-missing-package responses, so we must not let it resolve PyPI-only
# packages (diffusers, transformers, ...) there. Everything else then resolves
# from PyPI in installRequirements.
#
# ROCm 10 (2026-08-31): the index moved to stable.repo.amd.com/rocm/whl-next.
# The old repo.amd.com/rocm/whl-multi-arch/ tops out at rocm7.14.0 and carries no
# ROCm 10 build at all, which makes it easy to conclude none exists -- it does,
# just elsewhere. whl-next is the index AMD's own ROCm 10 container carries as
# PIP_EXTRA_INDEX_URL, and it serves torch 2.11/2.12/2.13+rocm10.0.0 plus the
# matching amd-torch-device-gfx* packages for gfx1103 and gfx1151.
#
# 2.11 rather than the newest 2.13: it is the smallest step off the previous
# 2.10 pin that whl-next actually offers (it has no 2.10), so the ROCm generation
# is the only thing that really changes here. torchvision tracks torch:
# 2.11->0.26, 2.12->0.27, 2.13->0.28.
if [ "x${BUILD_PROFILE}" == "xhipblas" ]; then
    # Arch from the build (AMDGPU_TARGETS); default gfx1151 -- the only arch we
    # could validate on real hardware. The torch[device-...] extra takes one arch.
    _gpu_arch="${AMDGPU_TARGETS:-gfx1151}"; _gpu_arch="${_gpu_arch%%;*}"; _gpu_arch="${_gpu_arch%% *}"
    ensureVenv
    uv pip install --index-url https://stable.repo.amd.com/rocm/whl-next \
        "torch[device-${_gpu_arch}]==2.11.0+rocm10.0.0" \
        "torchvision==0.26.0+rocm10.0.0"
fi

installRequirements
