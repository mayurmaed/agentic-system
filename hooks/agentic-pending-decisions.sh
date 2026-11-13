#!/bin/bash
# SessionStart hook: inject pending owner-decisions + last-2-days work log into session context (the daily digest).
#
# This is a DIGEST, not a dump. Echoing every pending row from every project verbatim breaks once
# the queues grow: a large hook output gets truncated to a short preview by the harness, so only
# whichever project sorts first reaches the context window and the rest are silently lost. The caps
# below keep it inside that budget. Anything dropped is reported as a count, never silently.
today=$(date +%Y-%m-%d)
yday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d 2>/dev/null)

MAX_ROWS=5      # newest rows shown per project and section
MAX_CHARS=400   # per-row truncation: enough for the decision + recommendation gist

digest() {  # $1=rows  $2=label  (newest first, capped, truncated, with an omitted count)
  local rows="$1" total shown
  total=$(printf '%s\n' "$rows" | grep -c '^|')
  shown=$(printf '%s\n' "$rows" | sort -r | head -n "$MAX_ROWS" \
    | cut -c1-"$MAX_CHARS" | sed 's/$/ …/')
  printf '%s\n' "$shown"
  [ "$total" -gt "$MAX_ROWS" ] && echo "  (+$((total - MAX_ROWS)) older $2 rows not shown — full queue in the file above)"
}

for f in "$HOME/.claude/decisions"/*.md; do
  [ -e "$f" ] || continue
  proj=$(basename "$f" .md)
  # Resolved entries are struck through (~~P-x~~ (resolved by D-y)) but stay in the file as the
  # audit trail. They are not pending, so filter them here rather than pruning the log.
  pending=$(awk '/^## Pending Decisions/{flag=1;next}/^## /{flag=0}flag' "$f" | grep -E '^\| [0-9]{4}' | grep -v '~~' || true)
  if [ -n "$pending" ]; then
    echo "PENDING DECISIONS for the owner ($proj) — if the owner is present, surface these FIRST (numbered, with recommendations) before other work. Source: $f"
    digest "$pending" "pending"
  fi
  worklog=$(awk '/^## Work Log/{flag=1;next}/^## /{flag=0}flag' "$f" | grep -E "^\| ($today|$yday)" || true)
  if [ -n "$worklog" ]; then
    echo "RECENT WORK ($proj, last 2 days) — include in the check-in digest:"
    digest "$worklog" "work-log"
  fi
done
exit 0
