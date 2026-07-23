#!/bin/bash
# Install/update the agentic system's Codex track into ~/.codex (idempotent).
set -e
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
START="<!-- agentic-system:start -->"
END="<!-- agentic-system:end -->"
HOOK_STATE_COMMENT="# agentic-push-gate: exact trusted hook definition"

# Confirm before mutating anything (skip with --yes/-y).
YES=0; for a in "$@"; do case "$a" in --yes|-y) YES=1;; esac; done
if [ "$YES" != 1 ]; then
  echo "This will modify:"
  echo "  - $CODEX_DIR/prompts/       (prompt files overwritten; existing ones backed up to *.bak.<ts>)"
  echo "  - $CODEX_DIR/automations/   (runner/sync scripts overwritten; backed up to *.bak.<ts>)"
  echo "  - $CODEX_DIR/AGENTS.md      (agentic block appended/replaced; backed up to *.bak.<ts>)"
  echo "  On Codex >= 0.144, also installs the OPTIONAL native PreToolUse push gate:"
  echo "  - $CODEX_DIR/hooks/         (push-gate scripts installed; backed up to *.bak.<ts>)"
  echo "  - $CODEX_DIR/hooks.json     (one PreToolUse handler merged; backed up to *.bak.<ts>)"
  echo "  - $CODEX_DIR/config.toml    (trust for that exact hook merged; backed up to *.bak.<ts>)"
  echo "WARNING: the native Codex hook is an additive early-warning layer that fails closed."
  echo "The per-repo git pre-push hook remains the universal primary gate."
  printf 'Continue? [y/N] '; read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
fi
TS="$(date +%Y%m%d%H%M%S)"
backup() { [ -e "$1" ] && cp -p "$1" "$1.bak.$TS" || true; }

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required." >&2; exit 1; }
[ -f "$REPO_DIR/codex/AGENTS.agentic.md" ] || { echo "ERROR: repo incomplete — codex/AGENTS.agentic.md missing." >&2; exit 1; }
[ -f "$REPO_DIR/hooks/agentic-push-gate.sh" ] || { echo "ERROR: repo incomplete — hooks/agentic-push-gate.sh missing." >&2; exit 1; }
[ -f "$REPO_DIR/hooks/agentic-push-gate.py" ] || { echo "ERROR: repo incomplete — hooks/agentic-push-gate.py missing." >&2; exit 1; }
ls "$REPO_DIR"/codex/prompts/*.md >/dev/null 2>&1 || { echo "ERROR: repo incomplete — codex/prompts/*.md missing." >&2; exit 1; }

# The native PreToolUse push gate needs Codex >= 0.144. It's optional and additive —
# if Codex is absent or older, skip only the hook; everything else still installs.
INSTALL_HOOK=0
if command -v codex >/dev/null 2>&1; then
  CODEX_VERSION="$(codex --version 2>/dev/null | awk 'NF { print $NF; exit }')"
  if python3 - "$CODEX_VERSION" <<'EOF'
import re, sys
m = re.match(r"^(\d+)\.(\d+)", sys.argv[1])
sys.exit(0 if (m and tuple(map(int, m.groups())) >= (0, 144)) else 1)
EOF
  then
    INSTALL_HOOK=1
  else
    echo "NOTE: Codex CLI < 0.144 (found ${CODEX_VERSION:-unknown}); skipping the optional native PreToolUse push gate." >&2
  fi
else
  echo "NOTE: Codex CLI not found; skipping the optional native PreToolUse push gate (the git pre-push hook remains the primary gate)." >&2
fi

mkdir -p "$CODEX_DIR/prompts" "$CODEX_DIR/automations" "$CODEX_DIR/hooks" "$HOME/.claude/decisions"
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

if [ "$INSTALL_HOOK" = 1 ]; then
  backup "$CODEX_DIR/hooks/agentic-push-gate.sh"
  backup "$CODEX_DIR/hooks/agentic-push-gate.py"
  backup "$CODEX_DIR/hooks.json"
  backup "$CODEX_DIR/config.toml"
  cp "$REPO_DIR/hooks/agentic-push-gate.sh" "$REPO_DIR/hooks/agentic-push-gate.py" "$CODEX_DIR/hooks/"
  chmod +x "$CODEX_DIR/hooks/agentic-push-gate.sh"

  python3 - "$CODEX_DIR/hooks.json" "$CODEX_DIR/config.toml" \
    "$CODEX_DIR/hooks/agentic-push-gate.sh" "$HOOK_STATE_COMMENT" <<'EOF'
import hashlib
import json
import os
import re
import shlex
import sys
import tempfile

hooks_path, config_path, wrapper_path = map(os.path.abspath, sys.argv[1:4])
state_comment = sys.argv[4]
status = "Checking AGENTIC_GREEN push gate"
matcher = "Bash"
handler = {
    "type": "command",
    "command": shlex.quote(wrapper_path),
    "timeout": 5,
    "statusMessage": status,
}
owned_group = {"matcher": matcher, "hooks": [handler]}

if os.path.exists(hooks_path):
    with open(hooks_path, encoding="utf-8") as source:
        root = json.load(source)
else:
    root = {}
if not isinstance(root, dict):
    raise SystemExit(f"ERROR: {hooks_path} must contain a JSON object.")
hooks = root.setdefault("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(f"ERROR: {hooks_path} field 'hooks' must be a JSON object.")
groups = hooks.setdefault("PreToolUse", [])
if not isinstance(groups, list):
    raise SystemExit(f"ERROR: {hooks_path} hooks.PreToolUse must be a JSON array.")

owned = []
for group_index, group in enumerate(groups):
    if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
        raise SystemExit(f"ERROR: invalid PreToolUse group {group_index} in {hooks_path}.")
    for handler_index, existing in enumerate(group["hooks"]):
        if isinstance(existing, dict) and existing.get("statusMessage") == status:
            owned.append((group_index, handler_index))
old_state_keys = {
    f"{hooks_path}:pre_tool_use:{group_index}:{handler_index}"
    for group_index, handler_index in owned
}

if len(owned) == 1 and len(groups[owned[0][0]]["hooks"]) == 1:
    group_index = owned[0][0]
    groups[group_index] = owned_group
else:
    for group in groups:
        group["hooks"] = [
            existing for existing in group["hooks"]
            if not (isinstance(existing, dict) and existing.get("statusMessage") == status)
        ]
    groups.append(owned_group)
    group_index = len(groups) - 1

normalized = dict(handler)
normalized["async"] = False
identity = {"event_name": "pre_tool_use", "matcher": matcher, "hooks": [normalized]}
canonical = json.dumps(identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
trusted_hash = "sha256:" + hashlib.sha256(canonical).hexdigest()
state_key = f"{hooks_path}:pre_tool_use:{group_index}:0"
header = f"[hooks.state.{json.dumps(state_key, ensure_ascii=False)}]"
old_state_keys.add(state_key)
owned_headers = {
    f"[hooks.state.{json.dumps(key, ensure_ascii=False)}]" for key in old_state_keys
}

config = ""
if os.path.exists(config_path):
    with open(config_path, encoding="utf-8") as source:
        config = source.read()

lines = config.splitlines(keepends=True)
kept = []
index = 0
while index < len(lines):
    if (
        lines[index].strip() == state_comment
        and index + 1 < len(lines)
        and lines[index + 1].strip() in owned_headers
    ):
        index += 1
        continue
    if lines[index].strip() not in owned_headers:
        kept.append(lines[index])
        index += 1
        continue
    index += 1
    while index < len(lines) and not re.match(r"^\s*\[", lines[index]):
        index += 1
config = "".join(kept).rstrip()
block = f'{state_comment}\n{header}\ntrusted_hash = "{trusted_hash}"\n'
config = (config + "\n\n" if config else "") + block

def atomic_write(path, text):
    directory = os.path.dirname(path)
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".agentic-install-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as destination:
            destination.write(text)
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

atomic_write(hooks_path, json.dumps(root, indent=2, ensure_ascii=False) + "\n")
atomic_write(config_path, config)
print(f"Registered native Codex PreToolUse hook: {state_key}")
print(f"Trusted exact hook definition: {trusted_hash}")
EOF

  CODEX_HOME="$CODEX_DIR" codex --strict-config app-server </dev/null >/dev/null
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
if [ "$INSTALL_HOOK" = 1 ]; then
  echo "Installed optional native Codex push gate: $CODEX_DIR/hooks/agentic-push-gate.sh"
  echo "WARNING: this is an additive early-warning layer; install the universal git gate per repo:"
  echo "  $REPO_DIR/scripts/install-git-prepush.sh <repo>"
fi
if [ -f "$CODEX_DIR/automations/pending-issue-sync.sh" ]; then
  echo "Installed pending-decision <-> GitHub-Issue syncer: $CODEX_DIR/automations/pending-issue-sync.sh"
  echo "  Configure project list at ~/.claude/decisions/.sync-projects (see .sync-projects.example), then cron it: */15 * * * * $CODEX_DIR/automations/pending-issue-sync.sh >/dev/null 2>&1"
fi
echo "Onboard a project to scheduled autonomous dev: $REPO_DIR/onboard-autodev.sh <repo-dir> [slug] [minute-offset] [--every MINUTES]"
echo "Optional per-repo enforcement: $REPO_DIR/scripts/install-git-prepush.sh <repo>"
command -v codex >/dev/null 2>&1 || echo "WARN: codex CLI not found — install it (npm i -g @openai/codex), or this track will no-op." >&2
