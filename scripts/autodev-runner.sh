#!/bin/bash
# Canonical autonomous-development cron runner — the ONE runner every project uses.
# Generalizes a proven pattern (real repo, shared token, lock, watchdog, caffeinate)
# so no project ever hand-rolls its own wrapper/clone/token again.
# Usage (from crontab): autodev-runner.sh <repo-dir> [project-slug]
# WARNING: This runner destructively resets and cleans its dedicated working clone; do not point it at a checkout you care about.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"

REPO="${1:?usage: autodev-runner.sh <repo-dir> [project-slug]}"
SLUG="${2:-$(basename "$REPO" | tr '[:upper:] ' '[:lower:]-')}"

# Shared GitHub token — cron/sandbox can't read the macOS keychain, so git/gh need GH_TOKEN
# (git uses gh as credential helper via `gh auth setup-git`). Same source as every runner.
[ -f "$HOME/.codex/secrets/github.env" ] && set -a && . "$HOME/.codex/secrets/github.env" && set +a

STATE="$HOME/.codex/automations/autodev-$SLUG"; mkdir -p "$STATE"
# Per-project prompt override (e.g. a scoped ticket allowlist) wins over the generic one.
PROMPT_FILE="$STATE/prompt.md"
[ -f "$PROMPT_FILE" ] || PROMPT_FILE="$HOME/.codex/prompts/autodev-cron.md"
[ -f "$PROMPT_FILE" ] || { echo "autodev-runner: no prompt ($STATE/prompt.md or ~/.codex/prompts/autodev-cron.md) — run install-codex.sh" >&2; exit 1; }
LOG="$STATE/RUN_LOG.md"
LOCK="/tmp/autodev-$SLUG.lock"
CODEX="$(command -v codex || echo /opt/homebrew/bin/codex)"
# Dedicated clone owned by the shared runner — ALWAYS clean regardless of the dev checkout,
# and its .git lives inside the sandbox workspace so commits/pushes work (a worktree's gitdir
# sits outside the workspace and the sandbox blocks writes to it). Uniform across projects,
# shared token — NOT a per-project bespoke clone/auth.
CLONE="$STATE/repo"

# mkdir lock; a run wedged >105 min is assumed dead and reclaimed (105 > 100-min watchdog,
# so the watchdog always kills a hang before the lock could be reclaimed under it).
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +105 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || exit 0
  else
    echo "$(date '+%F %T') skipped: previous run still active" >> "$LOG"; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Rotate to a timestamped backup instead of clobbering a previous rotation.
[ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 500000 ] && mv "$LOG" "$LOG.bak.$(date +%Y%m%d%H%M%S)"
# Keep one previous run's output rather than silently overwriting it.
[ -f "$STATE/last-message.md" ] && mv "$STATE/last-message.md" "$STATE/last-message.prev.md"

# Prepare a clean clone at origin's default-branch tip. First run clones from the project's
# GitHub URL (shared token via gh credential helper); later runs just fetch + hard-reset.
# The URL is read from a file onboarding stored (so cron never touches the dev checkout —
# it may live in a TCC-protected folder like ~/Desktop that cron can't access); fall back to
# reading it live from $REPO when that's reachable. Any prep failure aborts.
URL="$(cat "$STATE/origin-url" 2>/dev/null || true)"
[ -n "$URL" ] || URL="$(git -C "$REPO" remote get-url origin 2>/dev/null)"
[ -n "$URL" ] || { echo "$(date '+%F %T') abort: no origin URL (run onboard-autodev.sh to record it)" >> "$LOG"; exit 1; }
if [ ! -d "$CLONE/.git" ]; then
  git clone --quiet "$URL" "$CLONE" 2>>"$LOG" || { echo "$(date '+%F %T') abort: clone failed (auth?)" >> "$LOG"; exit 1; }
fi
git -C "$CLONE" fetch origin --quiet 2>>"$LOG" || { echo "$(date '+%F %T') abort: fetch failed (auth?)" >> "$LOG"; exit 1; }
# Base = the integration branch feature PRs target (recorded by onboarding; falls back to a
# 'staging' branch if one exists, else origin's default). Feature work is cut from here and
# PRs target here — promotion to main is the owner's deliberate call, never automation's.
BASE="$(cat "$STATE/base-branch" 2>/dev/null || true)"
if [ -z "$BASE" ]; then
  git -C "$CLONE" show-ref --verify --quiet refs/remotes/origin/staging && BASE=staging \
    || BASE="$(git -C "$CLONE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
fi
BASE="${BASE:-main}"
git -C "$CLONE" checkout -q -B "$BASE" "origin/$BASE" 2>>"$LOG" \
  && git -C "$CLONE" reset --hard "origin/$BASE" --quiet 2>>"$LOG" \
  && git -C "$CLONE" clean -fdq 2>>"$LOG" \
  || { echo "$(date '+%F %T') abort: checkout $BASE failed" >> "$LOG"; exit 1; }

# Mechanical push gate for autonomous pushes: install the AGENTIC_GREEN pre-push hook into the
# clone once. `git reset --hard`/`clean -fdq` never touch .git/hooks, so it persists across ticks;
# only reinstall if absent (avoids a backup file per tick). Non-fatal — a hook-install failure
# must not abort the run. Single-sourced from install-git-prepush.sh, copied here by install-codex.sh.
PREPUSH="$HOME/.codex/automations/install-git-prepush.sh"
[ -f "$CLONE/.git/hooks/pre-push" ] || { [ -f "$PREPUSH" ] && "$PREPUSH" --yes "$CLONE" >>"$LOG" 2>&1 || true; }

# Cron has no $ARGUMENTS — give the prompt its project context explicitly.
# Policy: every repo targets its integration branch (staging); PRs NEVER target main.
CTX="RUNNER-DRIVEN CONTEXT — Project slug: $SLUG. You are in an isolated clone at $CLONE, already clean on the base branch '$BASE' at origin's tip, with origin pointing at the project's GitHub remote. The runner holds the run lock and prepared this checkout, so SKIP the overlap-guard and sync steps entirely and do NOT create any lock file. Cut your feature branch from '$BASE'; commit and push, then open the PR with base='$BASE'. NEVER target 'main' and NEVER open a promote-to-main / release-to-main PR — promotion of '$BASE' to main is the owner's deliberate call; park any such task in the decision queue with a recommendation instead of doing it. Decision/work-log file: ~/.claude/decisions/$SLUG.md."

{
  echo ""
  echo "## Run $(date '+%F %T') — $SLUG"
  caffeinate -i "$CODEX" exec \
    -C "$CLONE" \
    -m gpt-5.6-terra \
    -c 'model_reasoning_effort="high"' \
    -s workspace-write \
    -c sandbox_workspace_write.network_access=true \
    -c "sandbox_workspace_write.writable_roots=[\"$CLONE/.git\"]" \
    -c shell_environment_policy.inherit=all \
    --add-dir "$STATE" \
    --add-dir "$HOME/.claude/decisions" \
    --add-dir /private/tmp \
    --skip-git-repo-check \
    -o "$STATE/last-message.md" \
    "$CTX"$'\n\n'"$(cat "$PROMPT_FILE")" 2>&1 | tail -40 &
  RUNPID=$!
  # 100-min watchdog — a true hang (wedged lint, sleep-suspended, stuck network) can't
  # outlive the cadence. This is exactly the failure mode a hand-rolled wrapper missed.
  ( sleep 6000; echo "$(date '+%F %T') WATCHDOG: killing run after 100min" >> "$LOG"; pkill -9 -P $RUNPID 2>/dev/null; kill -9 $RUNPID 2>/dev/null ) & WDPID=$!
  wait $RUNPID; RC=$?
  pkill -P $WDPID 2>/dev/null; kill $WDPID 2>/dev/null
  echo "## End $(date '+%F %T') (exit $RC)"
} >> "$LOG"

# Notify when PRs await merge.
PRS=$(grep -oE 'https://github.com/[^ )]+/pull/[0-9]+' "$STATE/last-message.md" 2>/dev/null | sort -u)
N=$(echo "$PRS" | grep -c pull 2>/dev/null || echo 0)
[ "$N" -gt 0 ] && osascript -e "display notification \"$N PR(s) awaiting merge — $SLUG\" with title \"Agentic run needs you\" sound name \"Glass\"" 2>/dev/null
exit 0
