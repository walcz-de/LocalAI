#!/bin/bash
# =============================================================================
# LocalAI Upstream Sync — ROCm 7.x Fork
# =============================================================================
# Usage:
#   bash sync-upstream.sh               # fetch + merge + build all + push
#   bash sync-upstream.sh --dry-run     # fetch + merge only (no build)
#   bash sync-upstream.sh --no-push     # build but no registry push
#   bash sync-upstream.sh --no-backends # main image only, skip backend images
#   ROCM_VERSION=7.13 bash sync-upstream.sh
#
# Naming convention:
#   Git tag:   v{upstream}-rocm{major}.{minor}   e.g. v4.1.3-rocm7.12
#   Image tags (immutable): {reg}/localai:v4.1.3-rocm7.12
#   Image tags (mutable):   {reg}/localai:rocm7          ← stable channel
#   Backends:  {reg}/localai-backends:v4.1.3-rocm7.12-llama-cpp
#              {reg}/localai-backends:rocm7-llama-cpp
#
#   Always pushed to BOTH registries.
#   docker-compose.yaml should pin the immutable version tag.
#
# On conflict: script stops, resolve manually, git commit, then re-run.
# =============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-192.168.178.127:5000}"
REGISTRY2="${REGISTRY2:-pointblank.ddns.net:5556}"
ROCM_VERSION="${ROCM_VERSION:-7.12}"
ROCM_ARCH="${ROCM_ARCH:-gfx803,gfx900,gfx906,gfx1012,gfx1030,gfx1031,gfx1032,gfx1100,gfx1101,gfx1102,gfx1103,gfx1150,gfx1151,gfx1152,gfx1200,gfx1201}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
DRY_RUN=false
NO_PUSH=false
NO_BACKENDS=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

for arg in "$@"; do
    case $arg in
        --dry-run)     DRY_RUN=true ;;
        --no-push)     NO_PUSH=true ;;
        --no-backends) NO_BACKENDS=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Backend list
# Format: "BACKEND_NAME|DOCKERFILE_TYPE"
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

ROCM_MAJOR="${ROCM_VERSION%%.*}"   # "7" from "7.12"
OUR_SUFFIX="rocm${ROCM_VERSION}"

# ---------------------------------------------------------------------------
echo -e "${BOLD}=== 1. Upstream fetch ===${NC}"
git fetch "$UPSTREAM_REMOTE"

UPSTREAM_VERSION=$(git describe --tags --abbrev=0 "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo "dev")
echo -e "  Upstream: ${YELLOW}$UPSTREAM_REMOTE/$UPSTREAM_BRANCH${NC} @ ${GREEN}$UPSTREAM_VERSION${NC}"
echo -e "  ROCm:     ${YELLOW}$ROCM_VERSION${NC} / arch ${YELLOW}$ROCM_ARCH${NC}"

BEHIND=$(git rev-list HEAD.."$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --count)
if [ "$BEHIND" = "0" ]; then
    echo -e "  ${GREEN}✓ Already up to date — no merge needed${NC}"
    if [ "$DRY_RUN" = "true" ]; then exit 0; fi
else
    echo -e "  ${YELLOW}⚠ $BEHIND new upstream commits${NC}"

    echo -e "\n${BOLD}=== 2. Merge upstream/$UPSTREAM_BRANCH ===${NC}"
    if ! git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-edit \
            -m "chore: merge upstream $UPSTREAM_VERSION into rocm7 fork"; then
        echo -e "\n${RED}✗ Merge conflicts! Manual resolution required:${NC}"
        echo ""
        git diff --name-only --diff-filter=U
        echo ""
        echo -e "  Steps:"
        echo -e "  1. Fix conflicts in the files listed above"
        echo -e "  2. ${YELLOW}git add <file>${NC} for each resolved file"
        echo -e "  3. ${YELLOW}git commit${NC} to complete the merge"
        echo -e "  4. Re-run this script"
        echo ""
        echo -e "  Or abort: ${YELLOW}git merge --abort${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ Merge successful${NC}"

    # Update the upstream version after merge
    UPSTREAM_VERSION=$(git describe --tags --abbrev=0 "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo "dev")
fi

if [ "$DRY_RUN" = "true" ]; then
    echo -e "\n${YELLOW}Dry-run — no build.${NC}"
    echo -e "  Next: set git tag and run without --dry-run"
    echo -e "  ${YELLOW}git tag ${UPSTREAM_VERSION}-${OUR_SUFFIX}${NC}"
    exit 0
fi

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== 3. Version tag ===${NC}"

# Fork version tag: v{upstream}-rocm{major}.{minor}
VERSION_TAG="${UPSTREAM_VERSION}-${OUR_SUFFIX}"
BUILD_SHA=$(git rev-parse --short HEAD)

# Create/update the fork version tag so git describe and the binary show a
# clean version string (e.g. v4.1.3-rocm7.12) without a commit-count suffix.
if git tag -l | grep -q "^${VERSION_TAG}$"; then
    # Only move tag if HEAD is not already tagged
    CURRENT_HEAD=$(git rev-parse HEAD)
    TAGGED_COMMIT=$(git rev-list -n1 "$VERSION_TAG" 2>/dev/null || echo "")
    if [ "$CURRENT_HEAD" != "$TAGGED_COMMIT" ]; then
        git tag -f "$VERSION_TAG"
        echo -e "  ${YELLOW}⚠ Tag $VERSION_TAG moved to HEAD${NC}"
    else
        echo -e "  ${GREEN}✓ Tag $VERSION_TAG already at HEAD${NC}"
    fi
else
    git tag "$VERSION_TAG"
    echo -e "  ${GREEN}✓ Tag $VERSION_TAG created${NC}"
fi

# Verify git describe now returns the clean tag
BINARY_VERSION=$(git describe --tags HEAD 2>/dev/null || echo "$VERSION_TAG")
echo -e "  Binary version will be: ${GREEN}$BINARY_VERSION${NC}"

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== 4. Pre-build checks ===${NC}"
FAIL=0

if grep -q "^ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY" Dockerfile 2>/dev/null; then
    echo -e "  ${RED}✗ GGML_CUDA_ENABLE_UNIFIED_MEMORY in Dockerfile! Remove it.${NC}"
    FAIL=1
else
    echo -e "  ${GREEN}✓ GGML_CUDA_ENABLE_UNIFIED_MEMORY not in Dockerfile${NC}"
fi

if grep -qE "core-7\.[0-9]" backend/Dockerfile.llama-cpp backend/Dockerfile.python 2>/dev/null; then
    echo -e "  ${RED}✗ Hardcoded core-7.XX in backend Dockerfiles — use core-7 (update-alternatives).${NC}"
    grep -n "core-7\.[0-9]" backend/Dockerfile.llama-cpp backend/Dockerfile.python 2>/dev/null || true
    FAIL=1
else
    echo -e "  ${GREEN}✓ No hardcoded core-7.XX in backend Dockerfiles${NC}"
fi

[ "$FAIL" = "1" ] && { echo -e "\n${RED}Checks failed. Build aborted.${NC}"; exit 1; }

# ---------------------------------------------------------------------------
LOCAL_IMAGE="localai:${OUR_SUFFIX}"
FORK_LD_FLAGS="-s -w -X github.com/mudler/LocalAI/internal.Version=${VERSION_TAG} -X github.com/mudler/LocalAI/internal.Commit=${BUILD_SHA}"

echo -e "\n${BOLD}=== 5. Build main image ===${NC}"
echo -e "  Local:       ${YELLOW}$LOCAL_IMAGE${NC}"
echo -e "  Push tags:   ${YELLOW}$VERSION_TAG${NC}  +  ${YELLOW}rocm${ROCM_MAJOR}${NC}  (both registries)"

docker build \
    --no-cache \
    --build-arg BUILD_TYPE=hipblas \
    --build-arg ROCM_VERSION=7 \
    --build-arg ROCM_ARCH="${ROCM_ARCH}" \
    --build-arg GPU_TARGETS="${ROCM_ARCH}" \
    --build-arg LD_FLAGS="${FORK_LD_FLAGS}" \
    -t "$LOCAL_IMAGE" \
    . 2>&1 | tee /tmp/localai-build-main.log

echo -e "  ${GREEN}✓ Main image built${NC}"

# ---------------------------------------------------------------------------
if [ "$NO_BACKENDS" = "false" ]; then
    echo -e "\n${BOLD}=== 6. Build backend images (${#BACKENDS[@]} total) ===${NC}"

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
                --no-cache \
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
        echo -e "${YELLOW}Continuing push for successfully built images.${NC}"
    else
        echo -e "\n  ${GREEN}✓ All backends built${NC}"
    fi
fi

# ---------------------------------------------------------------------------
if [ "$NO_PUSH" = "true" ]; then
    echo -e "\n${YELLOW}--no-push set — skipping registry push.${NC}"
    echo -e "  Local main image: ${GREEN}$LOCAL_IMAGE${NC}"
    exit 0
fi

# ---------------------------------------------------------------------------
push_image() {
    local local_tag="$1" remote_tag="$2"
    docker tag "$local_tag" "$remote_tag"
    docker push "$remote_tag" && echo -e "  ${GREEN}✓ $remote_tag${NC}"
}

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== 7. Push main image ===${NC}"

for REG in "$REGISTRY" "$REGISTRY2"; do
    push_image "$LOCAL_IMAGE" "${REG}/localai:${VERSION_TAG}"   # immutable: v4.1.3-rocm7.12
    push_image "$LOCAL_IMAGE" "${REG}/localai:rocm${ROCM_MAJOR}"  # mutable channel: rocm7
done

# ---------------------------------------------------------------------------
if [ "$NO_BACKENDS" = "false" ]; then
    echo -e "\n${BOLD}=== 8. Push backend images ===${NC}"

    for entry in "${BACKENDS[@]}"; do
        backend="${entry%%|*}"
        local_tag="localai-backends:${OUR_SUFFIX}-${backend}"

        if ! docker image inspect "$local_tag" &>/dev/null; then
            echo -e "  ${YELLOW}⚠ Skipping $backend (not built)${NC}"
            continue
        fi

        for REG in "$REGISTRY" "$REGISTRY2"; do
            push_image "$local_tag" "${REG}/localai-backends:${VERSION_TAG}-${backend}"   # immutable
            push_image "$local_tag" "${REG}/localai-backends:rocm${ROCM_MAJOR}-${backend}"  # mutable
        done
    done
fi

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== 9. Git tag push ===${NC}"
git push origin "$VERSION_TAG" --force 2>/dev/null \
    && echo -e "  ${GREEN}✓ Tag $VERSION_TAG pushed to origin${NC}" \
    || echo -e "  ${YELLOW}⚠ Tag push to origin failed (set locally)${NC}"

# ---------------------------------------------------------------------------
echo -e "\n${GREEN}${BOLD}=== Done ===${NC}"
echo -e "  Upstream:   ${GREEN}$UPSTREAM_VERSION${NC}"
echo -e "  Fork tag:   ${GREEN}$VERSION_TAG${NC}"
echo -e "  ROCm:       ${GREEN}$ROCM_VERSION / $ROCM_ARCH${NC}"
echo -e "  Images:     ${GREEN}${REGISTRY}/localai:${VERSION_TAG}${NC}"
echo -e "              ${GREEN}${REGISTRY2}/localai:${VERSION_TAG}${NC}"
if [ "$NO_BACKENDS" = "false" ]; then
    echo -e "  Backends:   ${GREEN}${#BACKENDS[@]} images × 2 registries${NC}"
fi
echo ""
echo -e "  ${BOLD}Update docker-compose.yaml:${NC}"
echo -e "  ${YELLOW}image: ${REGISTRY}/localai:${VERSION_TAG}${NC}"
echo ""
echo -e "  ${BOLD}Deploy:${NC}"
echo -e "  ${YELLOW}docker compose pull localai && docker compose up -d localai --force-recreate${NC}"
echo ""
echo -e "  ${BOLD}Next upstream sync:${NC}"
echo -e "  ${YELLOW}bash sync-upstream.sh${NC}"
echo -e "  ${YELLOW}ROCM_VERSION=7.13 bash sync-upstream.sh${NC}  (when new ROCm ships)"
