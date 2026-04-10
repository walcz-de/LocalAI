#!/bin/bash
# =============================================================================
# Nightly Sync — upstream/master holen, ROCm-Patch oben neu auflegen
# =============================================================================
# Läuft täglich um 03:00 via Cron.
# Strategie: rebase (nicht merge) — upstream-Commits kommen rein,
# unsere ROCm-Commits bleiben sauber auf der Spitze.
#
# Crontab-Eintrag:
#   0 3 * * * bash /home/stefanwalcz/Repo/LocalAI/nightly-sync.sh >> /var/log/localai-nightly-sync.log 2>&1
# =============================================================================
set -euo pipefail

REPO_DIR="/home/stefanwalcz/Repo/LocalAI"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"
APPRISE_URL="http://localhost:8000/notify/apprise"

_notify() {
    curl -sf -X POST "$APPRISE_URL" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"$1\",\"body\":\"$2\",\"tag\":\"${3:-info}\"}" \
        >/dev/null 2>&1 || true
}

echo "=== LocalAI Nightly Sync — $(date '+%Y-%m-%d %H:%M') ==="

cd "$REPO_DIR"

# Sicherheitscheck: uncommitted changes verhindern den Rebase
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "FEHLER: Uncommitted changes im Repo — Sync abgebrochen."
    _notify "LocalAI Sync: ABGEBROCHEN" "Uncommitted changes im Repo. Bitte prüfen." "error"
    exit 1
fi

echo "Fetching $UPSTREAM_REMOTE..."
git fetch "$UPSTREAM_REMOTE"

# Wieviele neue Commits gibt es upstream?
NEW_COUNT=$(git rev-list HEAD.."$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --count 2>/dev/null || echo "0")
UPSTREAM_VERSION=$(git describe --tags --abbrev=0 "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo "dev")

echo "Upstream: $UPSTREAM_VERSION — $NEW_COUNT neue Commits"

if [ "$NEW_COUNT" = "0" ]; then
    echo "Bereits auf aktuellem Stand. Kein Rebase nötig."
    exit 0
fi

# Unsere lokalen Commits (nicht in upstream/master)
OUR_COMMITS=$(git log --oneline "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"..HEAD)
OUR_COUNT=$(echo "$OUR_COMMITS" | grep -c . || true)
echo "Unsere lokalen Commits (werden neu aufgelegt): $OUR_COUNT"
echo "$OUR_COMMITS"

# Rebase: neue upstream-Commits reinkommen, unsere Patches obendrauf
echo "Starte rebase auf $UPSTREAM_REMOTE/$UPSTREAM_BRANCH..."
if ! git rebase "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    echo "FEHLER: Rebase-Konflikt in: $CONFLICTS"
    _notify "LocalAI Sync: KONFLIKT" \
        "Rebase $UPSTREAM_VERSION fehlgeschlagen. Konflikte in: $CONFLICTS — bitte manuell lösen." \
        "error"
    git rebase --abort 2>/dev/null || true
    exit 1
fi

NEW_HEAD=$(git rev-parse --short HEAD)
echo "Rebase OK: $UPSTREAM_VERSION (+$NEW_COUNT Commits), neuer HEAD: $NEW_HEAD"
_notify "LocalAI Sync: $UPSTREAM_VERSION" \
    "$NEW_COUNT neue upstream-Commits. ROCm-Patch neu aufgelegt. HEAD: $NEW_HEAD" \
    "info"
