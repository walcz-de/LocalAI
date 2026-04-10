ARG BASE_IMAGE=ubuntu:24.04
ARG GRPC_BASE_IMAGE=${BASE_IMAGE}
ARG INTEL_BASE_IMAGE=${BASE_IMAGE}
ARG UBUNTU_CODENAME=noble

###################################
# gRPC stage — builds gRPC C++ library for use by llama-cpp backend builder
# Same approach as backend/Dockerfile.llama-cpp so the main image can bake in
# the llama-cpp backend without an external stage reference.
FROM ${GRPC_BASE_IMAGE} AS llama-grpc

ARG GRPC_MAKEFLAGS="-j4 -Otarget"
ARG GRPC_VERSION=v1.65.0
ARG CMAKE_FROM_SOURCE=false
ARG CMAKE_VERSION=3.31.10

ENV MAKEFLAGS=${GRPC_MAKEFLAGS}
WORKDIR /build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential curl libssl-dev \
        git wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN <<EOT bash
    if [ "${CMAKE_FROM_SOURCE}" = "true" ]; then
        curl -L -s https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz -o cmake.tar.gz && tar xvf cmake.tar.gz && cd cmake-${CMAKE_VERSION} && ./configure && make && make install
    else
        apt-get update && apt-get install -y cmake && apt-get clean && rm -rf /var/lib/apt/lists/*
    fi
EOT

RUN git clone --recurse-submodules --jobs 4 -b ${GRPC_VERSION} --depth 1 --shallow-submodules https://github.com/grpc/grpc && \
    mkdir -p /build/grpc/cmake/build && \
    cd /build/grpc/cmake/build && \
    sed -i "216i\  TESTONLY" "../../third_party/abseil-cpp/absl/container/CMakeLists.txt" && \
    cmake -DgRPC_INSTALL=ON -DgRPC_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX:PATH=/opt/grpc ../.. && \
    make && \
    make install && \
    rm -rf /build

###################################

FROM ${BASE_IMAGE} AS requirements

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget espeak-ng libgomp1 \
        ffmpeg libopenblas0 libopenblas-dev libopus0 sox && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# The requirements-drivers target is for BUILD_TYPE specific items.  If you need to install something specific to CUDA, or specific to ROCM, it goes here.
FROM requirements AS requirements-drivers

ARG BUILD_TYPE
ARG CUDA_MAJOR_VERSION=12
ARG CUDA_MINOR_VERSION=0
ARG SKIP_DRIVERS=false
ARG TARGETARCH
ARG TARGETVARIANT
ENV BUILD_TYPE=${BUILD_TYPE}
ARG UBUNTU_VERSION=2404

RUN mkdir -p /run/localai
RUN echo "default" > /run/localai/capability

# Vulkan requirements
RUN <<EOT bash
    if [ "${BUILD_TYPE}" = "vulkan" ] && [ "${SKIP_DRIVERS}" = "false" ]; then
        apt-get update && \
        apt-get install -y  --no-install-recommends \
            software-properties-common pciutils wget gpg-agent && \
        apt-get install -y libglm-dev cmake libxcb-dri3-0 libxcb-present0 libpciaccess0 \
            libpng-dev libxcb-keysyms1-dev libxcb-dri3-dev libx11-dev g++ gcc \
            libwayland-dev libxrandr-dev libxcb-randr0-dev libxcb-ewmh-dev \
            git python-is-python3 bison libx11-xcb-dev liblz4-dev libzstd-dev \
            ocaml-core ninja-build pkg-config libxml2-dev wayland-protocols python3-jsonschema \
            clang-format qtbase5-dev qt6-base-dev libxcb-glx0-dev sudo xz-utils mesa-vulkan-drivers
        if [ "amd64" = "$TARGETARCH" ]; then
            wget "https://sdk.lunarg.com/sdk/download/1.4.335.0/linux/vulkansdk-linux-x86_64-1.4.335.0.tar.xz" && \
            tar -xf vulkansdk-linux-x86_64-1.4.335.0.tar.xz && \
            rm vulkansdk-linux-x86_64-1.4.335.0.tar.xz && \
            mkdir -p /opt/vulkan-sdk && \
            mv 1.4.335.0 /opt/vulkan-sdk/ && \
            cd /opt/vulkan-sdk/1.4.335.0 && \
            ./vulkansdk --no-deps --maxjobs \
                vulkan-loader \
                vulkan-validationlayers \
                vulkan-extensionlayer \
                vulkan-tools \
                shaderc && \
            cp -rfv /opt/vulkan-sdk/1.4.335.0/x86_64/bin/* /usr/bin/ && \
            cp -rfv /opt/vulkan-sdk/1.4.335.0/x86_64/lib/* /usr/lib/x86_64-linux-gnu/ && \
            cp -rfv /opt/vulkan-sdk/1.4.335.0/x86_64/include/* /usr/include/ && \
            cp -rfv /opt/vulkan-sdk/1.4.335.0/x86_64/share/* /usr/share/ && \
            rm -rf /opt/vulkan-sdk
        fi
        if [ "arm64" = "$TARGETARCH" ]; then
            mkdir vulkan && cd vulkan && \
            curl -L -o vulkan-sdk.tar.xz https://github.com/mudler/vulkan-sdk-arm/releases/download/1.4.335.0/vulkansdk-ubuntu-24.04-arm-1.4.335.0.tar.xz && \
            tar -xvf vulkan-sdk.tar.xz && \
            rm vulkan-sdk.tar.xz && \
            cd 1.4.335.0 && \
            cp -rfv aarch64/bin/* /usr/bin/ && \
            cp -rfv aarch64/lib/* /usr/lib/aarch64-linux-gnu/ && \
            cp -rfv aarch64/include/* /usr/include/ && \
            cp -rfv aarch64/share/* /usr/share/ && \
            cd ../.. && \
            rm -rf vulkan
        fi
        ldconfig && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/* && \
        echo "vulkan" > /run/localai/capability
    fi
EOT

# CuBLAS requirements
RUN <<EOT bash
    if ( [ "${BUILD_TYPE}" = "cublas" ] || [ "${BUILD_TYPE}" = "l4t" ] ) && [ "${SKIP_DRIVERS}" = "false" ]; then
        apt-get update && \
        apt-get install -y  --no-install-recommends \
            software-properties-common pciutils
        if [ "amd64" = "$TARGETARCH" ]; then
            curl -O https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION}/x86_64/cuda-keyring_1.1-1_all.deb
        fi
        if [ "arm64" = "$TARGETARCH" ]; then
            if [ "${CUDA_MAJOR_VERSION}" = "13" ]; then
                curl -O https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION}/sbsa/cuda-keyring_1.1-1_all.deb
            else
                curl -O https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION}/arm64/cuda-keyring_1.1-1_all.deb
            fi
        fi
        dpkg -i cuda-keyring_1.1-1_all.deb && \
        rm -f cuda-keyring_1.1-1_all.deb && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            cuda-nvcc-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} \
            libcufft-dev-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} \
            libcurand-dev-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} \
            libcublas-dev-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} \
            libcusparse-dev-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} \
            libcusolver-dev-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION}
        if [ "${CUDA_MAJOR_VERSION}" = "13" ] && [ "arm64" = "$TARGETARCH" ]; then
            apt-get install -y --no-install-recommends \
            libcufile-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} libcudnn9-cuda-${CUDA_MAJOR_VERSION} cuda-cupti-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION} libnvjitlink-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION}
        fi
        apt-get clean && \
        rm -rf /var/lib/apt/lists/* && \
        echo "nvidia-cuda-${CUDA_MAJOR_VERSION}" > /run/localai/capability
    fi
EOT

RUN <<EOT bash
    if [ "${BUILD_TYPE}" = "cublas" ] && [ "${TARGETARCH}" = "arm64" ]; then
        echo "nvidia-l4t-cuda-${CUDA_MAJOR_VERSION}" > /run/localai/capability
    fi
EOT

# https://github.com/NVIDIA/Isaac-GR00T/issues/343
RUN <<EOT bash
    if [ "${BUILD_TYPE}" = "cublas" ] && [ "${TARGETARCH}" = "arm64" ]; then
        wget https://developer.download.nvidia.com/compute/cudss/0.6.0/local_installers/cudss-local-tegra-repo-ubuntu${UBUNTU_VERSION}-0.6.0_0.6.0-1_arm64.deb && \
        dpkg -i cudss-local-tegra-repo-ubuntu${UBUNTU_VERSION}-0.6.0_0.6.0-1_arm64.deb && \
        cp /var/cudss-local-tegra-repo-ubuntu${UBUNTU_VERSION}-0.6.0/cudss-*-keyring.gpg /usr/share/keyrings/ && \
        apt-get update && apt-get -y install cudss cudss-cuda-${CUDA_MAJOR_VERSION} && \
        wget https://developer.download.nvidia.com/compute/nvpl/25.5/local_installers/nvpl-local-repo-ubuntu${UBUNTU_VERSION}-25.5_1.0-1_arm64.deb && \
        dpkg -i nvpl-local-repo-ubuntu${UBUNTU_VERSION}-25.5_1.0-1_arm64.deb && \
        cp /var/nvpl-local-repo-ubuntu${UBUNTU_VERSION}-25.5/nvpl-*-keyring.gpg /usr/share/keyrings/ && \
        apt-get update && apt-get install -y nvpl
    fi
EOT

# If we are building with clblas support, we need the libraries for the builds
RUN if [ "${BUILD_TYPE}" = "clblas" ] && [ "${SKIP_DRIVERS}" = "false" ]; then \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            libclblast-dev && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/* \
    ; fi

RUN if [ "${BUILD_TYPE}" = "hipblas" ] && [ "${SKIP_DRIVERS}" = "false" ]; then \
        mkdir -p /etc/apt/keyrings && \
        apt-get update && \
        apt-get install -y --no-install-recommends wget gpg && \
        wget -qO- https://repo.amd.com/rocm/packages/gpg/rocm.gpg | gpg --dearmor > /etc/apt/keyrings/amdrocm.gpg && \
        echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages/ubuntu2404 stable main' > /etc/apt/sources.list.d/rocm.list && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            amdrocm-llvm \
            amdrocm-core-sdk-gfx1151 && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/* && \
        echo "amd-gfx1151" > /run/localai/capability && \
        # ROCm 7.x installs to /opt/rocm/core-7.XX/ with update-alternatives managing
        # /opt/rocm/core-7 -> /opt/rocm/core-7.XX (e.g. core-7.12).
        # Use core-7 so symlinks survive minor version bumps (7.11 → 7.12 etc.).
        ln -sf /opt/rocm/core-7/lib/llvm /opt/rocm/llvm && \
        ln -sf /opt/rocm/core-7/bin /opt/rocm/bin && \
        ln -sf /opt/rocm/core-7 /opt/rocm/hip && \
        ln -sf /opt/rocm/core-7/lib /opt/rocm/lib && \
        ln -sf /opt/rocm/core-7/include /opt/rocm/include && \
        # ROCm lib packages don't trigger ldconfig - run it manually
        ldconfig \
    ; fi

RUN if [ "${BUILD_TYPE}" = "hipblas" ]; then \
    ln -sf /opt/rocm/llvm/lib/libomp.so /usr/lib/libomp.so \
    ; fi

RUN expr "${BUILD_TYPE}" = intel && echo "intel" > /run/localai/capability || echo "not intel"

# Cuda
ENV PATH=/usr/local/cuda/bin:${PATH}

# HipBLAS requirements
ENV PATH=/opt/rocm/bin:${PATH}

###################################
###################################

# The requirements-core target is common to all images.  It should not be placed in requirements-core unless every single build will use it.
FROM requirements-drivers AS build-requirements

ARG GO_VERSION=1.26.0
ARG CMAKE_VERSION=3.31.10
ARG CMAKE_FROM_SOURCE=false
ARG TARGETARCH
ARG TARGETVARIANT

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        ca-certificates espeak-ng \
        curl libssl-dev \
        git \
        git-lfs \
        libopus-dev pkg-config \
        unzip upx-ucl python3 python-is-python3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install CMake (the version in 22.04 is too old)
RUN <<EOT bash
    if [ "${CMAKE_FROM_SOURCE}" = "true" ]; then
        curl -L -s https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz -o cmake.tar.gz && tar xvf cmake.tar.gz && cd cmake-${CMAKE_VERSION} && ./configure && make && make install
    else
        apt-get update && \
        apt-get install -y \
            cmake && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*
    fi
EOT

# Install Go
RUN curl -L -s https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz | tar -C /usr/local -xz
ENV PATH=$PATH:/root/go/bin:/usr/local/go/bin

# Install grpc compilers
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2 && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@1958fcbe2ca8bd93af633f11e97d44e567e945af

COPY --chmod=644 custom-ca-certs/* /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN test -n "$TARGETARCH" \
    || (echo 'warn: missing $TARGETARCH, either set this `ARG` manually, or run using `docker buildkit`')

# Use the variables in subsequent instructions
RUN echo "Target Architecture: $TARGETARCH"
RUN echo "Target Variant: $TARGETVARIANT"




WORKDIR /build


###################################
###################################

# Temporary workaround for Intel's repository to work correctly
# https://community.intel.com/t5/Intel-oneAPI-Math-Kernel-Library/APT-Repository-not-working-signatures-invalid/m-p/1599436/highlight/true#M36143
# This is a temporary workaround until Intel fixes their repository
FROM ${INTEL_BASE_IMAGE} AS intel
ARG UBUNTU_CODENAME=noble
RUN wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
gpg --yes --dearmor --output /usr/share/keyrings/intel-graphics.gpg
RUN echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu ${UBUNTU_CODENAME}/lts/2350 unified" > /etc/apt/sources.list.d/intel-graphics.list
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        intel-oneapi-runtime-libs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

###################################
###################################

# The builder-base target has the arguments, variables, and copies shared between full builder images and the uncompiled devcontainer

FROM build-requirements AS builder-base

ARG GO_TAGS="auth"
ARG GRPC_BACKENDS
ARG MAKEFLAGS
ARG LD_FLAGS="-s -w"
ARG TARGETARCH
ARG TARGETVARIANT
ENV GRPC_BACKENDS=${GRPC_BACKENDS}
ENV GO_TAGS=${GO_TAGS}
ENV MAKEFLAGS=${MAKEFLAGS}
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_REQUIRE_CUDA="cuda>=${CUDA_MAJOR_VERSION}.0"
ENV NVIDIA_VISIBLE_DEVICES=all
ENV LD_FLAGS=${LD_FLAGS}

RUN echo "GO_TAGS: $GO_TAGS" && echo "TARGETARCH: $TARGETARCH"

WORKDIR /build


# We need protoc installed, and the version in 22.04 is too old.
RUN <<EOT bash
    if [ "amd64" = "$TARGETARCH" ]; then
        curl -L -s https://github.com/protocolbuffers/protobuf/releases/download/v27.1/protoc-27.1-linux-x86_64.zip -o protoc.zip && \
        unzip -j -d /usr/local/bin protoc.zip bin/protoc && \
        rm protoc.zip
    fi
    if [ "arm64" = "$TARGETARCH" ]; then
        curl -L -s https://github.com/protocolbuffers/protobuf/releases/download/v27.1/protoc-27.1-linux-aarch_64.zip -o protoc.zip && \
        unzip -j -d /usr/local/bin protoc.zip bin/protoc && \
        rm protoc.zip
    fi
EOT

###################################
###################################

# Build React UI
FROM node:25-slim AS react-ui-builder
WORKDIR /app
COPY core/http/react-ui/package*.json ./
RUN npm install
COPY core/http/react-ui/ ./
RUN npm run build

###################################
###################################

# Compile backends first in a separate stage
FROM builder-base AS builder-backends
ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /build

COPY ./Makefile .
COPY ./backend ./backend
COPY ./go.mod .
COPY ./go.sum .
COPY ./.git ./.git

# Some of the Go backends use libs from the main src, we could further optimize the caching by building the CPP backends before here
COPY ./pkg/grpc ./pkg/grpc
COPY ./pkg/utils ./pkg/utils

RUN ls -l ./
RUN make protogen-go

# The builder target compiles LocalAI. This target is not the target that will be uploaded to the registry.
# Adjustments to the build process should likely be made here.
FROM builder-backends AS builder

WORKDIR /build

COPY . .

# Copy pre-built React UI
COPY --from=react-ui-builder /app/dist ./core/http/react-ui/dist

## Build the binary
## If we're on arm64 AND using cublas/hipblas, skip some of the llama-compat backends to save space
## Otherwise just run the normal build
RUN make build

###################################
###################################

# Build llama-cpp backend with hipblas/ROCm 7.11 for gfx1151 — baked into the main image
# so no gallery download is needed at runtime.
FROM build-requirements AS llama-cpp-hipblas-builder
ARG BUILD_TYPE
ARG SKIP_DRIVERS=false
# GPU_TARGETS allows callers to restrict which GPU architectures are compiled.
# When set (e.g. GPU_TARGETS=gfx1151) it is forwarded as AMDGPU_TARGETS to the
# llama-cpp make invocations below.  Without an explicit override the cmake
# command is built up from multiple recursive $(MAKE) calls which can result in
# -DAMDGPU_TARGETS being specified more than once; cmake uses the LAST value,
# so if any sub-make appends a stale default the desired targets are silently
# dropped.  Passing AMDGPU_TARGETS on the command line prevents this by
# overriding the ?= assignment in every recursive Makefile call.
ARG GPU_TARGETS

# Install grpc (needed by the grpc-server build target)
COPY --from=llama-grpc /opt/grpc /usr/local

WORKDIR /build

# Copy the backend source (includes llama.cpp submodule and build scripts)
COPY ./backend ./backend
COPY ./scripts ./scripts

# Install rocWMMA headers from source (rocwmma-dev is not in ROCm 7.11 apt repo).
# Install to /opt/rocwmma-headers to avoid /opt/rocm/include symlink/path issues.
# CPATH is extended below so the compiler finds the headers without ROCm path gymnastics.
RUN if [ "${BUILD_TYPE}" = "hipblas" ]; then \
        git clone --depth 1 https://github.com/ROCm/rocWMMA /tmp/rocwmma && \
        mkdir -p /opt/rocwmma-headers/rocwmma && \
        cp -r /tmp/rocwmma/library/include/rocwmma/. /opt/rocwmma-headers/rocwmma/ && \
        rm -rf /tmp/rocwmma ; \
    fi
# Write rocwmma-version.hpp with known content (avoids cmake configure_file dependency)
RUN <<'EOT' bash
if [ "${BUILD_TYPE}" = "hipblas" ]; then
    cat > /opt/rocwmma-headers/rocwmma/rocwmma-version.hpp << 'ROCWMMA_EOF'
#ifndef ROCWMMA_API_VERSION_HPP
#define ROCWMMA_API_VERSION_HPP
#define ROCWMMA_VERSION_MAJOR 2
#define ROCWMMA_VERSION_MINOR 2
#define ROCWMMA_VERSION_PATCH 0
#endif
ROCWMMA_EOF
fi
EOT
ENV CPATH=/opt/rocwmma-headers:${CPATH:-}

RUN <<'EOT' bash
set -euxo pipefail
if [ "${BUILD_TYPE}" = "hipblas" ]; then
  cd /build/backend/cpp/llama-cpp
  # Remove any llama.cpp directory that came from the COPY context.
  # The Makefile's `llama.cpp` target clones at LLAMA_VERSION, which is the
  # correct commit (with common/chat-auto-parser.h).  If the directory already
  # exists from COPY, make considers the dependency satisfied and skips the
  # clone — potentially leaving us with the wrong commit.
  rm -rf llama.cpp
  # Also remove stale llama.cpp checkouts inside the build variant directories.
  # These directories are copied from the host build context and may contain an
  # old llama.cpp commit that lacks common/chat-auto-parser.h.  Removing them
  # forces each variant Makefile to re-clone at the correct LLAMA_VERSION.
  rm -rf ../llama-cpp-fallback-build/llama.cpp
  rm -rf ../llama-cpp-grpc-build/llama.cpp
  # Pass AMDGPU_TARGETS explicitly on the make command line so it propagates
  # through all recursive $(MAKE) calls without being overridden by the ?=
  # default in sub-Makefiles.  Without this, cmake receives -DAMDGPU_TARGETS
  # multiple times and the last (stale) value silently wins.
  MAKE_TARGETS="AMDGPU_TARGETS=${GPU_TARGETS:-gfx1151}"
  make llama-cpp-fallback ${MAKE_TARGETS}
  make llama-cpp-grpc ${MAKE_TARGETS}
  make llama-cpp-rpc-server
  make package
else
  # Create empty package dir for non-hipblas builds so COPY doesn't fail
  mkdir -p /build/backend/cpp/llama-cpp/package
fi
EOT

###################################
###################################

# The devcontainer target is not used on CI. It is a target for developers to use locally -
# rather than copying files it mounts them locally and leaves building to the developer

FROM builder-base AS devcontainer

COPY .devcontainer-scripts /.devcontainer-scripts

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ssh less
# For the devcontainer, leave apt functional in case additional devtools are needed at runtime.

RUN go install github.com/go-delve/delve/cmd/dlv@latest

RUN go install github.com/mikefarah/yq/v4@latest

###################################
###################################

# This is the final target. The result of this target will be the image uploaded to the registry.
# If you cannot find a more suitable place for an addition, this layer is a suitable place for it.
FROM requirements-drivers

ENV HEALTHCHECK_ENDPOINT=http://localhost:8080/readyz

ARG CUDA_MAJOR_VERSION=12
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_REQUIRE_CUDA="cuda>=${CUDA_MAJOR_VERSION}.0"
ENV NVIDIA_VISIBLE_DEVICES=all

# AMD gfx1151 (Strix Halo / RDNA 3.5) runtime requirements
ARG BUILD_TYPE
ENV HSA_OVERRIDE_GFX_VERSION=11.5.1
# Prefer hipBLASLt over rocBLAS for GEMM (avoids rocBLAS Kernels.so lookup).
ENV ROCBLAS_USE_HIPBLASLT=1
# Enable XNACK (memory fault retry) for APU unified memory (Strix Halo).
ENV HSA_XNACK=1
# Disable SDMA engine — known to cause hangs/errors on APU/iGPU configs.
ENV HSA_ENABLE_SDMA=0
# GGML_CUDA_ENABLE_UNIFIED_MEMORY intentionally NOT set – use hipMalloc (96GB VRAM pool)
# Enable rocWMMA-accelerated Flash Attention for RDNA 3.5.
ENV GGML_HIP_ROCWMMA=1
# libamd_comgr.so.3 depends on libLLVM.so.22.0git and libclang-cpp.so.22.0git from the
# ROCm LLVM toolchain.  These libs live in /opt/rocm/llvm/lib which is NOT searched by
# default.  Setting LD_LIBRARY_PATH here ensures backend subprocesses (run.sh prepends
# their own lib/ then inherits this) can find the LLVM shared libraries via dlopen.
ENV LD_LIBRARY_PATH=/opt/rocm/llvm/lib
# hipBLASLt and rocBLAS ship kernel data (TensileLibrary + Kernels.so) in arch-specific
# subdirectories relative to their library.  When backends run in isolation using the
# packaged lib/ directory, the library can't find its own data via dladdr.  Point both
# libraries explicitly to the system data path so gfx1151 kernels are always found.
ENV HIPBLASLT_TENSILE_LIBPATH=/opt/rocm/lib/hipblaslt/library
ENV ROCBLAS_TENSILE_LIBPATH=/opt/rocm/lib/rocblas/library

WORKDIR /

COPY ./entrypoint.sh .

# Use the default upstream gallery URL (github:mudler/LocalAI/backend/index.yaml@master).
# We intentionally do NOT set LOCALAI_BACKEND_GALLERIES here because the file:// URI
# handler in the downloader checks that the target file is inside BackendsPath (/backends)
# via InTrustedRoot — a path like /var/lib/local-ai/backend-index.yaml is outside that
# trusted root and the check fails, returning an empty gallery.
#
# The baked-in rocm-gfx1151-llama-cpp backend is still used for inference via the alias
# mechanism: its metadata.json carries alias=llama-cpp, so ListSystemBackends resolves
# "llama-cpp" to the baked-in backend before any gallery download is attempted.

# Copy the binary
COPY --from=builder /build/local-ai ./
# Copy the opus shim if it was built
RUN --mount=from=builder,src=/build/,dst=/mnt/build \
    if [ -f /mnt/build/libopusshim.so ]; then cp /mnt/build/libopusshim.so ./; fi

# Make sure the models directory exists
RUN mkdir -p /models /backends /data

# Bake in llama-cpp backend into BackendsSystemPath (/var/lib/local-ai/backends) rather than
# /backends — the VOLUME instruction makes /backends overrideable by user mounts, which would
# hide baked-in content. BackendsSystemPath is not a Docker VOLUME, so it's always visible.
RUN --mount=from=llama-cpp-hipblas-builder,src=/build/backend/cpp/llama-cpp/package,dst=/mnt/llama-pkg \
    if [ -n "$(ls -A /mnt/llama-pkg 2>/dev/null)" ]; then \
        mkdir -p /var/lib/local-ai/backends/rocm-gfx1151-llama-cpp && \
        cp -a /mnt/llama-pkg/. /var/lib/local-ai/backends/rocm-gfx1151-llama-cpp/ && \
        printf '{"alias":"llama-cpp","name":"rocm-gfx1151-llama-cpp"}' > /var/lib/local-ai/backends/rocm-gfx1151-llama-cpp/metadata.json && \
        echo "llama-cpp backend baked in at /var/lib/local-ai/backends/rocm-gfx1151-llama-cpp/" ; \
    fi

# Define the health check command
HEALTHCHECK --interval=1m --timeout=10m --retries=10 \
  CMD curl -f ${HEALTHCHECK_ENDPOINT} || exit 1

VOLUME /models /backends /configuration /data
EXPOSE 8080
ENTRYPOINT [ "/entrypoint.sh" ]
