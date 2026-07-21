#!/bin/bash
# Onboard a project to autonomous development the canonical way — ONE crontab line to the
# shared runner. No per-project wrapper, clone, or token. Idempotent.
# Usage: ./onboard-autodev.sh <repo-dir> [project-slug] [minute-offset] [--every MINUTES] [--hook]
set -e
# Strip --yes/-y and --every <n> before positional parsing.
YES=0; EVERY=""; WANT_EVERY=0; ARGS=()
for a in "$@"; do
  if [ "$WANT_EVERY" = 1 ]; then EVERY="$a"; WANT_EVERY=0; continue; fi
  case "$a" in --yes|-y) YES=1;; --every) WANT_EVERY=1;; *) ARGS+=("$a");; esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
REPO="${1:?usage: onboard-autodev.sh <repo-dir> [slug] [minute-offset] [--every MINUTES] [--hook] [--yes]}"
REPO="$(cd "$REPO" && pwd)"
[ -d "$REPO/.git" ] || { echo "ERROR: '$REPO' is not a git repo." >&2; exit 1; }
SLUG="${2:-$(basename "$REPO" | tr '[:upper:] ' '[:lower:]-')}"

# Interval must divide 60 or be a whole number of hours — anything else yields an irregular schedule.
valid_interval() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -gt 0 ] || return 1
  [ $((60 % $1)) -eq 0 ] || [ $(($1 % 60)) -eq 0 ]
}
bad_interval() {
  echo "ERROR: --every must divide 60 or be a multiple of 60 (e.g. 5, 10, 15, 20, 30, 60, 120, 240, 720, 1440); got '$1'." >&2
  exit 1
}
if [ -z "$EVERY" ]; then
  if [ "$YES" != 1 ] && [ -t 0 ]; then
    printf "How often should autodev run for '%s'? [minutes, default 30]: " "$SLUG"
    read -r EVERY
  fi
  EVERY="${EVERY:-30}"
fi
valid_interval "$EVERY" || bad_interval "$EVERY"

# Offset lives inside one interval (capped at an hour, since cron minutes wrap hourly).
SPAN=$(( EVERY < 60 ? EVERY : 60 ))
DEFOFF=12; [ "$SPAN" -gt 12 ] || DEFOFF=0
MIN="${3:-$DEFOFF}"
OFFERR="ERROR: minute offset must be 0-$((SPAN - 1)) for a $EVERY-minute interval."
case "$MIN" in ''|*[!0-9]*) echo "$OFFERR" >&2; exit 1;; esac
[ "$MIN" -ge 0 ] && [ "$MIN" -le $((SPAN - 1)) ] || { echo "$OFFERR" >&2; exit 1; }
WANT_HOOK=0; BASE=""; while [ $# -gt 0 ]; do
  case "$1" in --hook) WANT_HOOK=1;; --base) shift; BASE="$1";; esac; shift; done
RUNNER="$HOME/.codex/automations/autodev-runner.sh"

# Confirm before mutating anything (skip with --yes/-y).
if [ "$YES" != 1 ]; then
  echo "This will modify:"
  echo "  - your crontab: add/replace the line marked '# autodev:$SLUG' (current crontab backed up first)"
  echo "  - $HOME/.codex/automations/autodev-$SLUG/ (state files: origin-url, base-branch)"
  echo "  - $HOME/.claude/decisions/$SLUG.md (created only if missing)"
  [ "$WANT_HOOK" != 1 ] || echo "  - $REPO/.git/hooks/pre-push (installed; existing hook backed up)"
  printf 'Continue? [y/N] '; read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
fi

# 1. Preconditions
command -v codex >/dev/null 2>&1 || echo "WARN: codex CLI not found — install it, or this cron will no-op." >&2
[ -x "$RUNNER" ] || { echo "ERROR: $RUNNER missing — run ./install-codex.sh first." >&2; exit 1; }
if [ ! -f "$HOME/.codex/secrets/github.env" ]; then
  echo "ERROR: ~/.codex/secrets/github.env missing (GH_TOKEN=...). Cron can't read the keychain;" >&2
  echo "       create it with a token that can push to this repo, then re-run." >&2
  exit 1
fi
URL="$(git -C "$REPO" remote get-url origin 2>/dev/null)"
[ -n "$URL" ] || { echo "ERROR: $REPO has no origin remote." >&2; exit 1; }
( set -a; . "$HOME/.codex/secrets/github.env"; set +a
  GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" git ls-remote "$URL" HEAD >/dev/null 2>&1 ) \
  || { echo "ERROR: shared token cannot reach $REPO's remote — fix auth before scheduling." >&2; exit 1; }

# Record the URL so the cron runner never needs to touch the dev checkout (it may be in a
# TCC-protected folder like ~/Desktop that cron can't read). The runner clones from this.
STATE="$HOME/.codex/automations/autodev-$SLUG"; mkdir -p "$STATE"
printf '%s\n' "$URL" > "$STATE/origin-url"

# Policy: every repo targets a `staging` integration branch; PRs NEVER target main.
# Explicit --base wins; otherwise default to staging and CREATE it from the repo's default
# branch if it doesn't exist yet. Never fall back to main.
[ -n "$BASE" ] || BASE=staging
if ! ( set -a; . "$HOME/.codex/secrets/github.env"; set +a; GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" git ls-remote --exit-code "$URL" "refs/heads/$BASE" >/dev/null 2>&1 ); then
  OR="$(printf '%s' "$URL" | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')"
  if [ "$BASE" = staging ] && command -v gh >/dev/null 2>&1 && [ -n "$OR" ]; then
    DEF="$(gh api "repos/$OR" --jq .default_branch 2>/dev/null)"
    DSHA="$(gh api "repos/$OR/git/ref/heads/$DEF" --jq .object.sha 2>/dev/null)"
    [ -n "$DSHA" ] && gh api "repos/$OR/git/refs" -f ref=refs/heads/staging -f sha="$DSHA" >/dev/null 2>&1 \
      && echo "Created 'staging' on $OR from '$DEF' (PRs target staging; main stays manual)." \
      || { echo "ERROR: base 'staging' missing and could not create it on $OR — create it manually, then re-run." >&2; exit 1; }
  else
    echo "ERROR: base branch '$BASE' does not exist on origin — create it, then re-run." >&2; exit 1
  fi
fi
printf '%s\n' "$BASE" > "$STATE/base-branch"
echo "PR base branch: $BASE (PRs target it; promotion to main is owner-only)"

# 2. Decision/work-log file skeleton
DEC="$HOME/.claude/decisions/$SLUG.md"
if [ ! -f "$DEC" ]; then
  mkdir -p "$HOME/.claude/decisions"
  cat > "$DEC" <<EOF
# ${SLUG} Decision Log

## Pending Decisions

| Date | ID | Decision needed | Options | Recommendation | Blocks |
|---|---|---|---|---|---|

## Work Log

| Date | What shipped / halted / parked | PR or trail | Track/model |
|---|---|---|---|

## Decided

Append-only. Format: \`| date | id | decision | decided by | why | link |\`

| Date | ID | Decision | Decided by | Why | Link |
|---|---|---|---|---|---|
EOF
  echo "Created decision/work-log file: $DEC"
fi

# 3. Optional per-repo push gate
if [ "$WANT_HOOK" = 1 ]; then
  "$(dirname "$0")/scripts/install-git-prepush.sh" --yes "$REPO" || true
fi

# 4. Crontab line (idempotent via # autodev:<slug> marker)
# Explicit minute list, never */N — */N ignores the offset, so every project would collide.
cron_min_field() { # <interval> <offset> -> cron minute field
  local i="$1" o="$2" m out=""
  if [ "$i" -ge 60 ]; then echo "$o"; return; fi
  for (( m=o; m<60; m+=i )); do out="${out:+$out,}$m"; done
  echo "$out"
}
MINF="$(cron_min_field "$EVERY" "$MIN")"
if [ "$EVERY" -lt 60 ]; then
  SCHED="$MINF * * * *"; DESC="every $EVERY min at :${MINF//,/,:}"
elif [ "$EVERY" -eq 60 ]; then
  SCHED="$MINF * * * *"; DESC="hourly at :$MIN"
else
  SCHED="$MINF */$((EVERY/60)) * * *"; DESC="every $((EVERY/60))h at :$MIN"
fi
LINE="$SCHED $RUNNER \"$REPO\" $SLUG  # autodev:$SLUG"
TMP="$(mktemp)"
crontab -l > "$STATE/crontab.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
crontab -l 2>/dev/null | grep -v "# autodev:$SLUG\$" > "$TMP" || true
echo "$LINE" >> "$TMP"
crontab "$TMP"; rm -f "$TMP"

echo "Onboarded '$SLUG' → runs $DESC via the shared runner."
echo "  repo:     $REPO"
echo "  runner:   $RUNNER"
echo "  decisions:$DEC"
echo "Remove later with:  crontab -l | grep -v '# autodev:$SLUG' | crontab -"
