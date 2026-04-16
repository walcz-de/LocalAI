#!/bin/bash
# =============================================================================
# Nightly Sync — upstream/master holen und in unseren gfx1151/ROCm-Fork mergen
# =============================================================================
# Läuft täglich um 03:00 via Cron.
#
# Strategie: MERGE (nicht rebase) — unsere ROCm-Commits bleiben als eigene
# Commits im Branch stehen, upstream wird als Merge-Commit reingezogen. Das ist
# robust gegen große Commit-Mengen auf beiden Seiten (rebase würde bei jedem
# Commit neu konflikten, merge löst alles in einem Rutsch).
#
# Bei Merge-Konflikten: sauber abbrechen, Apprise-Notification senden, damit
# der Konflikt manuell gelöst werden kann. Niemals automatisch "-Xtheirs/ours"
# benutzen — das würde unsere ROCm-Anpassungen oder kritische upstream-Fixes
# wortlos verwerfen.
#
# Crontab-Eintrag:
#   0 3 * * * bash /home/stefanwalcz/Repo/LocalAI/nightly-sync.sh >> /var/log/localai-nightly-sync.log 2>&1
# =============================================================================
set -euo pipefail

REPO_DIR="/home/stefanwalcz/Repo/LocalAI"
UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="master"
APPRISE_URL="http://localhost:8085/notify/apprise"

_notify() {
    curl -sf -X POST "$APPRISE_URL" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"$1\",\"body\":\"$2\",\"tag\":\"${3:-info}\"}" \
        >/dev/null 2>&1 || true
}

echo "=== LocalAI Nightly Sync — $(date '+%Y-%m-%d %H:%M') ==="

cd "$REPO_DIR"

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Branch: $CURRENT_BRANCH"

# Sicherheitscheck: uncommitted changes blockieren den Merge
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "FEHLER: Uncommitted changes im Repo — Sync abgebrochen."
    _notify "LocalAI Sync: ABGEBROCHEN" \
        "Uncommitted changes auf $CURRENT_BRANCH. Bitte committen oder stashen." \
        "error"
    exit 1
fi

# Fall zurück in einen konsistenten Zustand, falls ein vorheriger Lauf abbrach
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    echo "WARNUNG: stehengebliebene rebase-Reste gefunden — aborten."
    git rebase --abort 2>/dev/null || true
fi
if [ -f .git/MERGE_HEAD ]; then
    echo "WARNUNG: stehengebliebener Merge gefunden — aborten."
    git merge --abort 2>/dev/null || true
fi

echo "Fetching $UPSTREAM_REMOTE..."
git fetch "$UPSTREAM_REMOTE"

NEW_COUNT=$(git rev-list HEAD.."$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --count 2>/dev/null || echo "0")
UPSTREAM_VERSION=$(git describe --tags --abbrev=0 "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" 2>/dev/null || echo "dev")

echo "Upstream: $UPSTREAM_VERSION — $NEW_COUNT neue Commits"

if [ "$NEW_COUNT" = "0" ]; then
    echo "Bereits auf aktuellem Stand. Nichts zu tun."
    exit 0
fi

# Unsere lokalen Commits (nicht in upstream/master)
OUR_COMMITS=$(git log --oneline "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"..HEAD || true)
OUR_COUNT=$(echo "$OUR_COMMITS" | grep -c . || true)
echo "Unsere lokalen Commits (bleiben erhalten): $OUR_COUNT"
echo "$OUR_COMMITS"

# Merge: unsere Commits bleiben stehen, upstream kommt als Merge-Commit rein.
# --no-edit: Standard-Merge-Message ohne Editor.
# --no-ff: explizit Merge-Commit erzwingen (auch wenn fast-forward möglich wäre),
#          damit der Sync im git log klar sichtbar bleibt.
echo "Starte merge von $UPSTREAM_REMOTE/$UPSTREAM_BRANCH in $CURRENT_BRANCH..."
if ! git merge --no-edit --no-ff "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
    CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    echo "FEHLER: Merge-Konflikt in: $CONFLICTS"
    _notify "LocalAI Sync: KONFLIKT" \
        "Merge $UPSTREAM_VERSION fehlgeschlagen. Konflikte in: $CONFLICTS — bitte manuell lösen (git merge --abort zum Zurücksetzen)." \
        "error"
    # Merge NICHT automatisch abbrechen — Konflikt-State bleibt fürs manuelle Fixen stehen.
    # Wenn das nächste Mal das Script läuft, räumt der Sicherheitscheck oben auf, falls nötig.
    exit 1
fi

NEW_HEAD=$(git rev-parse --short HEAD)
echo "Merge OK: $UPSTREAM_VERSION (+$NEW_COUNT Commits), neuer HEAD: $NEW_HEAD"
_notify "LocalAI Sync: $UPSTREAM_VERSION" \
    "$NEW_COUNT neue upstream-Commits in $CURRENT_BRANCH gemerged. HEAD: $NEW_HEAD" \
    "info"
