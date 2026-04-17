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
    # JSON-escape title+body via python3 so multiline + special chars work cleanly.
    local payload
    payload=$(TITLE="$1" BODY="$2" TAG="${3:-info}" python3 -c '
import json, os
print(json.dumps({
    "title": os.environ["TITLE"],
    "body":  os.environ["BODY"],
    "tag":   os.environ["TAG"],
    "format": "text",
}))
')
    curl -sf -X POST "$APPRISE_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" >/dev/null 2>&1 || true
}

# Build a rich commit-list report for the Apprise notification.
# Shows: category counts, top-level summary, one line per commit with +/- stats.
# Called after a successful merge with $1 = old HEAD, $2 = new HEAD.
_build_sync_report() {
    local old_head="$1" new_head="$2"
    python3 - "$old_head" "$new_head" "$UPSTREAM_VERSION" "$CURRENT_BRANCH" <<'PYEOF'
import re, subprocess, sys
from collections import Counter

old, new, upstream_ver, branch = sys.argv[1:5]

def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()

# Range: old..upstream/master captures the upstream commits that came in (the
# merge commit itself is NOT listed; first-parent path on merge-commit = our branch).
# We want: git log old..new --no-merges — excludes the merge-commit, shows upstream commits.
log = git("log", f"{old}..{new}", "--no-merges",
          "--format=%h%x01%s%x01%an%x01%ci")
commits = []
for line in log.splitlines():
    if not line.strip():
        continue
    parts = line.split("\x01")
    if len(parts) >= 4:
        commits.append(tuple(parts))

# Category detection via Conventional Commits prefix.
CAT_RE = re.compile(r"^(feat|fix|chore|docs|refactor|test|perf|ci|build|style|revert)(\(.+?\))?!?:")
cats = Counter()
for _, subj, *_ in commits:
    m = CAT_RE.match(subj)
    cats[m.group(1) if m else "other"] += 1

# Overall diffstat for the range
try:
    diffstat = git("diff", "--shortstat", f"{old}..{new}")
except subprocess.CalledProcessError:
    diffstat = ""

# Per-commit stat (files+insert+delete) — limit to first N commits in the report
MAX_LINES = 20
lines = []
for sha, subj, author, date in commits[:MAX_LINES]:
    try:
        stat = git("show", "--shortstat", "--format=", sha).strip()
    except subprocess.CalledProcessError:
        stat = ""
    # stat typically like: "5 files changed, 123 insertions(+), 12 deletions(-)"
    files = ins = dels = 0
    m = re.search(r"(\d+) files? changed", stat)
    if m: files = int(m.group(1))
    m = re.search(r"(\d+) insertions?\(\+\)", stat)
    if m: ins = int(m.group(1))
    m = re.search(r"(\d+) deletions?\(-\)", stat)
    if m: dels = int(m.group(1))

    cat_m = CAT_RE.match(subj)
    cat = cat_m.group(1) if cat_m else "other"
    # Trim subject for readability
    short_subj = subj if len(subj) <= 80 else subj[:77] + "..."
    lines.append(f"  [{cat:8}] {sha}  {short_subj}  (+{ins} -{dels} · {files} files)")

more = ""
if len(commits) > MAX_LINES:
    more = f"\n  ... +{len(commits) - MAX_LINES} weitere Commits"

cat_summary = " · ".join(f"{n} {c}" for c, n in cats.most_common())

# Compose final body
body = []
body.append(f"LocalAI sync — upstream {upstream_ver} → {branch}")
body.append(f"HEAD: {new}  ({len(commits)} upstream-Commits)")
body.append(f"Kategorien: {cat_summary}")
if diffstat:
    body.append(f"Gesamt-Diff: {diffstat}")
body.append("")
body.append("Commits:")
body.extend(lines)
body.append(more)
print("\n".join(l for l in body if l is not None))
PYEOF
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

OLD_HEAD=$(git rev-parse HEAD)

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

REPORT=$(_build_sync_report "$OLD_HEAD" "$NEW_HEAD" 2>/dev/null || echo "Report-Generierung fehlgeschlagen — $NEW_COUNT Commits gemerged, HEAD $NEW_HEAD.")

_notify "LocalAI Sync: $UPSTREAM_VERSION (+$NEW_COUNT)" \
    "$REPORT" \
    "info"
