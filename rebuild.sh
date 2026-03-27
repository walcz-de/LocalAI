#!/bin/bash
# =============================================================================
# LocalAI Rebuild & Deploy – Strix Halo gfx1151
# =============================================================================
set -euo pipefail

REGISTRY="${REGISTRY:-192.168.178.127:5000}"
ROCM_VERSION="${ROCM_VERSION:-7.12}"
TAG="${TAG:-latest-gfx1151}"
IMAGE="$REGISTRY/localai:$TAG"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/agntsio}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

# --- Pre-build checks -------------------------------------------------------
echo -e "${BOLD}=== Pre-build Checks ===${NC}"
FAIL=0

if grep -q "^ENV GGML_CUDA_ENABLE_UNIFIED_MEMORY" Dockerfile 2>/dev/null; then
    echo -e "${RED}✗ GGML_CUDA_ENABLE_UNIFIED_MEMORY in Dockerfile! Entfernen – sonst 32GB statt 96GB VRAM.${NC}"
    FAIL=1
else
    echo -e "${GREEN}✓ GGML_CUDA_ENABLE_UNIFIED_MEMORY nicht in Dockerfile${NC}"
fi

if grep -q "UNIFIED_MEMORY" "$COMPOSE_DIR/docker-compose.yaml" 2>/dev/null; then
    echo -e "${RED}✗ GGML_CUDA_ENABLE_UNIFIED_MEMORY in docker-compose.yaml! Entfernen.${NC}"
    FAIL=1
else
    echo -e "${GREEN}✓ GGML_CUDA_ENABLE_UNIFIED_MEMORY nicht in docker-compose.yaml${NC}"
fi

ENV_YAMLS=$(grep -l "^env:" "$COMPOSE_DIR/models/"*.yaml 2>/dev/null || true)
if [ -n "$ENV_YAMLS" ]; then
    echo -e "${RED}✗ env: Sektionen in Model-YAMLs gefunden:${NC}"
    echo "$ENV_YAMLS"
    FAIL=1
else
    echo -e "${GREEN}✓ Keine env: Sektionen in Model-YAMLs${NC}"
fi

DUPES=$(grep -h "^name:" "$COMPOSE_DIR/models/"*.yaml 2>/dev/null | sort | uniq -d || true)
if [ -n "$DUPES" ]; then
    echo -e "${RED}✗ Doppelte Model-Namen:${NC} $DUPES"
    FAIL=1
else
    echo -e "${GREEN}✓ Keine doppelten Model-Namen${NC}"
fi

[ "$FAIL" = "1" ] && { echo -e "\n${RED}Checks fehlgeschlagen. Build abgebrochen.${NC}"; exit 1; }
echo ""

# --- Build ------------------------------------------------------------------
echo -e "${BOLD}=== Build ===${NC}"
docker build \
    --build-arg BUILD_TYPE=hipblas \
    --build-arg GPU_TARGETS=gfx1151 \
    -t localai:rocm-gfx1151 \
    . 2>&1 | tee /tmp/localai-build.log
echo -e "${GREEN}✓ Build fertig${NC}\n"

# --- Push -------------------------------------------------------------------
echo -e "${BOLD}=== Push → $IMAGE ===${NC}"
docker tag localai:rocm-gfx1151 "$IMAGE"
docker push "$IMAGE"
echo -e "${GREEN}✓ Push fertig${NC}\n"

# --- Deploy -----------------------------------------------------------------
echo -e "${BOLD}=== Deploy ===${NC}"
cd "$COMPOSE_DIR"
docker compose pull localai
docker compose up -d localai --force-recreate
echo -e "${GREEN}✓ Container neu gestartet${NC}\n"

# --- Verify -----------------------------------------------------------------
echo -e "${BOLD}=== Verifikation ===${NC}"
sleep 8
UNIFIED=$(docker exec agntsio-localai-1 env 2>/dev/null | grep UNIFIED_MEMORY || true)
if [ -n "$UNIFIED" ]; then
    echo -e "${RED}✗ GGML_CUDA_ENABLE_UNIFIED_MEMORY ist noch gesetzt: $UNIFIED${NC}"
    echo -e "${YELLOW}  → 'docker compose up -d localai --force-recreate' nochmal ausführen${NC}"
else
    echo -e "${GREEN}✓ GGML_CUDA_ENABLE_UNIFIED_MEMORY nicht gesetzt – hipMalloc aktiv (96GB VRAM)${NC}"
fi

VRAM_USED=$(rocm-smi --showmeminfo vram 2>/dev/null | grep "Used Memory" | awk '{print $NF}')
echo -e "  VRAM Used jetzt: ${VRAM_USED} Bytes (steigt beim ersten Modell-Load auf ~GB-Bereich)"
echo ""
echo -e "${GREEN}${BOLD}=== Fertig ===${NC}"
