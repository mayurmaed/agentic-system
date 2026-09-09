#!/bin/bash
# Canonical autonomous-development cron runner — the ONE runner every project uses.
# Generalizes the proven RB2 pattern (real repo, shared token, lock, watchdog, caffeinate)
# so no project ever hand-rolls its own wrapper/clone/token again.
# Usage (from crontab): autodev-runner.sh <repo-dir> [project-slug]
#
# ┌─ IMPORTANT — CLAUDE-TRACK FALLBACK IS OFF BY DEFAULT ───────────────────────┐
# │ When Codex hits its usage cap, a tick normally just no-ops and logs.        │
# │ You can opt in to having the run continue on the Claude CLI instead:        │
# │                                                                            │
# │     touch ~/.codex/automations/claude-fallback-approved                     │
# │                                                                            │
# │ READ THIS BEFORE ENABLING IT. The fallback runs `claude -p` with            │
# │ --dangerously-skip-permissions, which means an unattended agent that        │
# │ writes code, commits, pushes, and opens PRs with NO per-action approval     │
# │ prompt. That is the same authority the Codex path already has, but it       │
# │ spends a different budget and bypasses Claude's trust gate. Enable it       │
# │ only on a machine you own, for repos you own, with branch protection on     │
# │ your default branch. It is never enabled by installing this template.       │
# │                                                                            │
# │ The flag is global (one approval covers every lane) and the runner DELETES  │
# │ it automatically as soon as Codex recovers, so the opt-in cannot silently   │
# │ outlive the outage. See the README section "Codex quota exhaustion".        │
# └────────────────────────────────────────────────────────────────────────────┘
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"

REPO="${1:?usage: autodev-runner.sh <repo-dir> [project-slug]}"
SLUG="${2:-$(basename "$REPO" | tr '[:upper:] ' '[:lower:]-')}"

# Shared GitHub token — cron/sandbox can't read the macOS keychain, so git/gh need GH_TOKEN
# (git uses gh as credential helper via `gh auth setup-git`). Same source as every runner.
[ -f "$HOME/.codex/secrets/github.env" ] && set -a && . "$HOME/.codex/secrets/github.env" && set +a
# Claude-track fallback auth: `claude setup-token` stores creds in the macOS Keychain, which
# cron/headless shells can't read. This file carries CLAUDE_CODE_OAUTH_TOKEN (the long-lived
# token setup-token prints) so `claude -p` authenticates without the Keychain. Owner-populated.
[ -f "$HOME/.codex/secrets/claude.env" ] && set -a && . "$HOME/.codex/secrets/claude.env" && set +a

STATE="$HOME/.codex/automations/autodev-$SLUG"; mkdir -p "$STATE"
# Optional per-automation extra secrets (e.g. a read-only Supabase key for a job that queries
# app data directly) — generic opt-in, not project-specific. Never committed: lives only in
# the state dir, outside the git clone, and is never written into $CTX or the transcript.
[ -f "$STATE/secrets.env" ] && set -a && . "$STATE/secrets.env" && set +a
# Per-project prompt override (e.g. a scoped ticket allowlist) wins over the generic one.
PROMPT_FILE="$STATE/prompt.md"
[ -f "$PROMPT_FILE" ] || PROMPT_FILE="$HOME/.codex/prompts/autodev-cron.md"
[ -f "$PROMPT_FILE" ] || { echo "autodev-runner: no prompt ($STATE/prompt.md or ~/.codex/prompts/autodev-cron.md) — run install-codex.sh" >&2; exit 1; }
LOG="$STATE/RUN_LOG.md"
CODEX_OUTPUT="$STATE/codex-output.log"
LOCK="/tmp/autodev-$SLUG.lock"
LOCK_PID_FILE="$LOCK/pid"
CODEX="${AUTODEV_CODEX_BIN:-$(command -v codex || echo /opt/homebrew/bin/codex)}"
# Dedicated clone owned by the shared runner — ALWAYS clean regardless of the dev checkout,
# and its .git lives inside the sandbox workspace so commits/pushes work (a worktree's gitdir
# sits outside the workspace and the sandbox blocks writes to it). Uniform across projects,
# shared token — NOT a per-project bespoke clone/auth.
CLONE="$STATE/repo"

# mkdir is atomic. A live runner owns its lock regardless of age: the watchdog is
# responsible for ending it, so a delayed watchdog must never create overlap.
if ! mkdir "$LOCK" 2>/dev/null; then
  LOCK_PID="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
  LOCK_COMMAND=""
  [ -n "$LOCK_PID" ] && LOCK_COMMAND="$(ps -p "$LOCK_PID" -o command= 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    if [ -z "$LOCK_COMMAND" ] || printf '%s' "$LOCK_COMMAND" | grep -Fq 'autodev-runner.sh'; then
      echo "$(date '+%F %T') skipped: previous run still active" >> "$LOG"; exit 0
    fi
  fi
  rm -f "$LOCK_PID_FILE" 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || { echo "$(date '+%F %T') skipped: lock changed while reclaiming" >> "$LOG"; exit 0; }
  echo "$(date '+%F %T') reclaimed stale lock (pid=${LOCK_PID:-missing})" >> "$LOG"
fi
printf '%s\n' "$$" > "$LOCK_PID_FILE" || { rmdir "$LOCK" 2>/dev/null; exit 1; }
# shellcheck disable=SC2329 # invoked through the EXIT trap below
cleanup_lock() {
  [ -n "${RUNPID:-}" ] && kill -KILL -- "-$RUNPID" 2>/dev/null
  rm -f "$LOCK_PID_FILE" 2>/dev/null
  rmdir "$LOCK" 2>/dev/null
}
trap cleanup_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 500000 ] && mv "$LOG" "$LOG.1"

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
# -f: a run that dies mid-flight can leave tracked files dirty; without force the checkout
# refuses and every subsequent tick aborts (observed: one lane wedged for 49 consecutive ticks).
git -C "$CLONE" checkout -qf -B "$BASE" "origin/$BASE" 2>>"$LOG" \
  && git -C "$CLONE" reset --hard "origin/$BASE" --quiet 2>>"$LOG" \
  && git -C "$CLONE" clean -fdq 2>>"$LOG" \
  || { echo "$(date '+%F %T') abort: checkout $BASE failed" >> "$LOG"; exit 1; }

# Cron has no $ARGUMENTS — give the prompt its project context explicitly.
# Policy: every repo targets its integration branch (staging); PRs NEVER target main.
# Decisions-slug override: lets multiple tracks/slugs on the SAME project (e.g. RB2.0's
# Track A/B/C, each its own state/clone/lock) share one canonical decision log instead of
# each writing a fragmented per-track file. Falls back to $SLUG when no override is set.
DECISIONS_SLUG="$(cat "$STATE/decisions-slug" 2>/dev/null || echo "$SLUG")"
# Migration handoff lives in CTX, not in a prompt file: a per-project $STATE/prompt.md
# REPLACES the generic prompt (see PROMPT_FILE above), so a rule added only to
# ~/.codex/prompts/autodev-cron.md would silently miss every project that has an override.
# CTX is prepended to every run unconditionally, so this reaches all tracks. Incident that
# motivated it: a migration merged to staging and sat unapplied for 2 days, invisible until
# the tag-triggered deploy's ledger-verify hard-failed.
CTX="RUNNER-DRIVEN CONTEXT — Project slug: $SLUG. You are in an isolated clone at $CLONE, already clean on the base branch '$BASE' at origin's tip, with origin pointing at the project's GitHub remote. The runner holds the run lock and prepared this checkout, so SKIP the overlap-guard and sync steps entirely and do NOT create any lock file. Cut your feature branch from '$BASE'; commit and push, then open the PR with base='$BASE'. NEVER target 'main' and NEVER open a promote-to-main / release-to-main PR — promotion of '$BASE' to main is the owner's deliberate call; park any such task in the decision queue with a recommendation instead of doing it. Decision/work-log file: ~/.claude/decisions/$DECISIONS_SLUG.md. MIGRATION HANDOFF — MANDATORY: if this run's diff adds or modifies ANY database migration file (e.g. anything under supabase/migrations/ or the project's migration directory), the work is NOT complete when the PR opens. Applying migrations to live databases is the owner's manual step and you must NEVER apply one yourself. Before you finish, append a row to the '## Pending Decisions' table in the decision/work-log file above naming: the exact migration filename, the PR number, and that it must be (a) applied to the staging database, (b) applied to production at promotion time, and (c) recorded in the migration ledger table if the project keeps one — otherwise the tag-triggered deploy's ledger-verify step will hard-fail. State it as a required manual step, not a suggestion, and repeat the filename verbatim in your final run summary so it surfaces in the run archive."

# The balanced tier stays the default tick model — every lane pays for this on every run.
# Override per lane from its crontab line (AUTODEV_MODEL=<top-tier model>) when one project
# genuinely needs the strongest tier; never raise it globally, and never fork the runner.
RUN_MODEL="${AUTODEV_MODEL:-gpt-5.6-terra}"
RUN_EFFORT="${AUTODEV_EFFORT:-high}"
# Single epoch snapshot for this run, formatted two ways, so the log header and the archived
# per-run message filename always correlate exactly (no drift between the two date calls).
RUN_START_EPOCH=$(date +%s)
RUN_START_LOG="$(date -r "$RUN_START_EPOCH" '+%F %T')"
RUN_START_FILE="$(date -r "$RUN_START_EPOCH" '+%Y%m%dT%H%M%S')"
{
  echo ""
  echo "## Run $RUN_START_LOG — $SLUG (model=$RUN_MODEL effort=$RUN_EFFORT)"
  # perl setpgrp gives this run a private process group on macOS, including
  # caffeinate, codex, and Codex's vendored child, so timeout cleanup is whole-tree.
  if [ "${AUTODEV_NO_CAFFEINATE:-0}" = 1 ]; then
    RUN_COMMAND=( "$CODEX" exec )
  else
    RUN_COMMAND=( caffeinate -i "$CODEX" exec )
  fi
  perl -e 'setpgrp; exec @ARGV' -- "${RUN_COMMAND[@]}" \
    -C "$CLONE" \
    -m "$RUN_MODEL" \
    -c "model_reasoning_effort=\"$RUN_EFFORT\"" \
    -s workspace-write \
    -c sandbox_workspace_write.network_access=true \
    -c "sandbox_workspace_write.writable_roots=[\"$CLONE/.git\"]" \
    -c shell_environment_policy.inherit=all \
    --add-dir "$STATE" \
    --add-dir "$HOME/.claude/decisions" \
    --add-dir /private/tmp \
    --skip-git-repo-check \
    -o "$STATE/last-message.md" \
    "$CTX"$'\n\n'"$(cat "$PROMPT_FILE")" >"$CODEX_OUTPUT" 2>&1 &
  RUNPID=$!
  # 100-min watchdog — TERM the entire run group, then KILL it after a grace period.
  ( sleep "${AUTODEV_WATCHDOG_SECONDS:-6000}"
    echo "$(date '+%F %T') WATCHDOG: killing run after ${AUTODEV_WATCHDOG_SECONDS:-6000}s" >> "$LOG"
    kill -TERM -- "-$RUNPID" 2>/dev/null
    for _ in $(seq 1 "${AUTODEV_WATCHDOG_GRACE_SECONDS:-15}"); do
      kill -0 -- "-$RUNPID" 2>/dev/null || exit 0
      sleep 1
    done
    echo "$(date '+%F %T') WATCHDOG: escalating to KILL" >> "$LOG"
    kill -KILL -- "-$RUNPID" 2>/dev/null
  ) & WDPID=$!
  wait $RUNPID; RC=$?
  pkill -P "$WDPID" 2>/dev/null; kill "$WDPID" 2>/dev/null; wait "$WDPID" 2>/dev/null
  tail -40 "$CODEX_OUTPUT"
  # ponytail: codex's exit status is only trustworthy now that its output goes to a file
  # instead of a pipe — `wait` used to return tail's status, so a dead run still read as 0.
  # The quota string is checked separately because codex exits 0 on it.
  grep -Fq "ERROR: You've hit your usage limit." "$CODEX_OUTPUT" && RC=1
  echo "## End $(date '+%F %T') (exit $RC)"
} >> "$LOG"

# ── Approval-gated Claude-track fallback ──────────────────────────────────────
# Codex exhausts its usage quota for days at a time (the cap string above sets RC=1).
# Rather than no-op every tick until it resets, fall back to the Claude CLI — but ONLY
# after the owner approves, since it spends a different budget and pushes real code.
# Approval = presence of $FALLBACK_FLAG (global, so one approval covers every lane).
# The runner clears it automatically once Codex recovers, so the Claude budget isn't
# spent past the outage. Override the ask with AUTODEV_NO_FALLBACK=1.
FALLBACK_FLAG="$HOME/.codex/automations/claude-fallback-approved"
PENDING_MARK="$HOME/.codex/automations/.fallback-approval-pending"
CAP_HIT=0; grep -Fq "ERROR: You've hit your usage limit." "$CODEX_OUTPUT" && CAP_HIT=1

if [ "$CAP_HIT" = 1 ] && [ -f "$FALLBACK_FLAG" ] && [ "${AUTODEV_NO_FALLBACK:-0}" != 1 ]; then
  CLAUDE="${AUTODEV_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
  CLAUDE_MODEL="${AUTODEV_CLAUDE_MODEL:-sonnet}"
  # Codex is dead this window — tell Claude to implement directly instead of honouring the
  # global "delegate everything to Codex" policy (that would just bounce off the same cap).
  FB_NOTE="CODEX IS QUOTA-EXHAUSTED THIS WINDOW. Do NOT delegate to Codex or the codex:rescue agent — it will fail on the same cap. Do the full plan/implement/test/review yourself with your own tools in this clone."
  echo "$(date '+%F %T') Codex capped — running Claude-track fallback (approved, model=$CLAUDE_MODEL)" >> "$LOG"
  # claude -p reads the prompt from stdin (a trailing positional is not picked up under
  # --print), so stage it in a file and redirect it in. --dangerously-skip-permissions
  # bypasses the per-directory trust gate for this headless clone.
  FB_PROMPT="$STATE/.fallback-prompt.txt"
  printf '%s\n\n%s\n\n%s' "$FB_NOTE" "$CTX" "$(cat "$PROMPT_FILE")" > "$FB_PROMPT"
  {
    echo ""
    echo "## Run $(date '+%F %T') — $SLUG (CLAUDE FALLBACK model=$CLAUDE_MODEL)"
    ( cd "$CLONE" && perl -e 'setpgrp; exec @ARGV' -- \
        "$CLAUDE" -p --model "$CLAUDE_MODEL" \
        --dangerously-skip-permissions \
        --add-dir "$STATE" --add-dir "$HOME/.claude/decisions" \
    ) <"$FB_PROMPT" >"$STATE/last-message.md" 2>"$CODEX_OUTPUT" &
    RUNPID=$!
    ( sleep "${AUTODEV_WATCHDOG_SECONDS:-6000}"
      kill -TERM -- "-$RUNPID" 2>/dev/null
      for _ in $(seq 1 "${AUTODEV_WATCHDOG_GRACE_SECONDS:-15}"); do kill -0 -- "-$RUNPID" 2>/dev/null || exit 0; sleep 1; done
      kill -KILL -- "-$RUNPID" 2>/dev/null ) & WDPID=$!
    wait $RUNPID; RC=$?
    pkill -P "$WDPID" 2>/dev/null; kill "$WDPID" 2>/dev/null; wait "$WDPID" 2>/dev/null
    tail -40 "$STATE/last-message.md"
    echo "## End $(date '+%F %T') (exit $RC via Claude fallback)"
  } >> "$LOG"
  RUN_START_EPOCH=$(stat -f %m "$STATE/last-message.md" 2>/dev/null || echo "$RUN_START_EPOCH")
  RUN_START_EPOCH=$((RUN_START_EPOCH - 1))  # freshness gate below is >=, keep the just-written message fresh
elif [ "$CAP_HIT" = 1 ]; then
  # ponytail: no notification. The ask used to fire here, but PENDING_MARK is cleared by any
  # healthy lane (below), so with several lanes and a partially-exhausted quota it re-asked
  # every few minutes for an approval the owner doesn't want. The fallback still exists —
  # `touch $FALLBACK_FLAG` by hand to enable it. Capped ticks just no-op and log.
  echo "$(date '+%F %T') Codex capped — no-op (fallback not approved; touch $FALLBACK_FLAG to enable)" >> "$LOG"
elif [ "$CAP_HIT" = 0 ]; then
  # Codex is healthy again — retire the outage markers so we revert to the cheaper track.
  rm -f "$PENDING_MARK"
  if [ -f "$FALLBACK_FLAG" ]; then
    rm -f "$FALLBACK_FLAG"
    echo "$(date '+%F %T') Codex recovered — cleared Claude fallback flag" >> "$LOG"
    osascript -e "display notification \"Codex recovered — reverted to Codex track\" with title \"Autodev\" sound name \"Glass\"" 2>/dev/null
  fi
fi

# ponytail: codex leaves the PREVIOUS run's last-message.md in place when it dies early
# (quota, connector-not-present), so every consumer below was reading a stale file — that's
# what re-notified about already-merged PRs each tick. One freshness gate, used by both.
FRESH=0
[ -f "$STATE/last-message.md" ] \
  && [ "$(stat -f %m "$STATE/last-message.md")" -ge "$RUN_START_EPOCH" ] \
  && FRESH=1
[ "$FRESH" = 0 ] && echo "$(date '+%F %T') WARN: no fresh last-message.md this run (stale output not reused)" >> "$LOG"

# Archive this run's final message under its own timestamped file — last-message.md gets
# overwritten every run, so without this, run history beyond "the very latest" only has noisy
# raw log-tail text to go on, not the clean structured outcome. Retention: keep the most recent
# 200 archives per automation (BSD `head` has no `-n -N`, so count-then-trim instead of relying
# on GNU-only negative offsets — this runs on macOS).
mkdir -p "$STATE/runs"
if [ "$FRESH" = 1 ]; then
  { echo "<!-- exit=$RC start=$RUN_START_LOG -->"; cat "$STATE/last-message.md"; } > "$STATE/runs/$RUN_START_FILE.md"
fi
RUNS_COUNT=$(ls -1 "$STATE/runs" 2>/dev/null | wc -l | tr -d ' ')
if [ "${RUNS_COUNT:-0}" -gt 200 ]; then
  ls -1 "$STATE/runs" | sort | head -n "$((RUNS_COUNT - 200))" | while read -r f; do rm -f "$STATE/runs/$f"; done
fi

# Notify when PRs await merge — only from THIS run's output, and only for PRs still open.
# ponytail: read ONLY the summary's "AWAITING MERGE" line, not the whole message — runs routinely
# cite PRs in prose ("PROJ-257 is already merged via #483"), and grepping the full text turned every
# such mention into a merge nag for work this lane had already finished.
N=0
TICKETS=""
if [ "$FRESH" = 1 ]; then
  AWAITING=$(grep -i 'AWAITING MERGE' "$STATE/last-message.md" 2>/dev/null)
  for pr in $(printf '%s' "$AWAITING" | grep -oE 'https://github.com/[^ )]+/pull/[0-9]+' | sort -u); do
    # ponytail: ask gh rather than trust the message text — a run can legitimately report a PR
    # it just merged, and that is not something to be woken up for.
    [ "$(gh pr view "$pr" --json state -q .state 2>/dev/null)" = "OPEN" ] && N=$((N + 1))
  done
  # Ticket keys from the same line, so the banner names the work, not just a count.
  TICKETS=$(printf '%s' "$AWAITING" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sort -u | tr '\n' ' ')
fi
[ "$N" -gt 0 ] && osascript -e "display notification \"${TICKETS:-$N PR(s)}awaiting merge — $SLUG\" with title \"Agentic run needs you\" sound name \"Glass\"" 2>/dev/null

# A migration named in the run summary means a manual DB apply is still owed: staging auto-applies
# on deploy, but PRODUCTION apply stays owner-gated. Fire a distinct, louder alert so it isn't lost
# among ordinary "PR awaiting merge" pings.
# ponytail: keys off the migration path appearing in the fresh summary — if a run merely *references*
# a migration without adding one this may over-notify; switch to a structured 'MIGRATION PENDING'
# token emitted by the prompt if it ever gets noisy.
if [ "$FRESH" = 1 ]; then
  MIGRATIONS=$(grep -oE 'supabase/migrations/[0-9A-Za-z_./-]+\.sql' "$STATE/last-message.md" 2>/dev/null | sort -u | tr '\n' ' ')
  [ -n "$MIGRATIONS" ] && osascript -e "display notification \"${MIGRATIONS}— apply to prod at promotion ($SLUG)\" with title \"⚠️ MIGRATION PENDING\" sound name \"Sosumi\"" 2>/dev/null
fi
exit "$RC"
