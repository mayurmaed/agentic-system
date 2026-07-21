#!/bin/bash
# SessionStart hook: inject pending the owner-decisions + last-2-days work log into session context (the daily digest).
today=$(date +%Y-%m-%d)
yday=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d 2>/dev/null)
for f in "$HOME/.claude/decisions"/*.md; do
  [ -e "$f" ] || continue
  proj=$(basename "$f" .md)
  pending=$(awk '/^## Pending Decisions/{flag=1;next}/^## /{flag=0}flag' "$f" | grep -E '^\| [0-9]{4}' || true)
  if [ -n "$pending" ]; then
    echo "PENDING DECISIONS for the owner ($proj) — if the owner is present, surface these FIRST (numbered, with recommendations) before other work:"
    echo "$pending"
  fi
  worklog=$(awk '/^## Work Log/{flag=1;next}/^## /{flag=0}flag' "$f" | grep -E "^\| ($today|$yday)" || true)
  if [ -n "$worklog" ]; then
    echo "RECENT WORK ($proj, last 2 days) — include in the check-in digest:"
    echo "$worklog"
  fi
done
exit 0
