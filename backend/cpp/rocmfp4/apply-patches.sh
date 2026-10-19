#!/bin/bash
# Apply the rocmfp4 patch series to a cloned walcz-de/llama.cpp-ROCmFP4 checkout.
#
# The wrapper Makefile deletes the vendored backend/cpp/llama-cpp/patches/ before building,
# so anything the shared grpc-server needs on top of the fork checkout is carried under
# backend/cpp/rocmfp4/patches/ and applied here. See that directory's README for what
# belongs there — chiefly reverts we also carry for llama-cpp, so both backends behave
# the same on gfx1151.
#
# Drop the corresponding patch from patches/ whenever the fork catches up with upstream —
# the build will fail fast if a patch stops applying, which is the signal to retire it.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <llama.cpp-src-dir> <patches-dir>" >&2
    exit 2
fi

SRC_DIR=$1
PATCHES_DIR=$2

if [[ ! -d "$SRC_DIR" ]]; then
    echo "source dir does not exist: $SRC_DIR" >&2
    exit 2
fi

if [[ ! -d "$PATCHES_DIR" ]]; then
    echo "no patches dir at $PATCHES_DIR, nothing to apply"
    exit 0
fi

shopt -s nullglob
patches=("$PATCHES_DIR"/*.patch)
shopt -u nullglob

if [[ ${#patches[@]} -eq 0 ]]; then
    echo "no .patch files in $PATCHES_DIR, nothing to apply"
    exit 0
fi

cd "$SRC_DIR"

for patch in "${patches[@]}"; do
    echo "==> applying $patch"
    git apply --verbose "$patch"
done

echo "all rocmfp4 patches applied successfully"
