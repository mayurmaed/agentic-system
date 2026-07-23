#!/bin/bash
# Pending-decision <-> pinned-GitHub-Issue syncer. ONE standalone job for ALL projects,
# decoupled from every dev runner (they already read ~/.claude/decisions/<slug>.md).
#
# Each run, per project:
#   1. Mirror the "## Pending Decisions" table -> a pinned "📋 Pending Decisions" issue.
#   2. Harvest owner answer-comments (lines starting `P-<n>:`) -> an "## Answers Inbox"
#      section in the decisions file, which the next agent run applies (per AGENTS.md
#      Off-Hands protocol). Each comment is harvested once (tracked in <slug>.seen).
#
# Answers flow: owner comments `P-4: approve` on the issue -> harvested here -> next run
# reads the Answers Inbox and acts. Branch-independent, no repo-tree file, no MCP.
#
# Project list lives OUTSIDE this script, in ~/.claude/decisions/.sync-projects
# (one "slug:owner/repo" per line, "#" comments and blank lines ignored) — install.sh
# never overwrites that file if it already exists, so it's yours to edit per machine.
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
[ -f "$HOME/.codex/secrets/github.env" ] && set -a && . "$HOME/.codex/secrets/github.env" && set +a

DEC="$HOME/.claude/decisions"
STATE="$HOME/.codex/automations/pending-sync"; mkdir -p "$STATE"
LOG="$STATE/RUN_LOG.md"
OWNER="$(gh api user --jq .login 2>/dev/null || echo unknown)"
NOW="$(date '+%F %T')"

PROJECTS_FILE="$DEC/.sync-projects"
if [ ! -f "$PROJECTS_FILE" ]; then
  echo "$NOW  no $PROJECTS_FILE — nothing to sync (see .sync-projects.example)" >> "$LOG"
  exit 0
fi
# slug:repo pairs, "#" comments and blank lines skipped.
PROJECTS=()
while IFS= read -r line; do
  PROJECTS+=("$line")
done < <(grep -vE '^\s*(#|$)' "$PROJECTS_FILE")

# Extract the Pending Decisions table rows (only real rows: those starting with a date).
pending_rows() { awk '
  /^## Pending Decisions/{f=1;next}
  /^## /{f=0}
  f && /^\| *[0-9]{4}-[0-9]{2}-[0-9]{2}/{print}
' "$1"; }

# Full table (header+separator+rows) for rendering, or empty if no real rows.
pending_table() { awk '
  /^## Pending Decisions/{f=1;next}
  /^## /{f=0}
  f && /^\|/{print}
' "$1"; }

issue_body() {
  local df="$1" rows
  rows="$(pending_rows "$df")"
  {
    echo "> **Auto-synced** from \`~/.claude/decisions/$(basename "$df")\` — the table below is overwritten each sync, don't hand-edit it."
    echo ">"
    echo "> **To decide:** add a comment with the P-id and your choice — e.g. \`P-4: approve\` or \`P-4: option a — <note>\`. The syncer harvests it and the next agent run applies it. You can also just answer in a Claude chat."
    echo ""
    echo "## Decisions awaiting you"
    echo ""
    if [ -n "$rows" ]; then pending_table "$df"; else echo "✅ Nothing pending right now."; fi
    echo ""
    echo "_Last synced: ${NOW}_"
  }
}

for entry in "${PROJECTS[@]}"; do
  slug="${entry%%:*}"; repo="${entry#*:}"; df="$DEC/$slug.md"
  [ -f "$df" ] || { echo "$NOW  $slug: no decisions file, skipped" >> "$LOG"; continue; }
  title="📋 Pending Decisions — $slug"
  body="$(issue_body "$df")"

  # Find existing open issue by exact title.
  num="$(gh issue list --repo "$repo" --state open --search "in:title 📋 Pending Decisions" \
          --json number,title --jq ".[] | select(.title==\"$title\") | .number" 2>/dev/null | head -1)"

  if [ -z "$num" ]; then
    num="$(gh issue create --repo "$repo" --title "$title" --body "$body" \
            --label "owner-decision" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
    if [ -z "$num" ]; then
      # label may not exist; retry without it
      num="$(gh issue create --repo "$repo" --title "$title" --body "$body" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
    fi
    [ -n "$num" ] || { echo "$NOW  $slug: issue create FAILED" >> "$LOG"; continue; }
    # Pin it (GraphQL; gh has no native pin). Best-effort.
    nid="$(gh issue view "$num" --repo "$repo" --json id --jq .id 2>/dev/null)"
    [ -n "$nid" ] && gh api graphql -f query="mutation{pinIssue(input:{issueId:\"$nid\"}){issue{number}}}" >/dev/null 2>&1
    echo "$NOW  $slug: created + pinned issue #$num" >> "$LOG"
  else
    gh issue edit "$num" --repo "$repo" --body "$body" >/dev/null 2>&1 \
      && echo "$NOW  $slug: refreshed issue #$num" >> "$LOG" \
      || echo "$NOW  $slug: refresh FAILED #$num" >> "$LOG"
  fi

  # --- Harvest owner answers from comments (once each) ---
  seen="$STATE/$slug.seen"; touch "$seen"
  # comments: id (node), author, body — only the owner's count.
  gh issue view "$num" --repo "$repo" --json comments \
    --jq ".comments[] | select(.author.login==\"$OWNER\") | [.id, (.body|gsub(\"\r\";\"\"))] | @tsv" 2>/dev/null \
  | while IFS=$'\t' read -r cid cbody; do
      [ -n "$cid" ] || continue
      grep -qxF "$cid" "$seen" && continue          # already harvested
      # pull answer lines: start with P-<digits>:
      ans="$(printf '%s\n' "$cbody" | grep -oiE 'P-[0-9]+ *:[^|]*' | sed 's/  */ /g')"
      if [ -n "$ans" ]; then
        # ensure Answers Inbox section exists
        grep -q '^## Answers Inbox' "$df" || printf '\n## Answers Inbox\n\n_Owner answers harvested from the pinned issue; agent runs apply each, then delete the line and move the P-item to Decided._\n' >> "$df"
        printf '%s\n' "$ans" | while IFS= read -r a; do
          [ -n "$a" ] && echo "- [$NOW] $a  (pinned issue #$num)" >> "$df"
        done
        echo "$NOW  $slug: harvested answer from #$num comment $cid" >> "$LOG"
      fi
      echo "$cid" >> "$seen"
    done
done
exit 0
