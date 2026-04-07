#!/bin/bash
# =============================================================================
# One-time git setup for the LocalAI ROCm fork
# =============================================================================
# Run once after cloning: bash scripts/install-hooks.sh
#
# Sets up:
#   1. 'ours-rocm' merge driver — keeps our version of protected files when
#      merging upstream (backend/index.yaml, docker-compose.yaml, etc.)
#      Registered in .git/config (local to this repo clone).
#
# Protected files are declared in .gitattributes with merge=ours-rocm.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

cd "$(git rev-parse --show-toplevel)"

# ---------------------------------------------------------------------------
# 1. Register the 'ours-rocm' merge driver (local repo config only)
# ---------------------------------------------------------------------------
# The driver uses git's built-in 'ours' strategy: keep our version, discard
# theirs. This means you NEVER automatically get upstream changes to these
# files — they must be manually reviewed and merged when needed.
#
# To manually merge a protected file after a sync:
#   git checkout upstream/master -- backend/index.yaml  # see upstream version
#   # merge local registry sections back in, then:
#   git checkout HEAD -- backend/index.yaml             # restore ours
#   # hand-edit, then git add + commit
# ---------------------------------------------------------------------------
git config merge.ours-rocm.name "ROCm fork: keep ours on upstream merge"
git config merge.ours-rocm.driver "true"   # 'true' exits 0 = keep working tree

echo -e "${GREEN}Registered merge driver 'ours-rocm' in .git/config${NC}"

# ---------------------------------------------------------------------------
# 2. Verify .gitattributes is in place
# ---------------------------------------------------------------------------
if grep -q 'merge=ours-rocm' .gitattributes 2>/dev/null; then
    echo -e "${GREEN}Protected files declared in .gitattributes${NC}"
else
    echo "WARN: .gitattributes does not reference 'ours-rocm' — check the file"
fi

echo ""
echo -e "${BOLD}Setup complete.${NC}"
echo ""
echo "Protected files (kept on upstream merge):"
grep 'merge=ours-rocm' .gitattributes | awk '{print "  "$1}'
echo ""
echo "To sync upstream:  bash scripts/sync-upstream.sh [--build] [--no-push]"
