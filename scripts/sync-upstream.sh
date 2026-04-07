#!/bin/bash
# =============================================================================
# LocalAI Upstream Sync Script
# =============================================================================
# Merges upstream/master into our ROCm branch, re-applies local overrides,
# tags the result, and optionally rebuilds + pushes all images.
#
# Background: our fork adds ROCm 7.x support (gfx1151 / Strix Halo).
# The following files contain local overrides that MUST NOT be blindly
# overwritten by upstream merges:
#
#   Dockerfile                    — dpkg passes 1-3 (build-essential fix)
#   Dockerfile.python-rocm7-base  — our entire file, not in upstream
#   backend/Dockerfile.python     — dpkg patches + SKIP_DRIVERS logic (TODO: investigate)
#   backend/index.yaml            — local registry URIs as primary source
#   scripts/build-rocm.sh         — our build orchestration, not in upstream
#   scripts/sync-upstream.sh      — this file
#   docker-compose.yaml           — ROCm device mounts + custom image tags
#
# Usage:
#   bash scripts/sync-upstream.sh                    # merge + verify, no build
#   bash scripts/sync-upstream.sh --build            # merge + build all + push
#   bash scripts/sync-upstream.sh --build --no-push  # merge + build, no push
#   bash scripts/sync-upstream.sh --tag-only         # tag current HEAD, no merge
#
# After running:
#   1. Review any merge conflicts (see PROTECTED FILES above)
#   2. Run: bash scripts/build-rocm.sh [--no-push]
# =============================================================================
set -euo pipefail

OUR_BRANCH="pr/rocm7-gfx1151-build-support"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"
ORIGIN_REMOTE="origin"

DO_BUILD=false
NO_PUSH=false
TAG_ONLY=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

for arg in "$@"; do
    case $arg in
        --build)    DO_BUILD=true ;;
        --no-push)  NO_PUSH=true ;;
        --tag-only) TAG_ONLY=true ;;
    esac
done

# ---------------------------------------------------------------------------
# 0. Sanity: must be on our ROCm branch, tree must be clean
# ---------------------------------------------------------------------------
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "${CURRENT_BRANCH}" != "${OUR_BRANCH}" ]; then
    echo -e "${RED}ERROR: must be on ${OUR_BRANCH}, currently on ${CURRENT_BRANCH}${NC}"
    echo "  Run: git checkout ${OUR_BRANCH}"
    exit 1
fi

if ! git diff --quiet HEAD; then
    echo -e "${RED}ERROR: working tree has uncommitted changes. Commit or stash first.${NC}"
    git status --short
    exit 1
fi

if [ "${TAG_ONLY}" = "true" ]; then
    # Skip merge — just compute version from current go.mod and tag.
    :
else
    # ---------------------------------------------------------------------------
    # 1. Fetch upstream
    # ---------------------------------------------------------------------------
    echo -e "\n${BOLD}=== Fetching ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH} ===${NC}"
    git fetch "${UPSTREAM_REMOTE}"

    UPSTREAM_HEAD=$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}")
    OUR_HEAD=$(git rev-parse HEAD)

    if git merge-base --is-ancestor "${UPSTREAM_HEAD}" "${OUR_HEAD}"; then
        echo -e "  ${GREEN}Already up to date — no new upstream commits.${NC}"
    else
        NEW_COMMITS=$(git log --oneline "${OUR_HEAD}..${UPSTREAM_HEAD}" | wc -l | tr -d ' ')
        echo -e "  ${YELLOW}${NEW_COMMITS} new upstream commits to merge.${NC}"

        # ---------------------------------------------------------------------------
        # 2. Merge with the 'ours' strategy for protected files so git doesn't
        #    auto-overwrite them. We do a standard merge and then check for
        #    conflicts in protected files manually.
        # ---------------------------------------------------------------------------
        echo -e "\n${BOLD}=== Merging upstream ===${NC}"
        if ! git merge --no-ff "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" \
                --strategy-option=patience \
                -m "chore(sync): merge upstream/master @ ${UPSTREAM_HEAD:0:8}"; then

            echo -e "\n${RED}=== MERGE CONFLICTS — manual resolution required ===${NC}"
            echo ""
            echo "Conflicting files:"
            git diff --name-only --diff-filter=U | sed 's/^/  /'
            echo ""
            echo -e "${BOLD}PROTECTED FILES checklist — verify these after resolving conflicts:${NC}"
            echo "  □ Dockerfile            — must keep dpkg passes 1+2+3 (see CLAUDE.md)"
            echo "  □ backend/index.yaml    — must keep local registry URIs as primary"
            echo "  □ docker-compose.yaml   — must keep ROCm device mounts + image tags"
            echo "  □ backend/Dockerfile.python  — check SKIP_DRIVERS logic still present"
            echo ""
            echo "After resolving: git add <files> && git merge --continue"
            echo "Then re-run this script or: bash scripts/build-rocm.sh"
            exit 1
        fi

        echo -e "  ${GREEN}Merge succeeded.${NC}"

        # ---------------------------------------------------------------------------
        # 3. Post-merge: verify protected files still contain our critical patches
        # ---------------------------------------------------------------------------
        echo -e "\n${BOLD}=== Verifying protected overrides ===${NC}"

        VERIFY_FAIL=false

        # Dockerfile must have all 3 dpkg passes
        if ! grep -q 'Pass 2' Dockerfile; then
            echo -e "  ${RED}FAIL: Dockerfile missing dpkg Pass 2!${NC}"
            VERIFY_FAIL=true
        else
            echo -e "  ${GREEN}OK:  Dockerfile dpkg passes present${NC}"
        fi

        # backend/index.yaml must reference our local registry
        if ! grep -q '192.168.178.127\|pointblank.ddns.net' backend/index.yaml 2>/dev/null; then
            echo -e "  ${YELLOW}WARN: backend/index.yaml may have lost local registry URIs${NC}"
            echo -e "       Check: grep -n 'uri:' backend/index.yaml | head -5"
        else
            echo -e "  ${GREEN}OK:  backend/index.yaml local registry URIs present${NC}"
        fi

        if [ "${VERIFY_FAIL}" = "true" ]; then
            echo ""
            echo -e "${RED}One or more protected overrides were lost in the merge.${NC}"
            echo "Inspect the above files, re-apply the patches, commit, then rebuild."
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Compute new version tag from go.mod + ROCm version + upstream HEAD
# ---------------------------------------------------------------------------
UPSTREAM_SHA=$(git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null || git rev-parse HEAD)
UPSTREAM_SHA_SHORT="${UPSTREAM_SHA:0:8}"

# Extract upstream version from go.mod (module line has the path, not the version;
# use git describe on upstream/master instead)
UPSTREAM_VERSION=$(git describe --tags "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" 2>/dev/null \
    | sed 's/^v//' | cut -d'-' -f1 || echo "4.x.x")

ROCM_VERSION="${ROCM_VERSION:-7.12}"
NEW_TAG="v${UPSTREAM_VERSION}-rocm${ROCM_VERSION}-${UPSTREAM_SHA_SHORT}"

echo -e "\n${BOLD}=== Version tag ===${NC}"
echo -e "  Proposed tag: ${CYAN}${NEW_TAG}${NC}"

if git tag | grep -qF "${NEW_TAG}"; then
    echo -e "  ${YELLOW}Tag ${NEW_TAG} already exists — skipping tag creation${NC}"
else
    git tag -a "${NEW_TAG}" -m "ROCm ${ROCM_VERSION} build — upstream @ ${UPSTREAM_SHA_SHORT}"
    echo -e "  ${GREEN}Tagged HEAD as ${NEW_TAG}${NC}"
fi

# ---------------------------------------------------------------------------
# 5. Push tag + branch to origin
# ---------------------------------------------------------------------------
if [ "${NO_PUSH}" != "true" ]; then
    echo -e "\n${BOLD}=== Pushing branch + tag to ${ORIGIN_REMOTE} ===${NC}"
    git push "${ORIGIN_REMOTE}" "${OUR_BRANCH}"
    git push "${ORIGIN_REMOTE}" "${NEW_TAG}"
    echo -e "  ${GREEN}Pushed${NC}"
fi

# ---------------------------------------------------------------------------
# 6. Optionally rebuild and push all images
# ---------------------------------------------------------------------------
if [ "${DO_BUILD}" = "true" ]; then
    PUSH_FLAG=""
    [ "${NO_PUSH}" = "true" ] && PUSH_FLAG="--no-push"
    echo -e "\n${BOLD}=== Starting image rebuild ===${NC}"
    bash "$(dirname "$0")/build-rocm.sh" --rebuild-base ${PUSH_FLAG}
else
    echo -e "\n${BOLD}=== Next step ===${NC}"
    echo "  Build and push images:"
    echo "    bash scripts/build-rocm.sh --rebuild-base"
    echo ""
    echo "  Or build without pushing:"
    echo "    bash scripts/build-rocm.sh --rebuild-base --no-push"
fi
