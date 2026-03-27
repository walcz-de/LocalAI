#!/bin/bash
# =============================================================================
# LocalAI Upstream Sync — gfx1151 / ROCm 7.x Fork
# =============================================================================
# Usage:
#   bash sync-upstream.sh              # fetch + merge + build + push
#   bash sync-upstream.sh --dry-run    # nur fetch + merge (kein Build)
#   bash sync-upstream.sh --no-push    # build aber kein Push
#   ROCM_VERSION=7.12 bash sync-upstream.sh
#
# Ergebnis-Image-Tags:
#   <REGISTRY>/localai:<UPSTREAM_VERSION>-gfx1151-rocm<ROCM_VERSION>   (versioniert)
#   <REGISTRY>/localai:latest-gfx1151                                   (rolling)
#
# Strategie: git merge — alle gfx1151-Änderungen als separate Commits auf
# dem Branch feat/rocm7-gfx1151-v4-clean, upstream wird per merge hinzugefügt.
# Bei Konflikten: Script stoppt, manuell lösen, dann erneut ausführen.
# =============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-192.168.178.127:5000}"
ROCM_VERSION="${ROCM_VERSION:-7.12}"   # aktuellste ROCm-Version; per Env überschreibbar
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
DRY_RUN=false
NO_PUSH=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --no-push) NO_PUSH=true ;;
    esac
done

OUR_SUFFIX="gfx1151-rocm${ROCM_VERSION}"

# ---------------------------------------------------------------------------
echo -e "${BOLD}=== 1. Upstream fetch ===${NC}"
git fetch "$UPSTREAM_REMOTE"

UPSTREAM_VERSION=$(git describe --tags --abbrev=0 "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo "dev")
echo -e "  Upstream: ${YELLOW}$UPSTREAM_REMOTE/$UPSTREAM_BRANCH${NC} @ ${GREEN}$UPSTREAM_VERSION${NC}"
echo -e "  ROCm:     ${YELLOW}$ROCM_VERSION${NC}"

BEHIND=$(git rev-list HEAD.."$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --count)
if [ "$BEHIND" = "0" ]; then
    echo -e "  ${GREEN}✓ Bereits auf aktuellem Stand — kein Merge nötig${NC}"
    if [ "$DRY_RUN" = "true" ]; then exit 0; fi
else
    echo -e "  ${YELLOW}⚠ $BEHIND neue Upstream-Commits${NC}"

    # ---------------------------------------------------------------------------
    echo -e "\n${BOLD}=== 2. Merge upstream/$UPSTREAM_BRANCH ===${NC}"
    echo -e "  Starte merge... Konflikte müssen manuell gelöst werden falls vorhanden."

    if ! git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-edit -m "chore: merge upstream $UPSTREAM_VERSION into gfx1151 fork"; then
        echo -e "\n${RED}✗ Merge-Konflikte! Auflösung erforderlich:${NC}"
        echo ""
        git diff --name-only --diff-filter=U
        echo ""
        echo -e "  Schritte zum Lösen:"
        echo -e "  1. Konflikte in obigen Dateien manuell lösen"
        echo -e "  2. ${YELLOW}git add <datei>${NC} für jede gelöste Datei"
        echo -e "  3. ${YELLOW}git commit${NC} um den Merge abzuschließen"
        echo -e "  4. Dieses Skript erneut ausführen"
        echo ""
        echo -e "  Oder Merge abbrechen: ${YELLOW}git merge --abort${NC}"
        exit 1
    fi

    echo -e "  ${GREEN}✓ Merge erfolgreich${NC}"
fi

if [ "$DRY_RUN" = "true" ]; then
    echo -e "\n${YELLOW}Dry-run — kein Build.${NC}"
    exit 0
fi

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== 3. Pre-build Checks ===${NC}"
FAIL=0

if grep -q "^ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY" Dockerfile 2>/dev/null; then
    echo -e "  ${RED}✗ GGML_CUDA_ENABLE_UNIFIED_MEMORY in Dockerfile! Entfernen.${NC}"
    FAIL=1
else
    echo -e "  ${GREEN}✓ GGML_CUDA_ENABLE_UNIFIED_MEMORY nicht in Dockerfile${NC}"
fi

# Check backend Dockerfiles fuer hardcoded core-7.XX (sollte core-7 sein)
if grep -qE "core-7\.[0-9]" backend/Dockerfile.llama-cpp backend/Dockerfile.python 2>/dev/null; then
    echo -e "  ${RED}✗ Hardcoded core-7.XX in backend Dockerfiles! Bitte auf core-7 aktualisieren.${NC}"
    grep -n "core-7\.[0-9]" backend/Dockerfile.llama-cpp backend/Dockerfile.python 2>/dev/null || true
    FAIL=1
else
    echo -e "  ${GREEN}✓ Keine hardcoded core-7.XX in backend Dockerfiles${NC}"
fi

[ "$FAIL" = "1" ] && { echo -e "\n${RED}Checks fehlgeschlagen. Build abgebrochen.${NC}"; exit 1; }

# ---------------------------------------------------------------------------
IMAGE_TAG="${UPSTREAM_VERSION}-${OUR_SUFFIX}"
LOCAL_IMAGE="localai:${OUR_SUFFIX}"
REGISTRY_IMAGE="${REGISTRY}/localai:${IMAGE_TAG}"
REGISTRY_LATEST="${REGISTRY}/localai:latest-gfx1151"

echo -e "\n${BOLD}=== 4. Build ===${NC}"
echo -e "  Image: ${YELLOW}$LOCAL_IMAGE${NC} → ${GREEN}$REGISTRY_IMAGE${NC}"

docker build \
    --build-arg BUILD_TYPE=hipblas \
    --build-arg GPU_TARGETS=gfx1151 \
    -t "$LOCAL_IMAGE" \
    . 2>&1 | tee /tmp/localai-build.log

echo -e "  ${GREEN}✓ Build fertig${NC}"

# ---------------------------------------------------------------------------
if [ "$NO_PUSH" = "true" ]; then
    echo -e "\n${YELLOW}--no-push gesetzt — kein Push.${NC}"
    echo -e "  Lokales Image: ${GREEN}$LOCAL_IMAGE${NC}"
    exit 0
fi

echo -e "\n${BOLD}=== 5. Push ===${NC}"

docker tag "$LOCAL_IMAGE" "$REGISTRY_IMAGE"
docker tag "$LOCAL_IMAGE" "$REGISTRY_LATEST"

docker push "$REGISTRY_IMAGE"
echo -e "  ${GREEN}✓ Pushed: $REGISTRY_IMAGE${NC}"

docker push "$REGISTRY_LATEST"
echo -e "  ${GREEN}✓ Pushed: $REGISTRY_LATEST${NC}"

# ---------------------------------------------------------------------------
echo -e "\n${BOLD}=== 6. Git-Tag setzen ===${NC}"
GIT_TAG="${IMAGE_TAG}"
if git tag -l | grep -q "^${GIT_TAG}$"; then
    echo -e "  ${YELLOW}Tag $GIT_TAG existiert bereits — übersprungen${NC}"
else
    git tag "$GIT_TAG"
    git push origin "$GIT_TAG" 2>/dev/null || echo -e "  ${YELLOW}  (Push des Tags fehlgeschlagen — lokal gesetzt)${NC}"
    echo -e "  ${GREEN}✓ Tag gesetzt: $GIT_TAG${NC}"
fi

# ---------------------------------------------------------------------------
echo -e "\n${GREEN}${BOLD}=== Fertig ===${NC}"
echo -e "  Upstream:  ${GREEN}$UPSTREAM_VERSION${NC}"
echo -e "  ROCm:      ${GREEN}$ROCM_VERSION${NC}"
echo -e "  Image:     ${GREEN}$REGISTRY_IMAGE${NC}"
echo -e "  Latest:    ${GREEN}$REGISTRY_LATEST${NC}"
echo ""
echo -e "  Deploy:"
echo -e "  ${YELLOW}docker compose -f docker-compose-gfx1151.yaml up -d localai --force-recreate${NC}"
echo ""
echo -e "  Naechstes Upgrade:"
echo -e "  ${YELLOW}bash sync-upstream.sh [--dry-run]${NC}"
echo -e "  ${YELLOW}ROCM_VERSION=7.13 bash sync-upstream.sh${NC}  (wenn neue ROCm-Version verfuegbar)"
