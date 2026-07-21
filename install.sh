#!/bin/bash
# Install/update the agentic system into ~/.claude (idempotent).
set -e
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
START="<!-- agentic-system:start -->"
END="<!-- agentic-system:end -->"

# Confirm before mutating anything (skip with --yes/-y).
YES=0; for a in "$@"; do case "$a" in --yes|-y) YES=1;; esac; done
if [ "$YES" != 1 ]; then
  echo "This will modify:"
  echo "  - $CLAUDE_DIR/agents/, commands/, hooks/, rules/ (files overwritten; existing ones backed up to *.bak.<ts>)"
  echo "  - $CLAUDE_DIR/settings.json                      (hook registrations merged; settings.json.bak written)"
  echo "  - $CLAUDE_DIR/CLAUDE.md                          (agentic block appended/replaced; backed up to *.bak.<ts>)"
  printf 'Continue? [y/N] '; read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
fi
TS="$(date +%Y%m%d%H%M%S)"
backup() { [ -e "$1" ] && cp -p "$1" "$1.bak.$TS" || true; }

# Preflight — fail before mutating anything.
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required (settings merge + push-gate parsing)." >&2; exit 1; }
ls "$REPO_DIR"/claude/agents/*.md >/dev/null 2>&1 || { echo "ERROR: repo incomplete — claude/agents/*.md missing." >&2; exit 1; }
ls "$REPO_DIR"/claude/commands/*.md >/dev/null 2>&1 || { echo "ERROR: repo incomplete — claude/commands/*.md missing." >&2; exit 1; }
ls "$REPO_DIR"/hooks/agentic-*.sh >/dev/null 2>&1 || { echo "ERROR: repo incomplete — hooks/agentic-*.sh missing." >&2; exit 1; }
[ -f "$REPO_DIR/claude/CLAUDE.agentic.md" ] || { echo "ERROR: repo incomplete — claude/CLAUDE.agentic.md missing." >&2; exit 1; }

mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/decisions" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/rules"
for f in "$REPO_DIR"/claude/agents/*.md; do backup "$CLAUDE_DIR/agents/$(basename "$f")"; done
for f in "$REPO_DIR"/claude/commands/*.md; do backup "$CLAUDE_DIR/commands/$(basename "$f")"; done
for f in "$REPO_DIR"/hooks/agentic-*; do backup "$CLAUDE_DIR/hooks/$(basename "$f")"; done
cp "$REPO_DIR"/claude/agents/*.md "$CLAUDE_DIR/agents/"
cp "$REPO_DIR"/claude/commands/*.md "$CLAUDE_DIR/commands/"
cp "$REPO_DIR"/hooks/agentic-* "$CLAUDE_DIR/hooks/"
chmod +x "$CLAUDE_DIR"/hooks/agentic-*.sh
if ls "$REPO_DIR"/claude/rules/*.md >/dev/null 2>&1; then
  for f in "$REPO_DIR"/claude/rules/*.md; do backup "$CLAUDE_DIR/rules/$(basename "$f")"; done
  cp "$REPO_DIR"/claude/rules/*.md "$CLAUDE_DIR/rules/"
fi

# Merge hook registrations into settings.json (idempotent, atomic, backed up).
python3 - "$CLAUDE_DIR" <<'EOF'
import json, os, sys, shlex, shutil, tempfile
cdir = sys.argv[1]
path = os.path.join(cdir, "settings.json")
settings = json.load(open(path)) if os.path.exists(path) else {}
hooks = settings.setdefault("hooks", {})

def ensure(event, matcher, script):
    # exact-command match (accept legacy double-quoted form too), not substring
    known = {'bash ' + shlex.quote(script), f'bash "{script}"'}
    entries = hooks.setdefault(event, [])
    for e in entries:
        for h in e.get("hooks", []):
            if h.get("type") == "command" and h.get("command") in known:
                return
    entry = {"hooks": [{"type": "command", "command": "bash " + shlex.quote(script)}]}
    if matcher:
        entry["matcher"] = matcher
    entries.append(entry)

ensure("SessionStart", None, os.path.join(cdir, "hooks/agentic-pending-decisions.sh"))
ensure("PreToolUse", "Bash", os.path.join(cdir, "hooks/agentic-push-gate.sh"))

if os.path.exists(path):
    shutil.copy2(path, path + ".bak")
fd, tmp = tempfile.mkstemp(dir=cdir, prefix=".settings-", suffix=".json")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
print("Hooks registered in settings.json (backup: settings.json.bak)")
EOF

TARGET="$CLAUDE_DIR/CLAUDE.md"
BLOCK="$REPO_DIR/claude/CLAUDE.agentic.md"
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
echo "Installed agents: $(ls "$REPO_DIR"/claude/agents/*.md | wc -l | tr -d ' '), commands: $(ls "$REPO_DIR"/claude/commands/*.md | wc -l | tr -d ' '), rules: $(ls "$REPO_DIR"/claude/rules/*.md 2>/dev/null | wc -l | tr -d ' ')"
command -v claude >/dev/null 2>&1 || echo "WARN: claude CLI not found — config installed, but nothing will run it. Install Claude Code: https://claude.com/claude-code" >&2
