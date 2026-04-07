#!/bin/bash
# =============================================================================
# LocalAI ROCm 7.x Rebuild Script
# =============================================================================
# Builds (and optionally pushes) the main LocalAI image plus backend images.
# No git sync — use sync-upstream.sh for merge + tag + build + push.
#
# Naming convention:
#   Git tag / binary version:  v{upstream}-rocm{major}.{minor}   e.g. v4.1.3-rocm7.12
#   Image tags (immutable):    {reg}/localai:v4.1.3-rocm7.12
#   Image tags (mutable):      {reg}/localai:rocm7
#   Always pushed to both registries.
#
# Usage:
#   bash scripts/build-rocm.sh               # build all + push
#   bash scripts/build-rocm.sh --no-push     # build all, no registry push
#   bash scripts/build-rocm.sh --no-backends # main image only
#   ROCM_VERSION=7.13 bash scripts/build-rocm.sh
#   ROCM_ARCH=gfx1150,gfx1151 bash scripts/build-rocm.sh  # faster local build
# =============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-192.168.178.127:5000}"
REGISTRY2="${REGISTRY2:-pointblank.ddns.net:5556}"
ROCM_VERSION="${ROCM_VERSION:-7.12}"
ROCM_ARCH="${ROCM_ARCH:-gfx803,gfx900,gfx906,gfx1012,gfx1030,gfx1031,gfx1032,gfx1100,gfx1101,gfx1102,gfx1103,gfx1150,gfx1151,gfx1152,gfx1200,gfx1201}"
NO_PUSH=false
NO_BACKENDS=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

for arg in "$@"; do
    case $arg in
        --no-push)     NO_PUSH=true ;;
        --no-backends) NO_BACKENDS=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Backend list — keep in sync with sync-upstream.sh
# ---------------------------------------------------------------------------
BACKENDS=(
    "rerankers|python"
    "llama-cpp|llama-cpp"
    "vllm|python"
    "vllm-omni|python"
    "transformers|python"
    "diffusers|python"
    "ace-step|python"
    "kokoro|python"
    "vibevoice|python"
    "qwen-asr|python"
    "nemo|python"
    "qwen-tts|python"
    "fish-speech|python"
    "voxcpm|python"
    "pocket-tts|python"
    "faster-whisper|python"
    "whisperx|python"
    "coqui|python"
)

ROCM_MAJOR="${ROCM_VERSION%%.*}"
OUR_SUFFIX="rocm${ROCM_VERSION}"

# Derive version tag from git: expects a tag like v4.1.3-rocm7.12 at HEAD.
# If HEAD is exactly at a fork tag use it; otherwise fall back to
# v{nearest-upstream-tag}-rocm{version}-{sha} so the binary is always traceable.
VERSION_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || \
    echo "$(git describe --tags --abbrev=0 upstream/master 2>/dev/null || echo 'dev')-${OUR_SUFFIX}-$(git rev-parse --short HEAD)")
BUILD_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "local")
FORK_LD_FLAGS="-s -w -X github.com/mudler/LocalAI/internal.Version=${VERSION_TAG} -X github.com/mudler/LocalAI/internal.Commit=${BUILD_SHA}"
LOCAL_IMAGE="localai:${OUR_SUFFIX}"

echo -e "${BOLD}LocalAI ROCm Rebuild${NC}"
echo -e "  ROCm:     ${YELLOW}$ROCM_VERSION / $ROCM_ARCH${NC}"
echo -e "  Version:  ${YELLOW}$VERSION_TAG${NC}"
echo -e "  Push:     $( [ "$NO_PUSH" = "true" ] && echo "${YELLOW}disabled${NC}" || echo "${GREEN}→ $REGISTRY + $REGISTRY2${NC}" )"
echo -e "  Backends: $( [ "$NO_BACKENDS" = "true" ] && echo "${YELLOW}skipped${NC}" || echo "${GREEN}${#BACKENDS[@]} images${NC}" )"

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== Build main image ===${NC}"

docker build \
    --build-arg BUILD_TYPE=hipblas \
    --build-arg ROCM_VERSION=7 \
    --build-arg ROCM_ARCH="${ROCM_ARCH}" \
    --build-arg GPU_TARGETS="${ROCM_ARCH}" \
    --build-arg LD_FLAGS="${FORK_LD_FLAGS}" \
    -t "$LOCAL_IMAGE" \
    . 2>&1 | tee /tmp/localai-build-main.log

echo -e "  ${GREEN}✓ Main image built: $LOCAL_IMAGE${NC}"

# ---------------------------------------------------------------------------
if [ "$NO_BACKENDS" = "false" ]; then
    echo -e "\n${BOLD}=== Build backend images (${#BACKENDS[@]} total) ===${NC}"

    FAILED_BACKENDS=()
    for entry in "${BACKENDS[@]}"; do
        backend="${entry%%|*}"
        dftype="${entry##*|}"

        case "$dftype" in
            llama-cpp) dockerfile="backend/Dockerfile.llama-cpp"; backend_arg="" ;;
            *)         dockerfile="backend/Dockerfile.python";    backend_arg="--build-arg BACKEND=${backend}" ;;
        esac

        local_tag="localai-backends:${OUR_SUFFIX}-${backend}"
        echo -e "\n  [${backend}] Building..."

        # shellcheck disable=SC2086
        if docker build \
                --build-arg BUILD_TYPE=hipblas \
                --build-arg ROCM_VERSION=7 \
                --build-arg ROCM_ARCH="${ROCM_ARCH}" \
                $backend_arg \
                -f "$dockerfile" \
                -t "$local_tag" \
                . 2>&1 | tee "/tmp/localai-build-${backend}.log"; then
            echo -e "  ${GREEN}✓ ${backend} OK${NC}"
        else
            echo -e "  ${RED}✗ ${backend} FAILED (log: /tmp/localai-build-${backend}.log)${NC}"
            FAILED_BACKENDS+=("$backend")
        fi
    done

    if [ "${#FAILED_BACKENDS[@]}" -gt 0 ]; then
        echo -e "\n${RED}${BOLD}Failed backends:${NC} ${FAILED_BACKENDS[*]}"
    else
        echo -e "\n  ${GREEN}✓ All backends built${NC}"
    fi
fi

# ---------------------------------------------------------------------------
if [ "$NO_PUSH" = "true" ]; then
    echo -e "\n${YELLOW}--no-push set — done.${NC}"
    echo -e "  To push later: ${YELLOW}bash scripts/build-rocm.sh --no-backends${NC} won't rebuild, just re-push existing local tags."
    exit 0
fi

# ---------------------------------------------------------------------------
push_image() {
    local local_tag="$1" remote_tag="$2"
    docker tag "$local_tag" "$remote_tag"
    docker push "$remote_tag" && echo -e "  ${GREEN}✓ $remote_tag${NC}"
}

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== Push main image ===${NC}"
for REG in "$REGISTRY" "$REGISTRY2"; do
    push_image "$LOCAL_IMAGE" "${REG}/localai:${VERSION_TAG}"       # immutable
    push_image "$LOCAL_IMAGE" "${REG}/localai:rocm${ROCM_MAJOR}"    # mutable channel
done

# ---------------------------------------------------------------------------
if [ "$NO_BACKENDS" = "false" ]; then
    echo -e "\n${BOLD}=== Push backend images ===${NC}"
    for entry in "${BACKENDS[@]}"; do
        backend="${entry%%|*}"
        local_tag="localai-backends:${OUR_SUFFIX}-${backend}"

        if ! docker image inspect "$local_tag" &>/dev/null; then
            echo -e "  ${YELLOW}⚠ Skipping $backend (not built)${NC}"
            continue
        fi

        for REG in "$REGISTRY" "$REGISTRY2"; do
            push_image "$local_tag" "${REG}/localai-backends:${VERSION_TAG}-${backend}"
            push_image "$local_tag" "${REG}/localai-backends:rocm${ROCM_MAJOR}-${backend}"
        done
    done
fi

# ---------------------------------------------------------------------------
echo -e "\n${GREEN}${BOLD}=== Done ===${NC}"
echo -e "  Version: ${GREEN}$VERSION_TAG${NC}"
echo -e "  ${REGISTRY}/localai:${VERSION_TAG}"
echo -e "  ${REGISTRY2}/localai:${VERSION_TAG}"
echo ""
echo -e "  ${BOLD}Update docker-compose.yaml:${NC}"
echo -e "  ${YELLOW}image: ${REGISTRY}/localai:${VERSION_TAG}${NC}"
echo ""
echo -e "  ${BOLD}Deploy:${NC}"
echo -e "  ${YELLOW}docker compose pull localai && docker compose up -d localai --force-recreate${NC}"
