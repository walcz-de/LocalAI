#!/bin/bash
set -e

backend_dir=$(dirname $0)
if [ -d $backend_dir/common ]; then
    source $backend_dir/common/libbackend.sh
else
    source $backend_dir/../common/libbackend.sh
fi

if [ "x${BUILD_PROFILE}" == "xl4t13" ]; then
  PYTHON_VERSION="3.12"
  PYTHON_PATCH="12"
  PY_STANDALONE_TAG="20251120"
fi

if [ "x${BUILD_PROFILE}" == "xl4t12" ]; then
    USE_PIP=true
fi

# --index-strategy is a uv-only flag; skip it when using pip
if [ "x${USE_PIP}" != "xtrue" ]; then
    if [ "x${BUILD_PROFILE}" != "xmetal" ] && [ "x${BUILD_PROFILE}" != "xmps" ]; then
        EXTRA_PIP_INSTALL_FLAGS+=" --index-strategy unsafe-best-match"
    fi
fi

# ROCm: torch per GPU arch, BEFORE installRequirements (same pattern as the
# diffusers and rerankers backends).
#
# There was NO hipblas profile at all until 2026-08-31 -- no requirements-hipblas.txt
# existed, so a BUILD_TYPE=hipblas build installed only requirements.txt (grpcio,
# protobuf, grpcio-tools) and produced a backend whose venv held exactly
# google/grpc/grpc_tools/setuptools: no torch, no whisperx, nothing that can
# transcribe. It started, answered gRPC, and could never do its job.
#
# NO ROCm torch step here, deliberately -- and this is worth stating, because the
# obvious move (mirror what diffusers/rerankers do) does not work:
#
#   whisperX 3.8.7 pins  torch~=2.8.0, torchaudio~=2.8.0, torchvision~=0.23.0
#   AMD's ROCm 10 index starts at torch 2.11 (2.11/2.12/2.13+rocm10.0.0)
#
# ~=2.8.0 means >=2.8.0,<2.9.0, so a ROCm 10 torch cannot satisfy it. Installing
# one first does not help: installRequirements resolves whisperX afterwards and
# replaces it with torch 2.8.0+cu128 from PyPI. Measured, not assumed -- that is
# exactly what the first attempt produced. A ROCm build of the 2.8 line exists only
# for ROCm 7.13, which would reintroduce a second ROCm generation.
#
# So this backend runs its torch on CPU. That is less costly than it sounds:
# whisperX's transcription path is faster-whisper/ctranslate2, which has no ROCm
# backend either and would stay on CPU regardless. torch only covers alignment and
# diarization here. Revisit when whisperX relaxes its torch pin.

installRequirements
