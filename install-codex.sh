#!/bin/bash
# Install/update the agentic system's Codex track into ~/.codex (idempotent).
set -e
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
START="<!-- agentic-system:start -->"
END="<!-- agentic-system:end -->"

# Confirm before mutating anything (skip with --yes/-y).
YES=0; for a in "$@"; do case "$a" in --yes|-y) YES=1;; esac; done
if [ "$YES" != 1 ]; then
  echo "This will modify:"
  echo "  - $CODEX_DIR/prompts/       (prompt files overwritten; existing ones backed up to *.bak.<ts>)"
  echo "  - $CODEX_DIR/automations/   (runner/sync scripts overwritten; backed up to *.bak.<ts>)"
  echo "  - $CODEX_DIR/AGENTS.md      (agentic block appended/replaced; backed up to *.bak.<ts>)"
  printf 'Continue? [y/N] '; read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
fi
TS="$(date +%Y%m%d%H%M%S)"
backup() { [ -e "$1" ] && cp -p "$1" "$1.bak.$TS" || true; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required." >&2; exit 1; }
[ -f "$REPO_DIR/codex/AGENTS.agentic.md" ] || { echo "ERROR: repo incomplete — codex/AGENTS.agentic.md missing." >&2; exit 1; }
ls "$REPO_DIR"/codex/prompts/*.md >/dev/null 2>&1 || { echo "ERROR: repo incomplete — codex/prompts/*.md missing." >&2; exit 1; }

mkdir -p "$CODEX_DIR/prompts" "$CODEX_DIR/automations" "$HOME/.claude/decisions"
for f in "$REPO_DIR"/codex/prompts/*.md; do backup "$CODEX_DIR/prompts/$(basename "$f")"; done
backup "$CODEX_DIR/automations/autodev-runner.sh"
cp "$REPO_DIR"/codex/prompts/*.md "$CODEX_DIR/prompts/"
cp "$REPO_DIR"/scripts/autodev-runner.sh "$CODEX_DIR/automations/"
chmod +x "$CODEX_DIR/automations/autodev-runner.sh"
# The runner installs this pre-push gate into its clone each first run, so it must sit alongside it.
backup "$CODEX_DIR/automations/install-git-prepush.sh"
cp "$REPO_DIR"/scripts/install-git-prepush.sh "$CODEX_DIR/automations/"
chmod +x "$CODEX_DIR/automations/install-git-prepush.sh"
if [ -f "$REPO_DIR/scripts/pending-issue-sync.sh" ]; then
  backup "$CODEX_DIR/automations/pending-issue-sync.sh"
  cp "$REPO_DIR/scripts/pending-issue-sync.sh" "$CODEX_DIR/automations/"
  chmod +x "$CODEX_DIR/automations/pending-issue-sync.sh"
  # Project list is user-owned config — install a starter copy only if none exists yet.
  if [ ! -f "$HOME/.claude/decisions/.sync-projects" ] && [ -f "$REPO_DIR/scripts/.sync-projects.example" ]; then
    cp "$REPO_DIR/scripts/.sync-projects.example" "$HOME/.claude/decisions/.sync-projects.example"
  fi
fi

TARGET="$CODEX_DIR/AGENTS.md"
BLOCK="$REPO_DIR/codex/AGENTS.agentic.md"
backup "$TARGET"
touch "$TARGET"
if grep -qF "$START" "$TARGET"; then
  if ! grep -qF "$END" "$TARGET"; then
    echo "ERROR: $TARGET has a start marker ($START) but no end marker ($END)." >&2
    echo "This usually means a previous install was interrupted, or the end marker was" >&2
    echo "accidentally deleted. Nothing was changed. To fix, either:" >&2
    echo "  - append '$END' to the end of the existing agentic block in $TARGET, then re-run; or" >&2
    echo "  - remove everything from '$START' onward in $TARGET, then re-run to re-append cleanly." >&2
    exit 1
  fi
  python3 - "$TARGET" "$BLOCK" "$START" "$END" <<'EOF'
import sys, re
target, block, start, end = sys.argv[1:5]
t = open(target).read()
b = open(block).read().rstrip("\n")
new, count = re.subn(re.escape(start) + r".*?" + re.escape(end),
                      lambda _: start + "\n" + b + "\n" + end, t, flags=re.S)
if count == 0:
    print(f"ERROR: start/end markers present but the block pattern did not match "
          f"in {target} (unexpected content between markers?). Nothing was changed.",
          file=sys.stderr)
    sys.exit(1)
open(target, "w").write(new)
EOF
  echo "Updated agentic block in $TARGET"
else
  { printf '\n%s\n' "$START"; cat "$BLOCK"; printf '%s\n' "$END"; } >> "$TARGET"
  echo "Appended agentic block to $TARGET"
fi
echo "Installed Codex prompts: $(ls "$REPO_DIR"/codex/prompts/*.md | wc -l | tr -d ' ') (/autodev /autodev-cron /ticket /task)"
echo "Installed shared cron runner: $CODEX_DIR/automations/autodev-runner.sh"
if [ -f "$CODEX_DIR/automations/pending-issue-sync.sh" ]; then
  echo "Installed pending-decision <-> GitHub-Issue syncer: $CODEX_DIR/automations/pending-issue-sync.sh"
  echo "  Configure project list at ~/.claude/decisions/.sync-projects (see .sync-projects.example), then cron it: */15 * * * * $CODEX_DIR/automations/pending-issue-sync.sh >/dev/null 2>&1"
fi
echo "Onboard a project to scheduled autonomous dev: $REPO_DIR/onboard-autodev.sh <repo-dir> [slug] [minute-offset] [--every MINUTES]"
echo "Optional per-repo enforcement: $REPO_DIR/scripts/install-git-prepush.sh <repo>"
command -v codex >/dev/null 2>&1 || echo "WARN: codex CLI not found — install it (npm i -g @openai/codex), or this track will no-op." >&2
