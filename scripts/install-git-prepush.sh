#!/bin/bash
# Install the tool-agnostic AGENTIC_GREEN pre-push hook into a repo (works for Codex, Claude, and manual pushes).
# Usage: ./install-git-prepush.sh [repo-dir]   (default: current directory)
set -e
# Strip --yes/-y before positional parsing.
YES=0; ARGS=(); for a in "$@"; do case "$a" in --yes|-y) YES=1;; *) ARGS+=("$a");; esac; done
set -- ${ARGS[@]+"${ARGS[@]}"}
REPO="${1:-.}"
GITDIR="$(git -C "$REPO" rev-parse --git-dir)"
HOOK="$GITDIR/hooks/pre-push"
if [ -e "$HOOK" ] && ! grep -q AGENTIC_GREEN "$HOOK" 2>/dev/null; then
  echo "ERROR: $HOOK already exists (not ours) — merge manually." >&2
  exit 1
fi
# Confirm before mutating (skip with --yes/-y).
if [ "$YES" != 1 ]; then
  echo "This will write the AGENTIC_GREEN pre-push hook to: $HOOK"
  [ ! -e "$HOOK" ] || echo "  (existing hook will be backed up to $HOOK.bak.<ts> first)"
  printf 'Continue? [y/N] '; read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
fi
[ ! -e "$HOOK" ] || cp -p "$HOOK" "$HOOK.bak.$(date +%Y%m%d%H%M%S)"
cat > "$HOOK" <<'EOF'
#!/bin/bash
# Agentic pre-push gate: HEAD must have a green pipeline marker.
gitdir=$(git rev-parse --git-dir)
head=$(git rev-parse HEAD)
marker="$gitdir/AGENTIC_GREEN"
[ -f "$marker" ] && [ "$(cat "$marker")" = "$head" ] && exit 0
echo "PUSH BLOCKED: no green pipeline gate for HEAD ($head)." >&2
echo "Run the tester + functional gates; on PASS:  git rev-parse HEAD > \"$gitdir/AGENTIC_GREEN\"  then push." >&2
echo "(Deliberate override for non-pipeline pushes: write the marker after your own verification.)" >&2
exit 1
EOF
chmod +x "$HOOK"
echo "Installed pre-push gate in $HOOK"
