#!/bin/bash
# PreToolUse (Bash) hook: block `git push` unless the pipeline green marker matches HEAD.
command -v python3 >/dev/null 2>&1 || { echo "PUSH GATE: python3 missing — failing closed. Install python3 or remove this hook." >&2; exit 2; }
parser="$(cd "$(dirname "$0")" && pwd)/agentic-push-gate.py"
[ -f "$parser" ] || { echo "PUSH GATE: parser $parser missing — failing closed. Re-run install.sh." >&2; exit 2; }
input=$(cat)
out=$(AGENTIC_HOOK_INPUT="$input" python3 "$parser")
case "$out" in
  NOPUSH) exit 0 ;;
  UNRESOLVED:*) echo "PUSH BLOCKED: cannot resolve target repo dir '${out#UNRESOLVED:}' from the command — failing closed. Use a plain 'cd <dir> && git push' form." >&2; exit 2 ;;
  PUSH:*) dir="${out#PUSH:}" ;;
  MALFORMED:*) echo "PUSH BLOCKED: malformed hook input (${out#MALFORMED:}) — failing closed." >&2; exit 2 ;;
  *) echo "PUSH GATE: parser failed — failing closed." >&2; exit 2 ;;
esac
if [ -n "$dir" ]; then
  cd "$dir" 2>/dev/null || { echo "PUSH BLOCKED: cd '$dir' failed — failing closed." >&2; exit 2; }
fi
gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
head=$(git rev-parse HEAD 2>/dev/null) || exit 0
marker="$gitdir/AGENTIC_GREEN"
[ -f "$marker" ] && [ "$(cat "$marker")" = "$head" ] && exit 0
# ponytail: tripwire not vault — pushes buried in scripts (./release.sh) are beyond text parsing; the marker write is the documented override
echo "PUSH BLOCKED: no green pipeline gate for HEAD ($head). Run the tester + functional gates; on PASS write the marker and push:  git rev-parse HEAD > \"$gitdir/AGENTIC_GREEN\". Non-pipeline repos: write the marker after your own verification — deliberate override, log it if it skips a real gate." >&2
exit 2
