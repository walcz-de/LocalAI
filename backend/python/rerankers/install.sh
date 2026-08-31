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

# ROCm: install torch separately, per GPU arch, BEFORE installRequirements -- the
# same pattern the diffusers backend uses, and for the same reason.
#
# What was wrong before (2026-08-31): requirements-hipblas.txt pinned
# `torch==2.10.0+rocm7.0` from download.pytorch.org/whl/rocm7.0. That community
# wheel does not enumerate Strix Halo -- torch.cuda.device_count() returns 0 on
# gfx1151, so the backend silently falls back to CPU. A requirements file cannot
# express the per-arch selection this needs (it has no access to AMDGPU_TARGETS),
# which is why the torch pin has to move here.
#
# Index: stable.repo.amd.com/rocm/whl-next (ROCm 10; what AMD's own ROCm 10
# container carries as PIP_EXTRA_INDEX_URL). torchvision tracks torch: 2.11->0.26.
if [ "x${BUILD_PROFILE}" == "xhipblas" ]; then
    _gpu_arch="${AMDGPU_TARGETS:-gfx1151}"; _gpu_arch="${_gpu_arch%%;*}"; _gpu_arch="${_gpu_arch%% *}"
    ensureVenv
    # PyPI must stay reachable: torch pulls numpy, and whl-next carries numpy only
    # as cp312/cp313/cp314 wheels. This backend runs on portable CPython 3.10, so a
    # bare --index-url (which REPLACES PyPI) fails with "no wheels with a matching
    # Python implementation tag". The +rocm10.0.0 local versions exist only on
    # whl-next, so PyPI cannot shadow the ROCm packages.
    uv pip install --index-url https://stable.repo.amd.com/rocm/whl-next \
        --extra-index-url https://pypi.org/simple --index-strategy unsafe-best-match \
        "torch[device-${_gpu_arch}]==2.11.0+rocm10.0.0"
fi

installRequirements
