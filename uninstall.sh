#!/bin/bash
# Remove the files and registrations installed by install.sh and install-codex.sh.
set -e

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
START="<!-- agentic-system:start -->"
END="<!-- agentic-system:end -->"
HOOK_STATUS="Checking AGENTIC_GREEN push gate"
HOOK_STATE_COMMENT="# agentic-push-gate: exact trusted hook definition"

YES=0
CLAUDE=0
CODEX=0
SCOPED=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --claude) CLAUDE=1; SCOPED=1 ;;
    --codex) CODEX=1; SCOPED=1 ;;
    *) echo "Usage: $0 [--yes|-y] [--claude] [--codex]" >&2; exit 2 ;;
  esac
done
if [ "$SCOPED" = 0 ]; then
  CLAUDE=1
  CODEX=1
fi

echo "This will remove:"
[ "$CLAUDE" = 1 ] && echo "  - Agentic Claude files and registrations under $CLAUDE_DIR (decisions/ is preserved)"
[ "$CODEX" = 1 ] && echo "  - Agentic Codex files and registrations under $CODEX_DIR"
if [ "$YES" != 1 ]; then
  printf 'Continue? [y/N] '
  read -r REPLY
  case "$REPLY" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
fi

remove_file() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    rm -f -- "$1"
    echo "Removed $1"
  fi
}

remove_marked_block() {
  [ -f "$1" ] || return 0
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required to update $1 safely." >&2
    exit 1
  }
  python3 - "$1" "$START" "$END" <<'PY'
import os
import re
import sys
import tempfile

path, start, end = sys.argv[1:4]
with open(path, encoding="utf-8") as source:
    original = source.read()
if start not in original:
    raise SystemExit
if end not in original:
    raise SystemExit(f"ERROR: {path} has an agentic start marker but no end marker; nothing was changed.")
updated, count = re.subn(
    r"(?:\r?\n)?" + re.escape(start) + r".*?" + re.escape(end) + r"\r?\n?",
    "",
    original,
    flags=re.S,
)
if not count:
    raise SystemExit(f"ERROR: agentic markers in {path} did not form a removable block; nothing was changed.")

mode = os.stat(path).st_mode & 0o777
handle, temporary = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".agentic-uninstall-")
try:
    with os.fdopen(handle, "w", encoding="utf-8") as destination:
        destination.write(updated)
        destination.flush()
        os.fsync(destination.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print(f"Removed agentic block from {path}")
PY
}

prune_claude_settings() {
  local path="$CLAUDE_DIR/settings.json"
  [ -f "$path" ] || return 0
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required to update $path safely." >&2
    exit 1
  }
  python3 - "$path" \
    "$CLAUDE_DIR/hooks/agentic-pending-decisions.sh" \
    "$CLAUDE_DIR/hooks/agentic-push-gate.sh" <<'PY'
import json
import os
import shlex
import sys
import tempfile

path, pending, gate = sys.argv[1:4]
with open(path, encoding="utf-8") as source:
    root = json.load(source)
if not isinstance(root, dict):
    raise SystemExit(f"ERROR: {path} must contain a JSON object.")

owned = {
    "SessionStart": {"bash " + shlex.quote(pending), f'bash "{pending}"'},
    "PreToolUse": {"bash " + shlex.quote(gate), f'bash "{gate}"'},
}
changed = False
hooks = root.get("hooks")
if hooks is not None and not isinstance(hooks, dict):
    raise SystemExit(f"ERROR: {path} field 'hooks' must be a JSON object.")
if isinstance(hooks, dict):
    for event, commands in owned.items():
        groups = hooks.get(event)
        if groups is None:
            continue
        if not isinstance(groups, list):
            raise SystemExit(f"ERROR: {path} hooks.{event} must be a JSON array.")
        kept_groups = []
        for index, group in enumerate(groups):
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise SystemExit(f"ERROR: invalid {event} group {index} in {path}.")
            before = group["hooks"]
            after = [
                handler for handler in before
                if not (
                    isinstance(handler, dict)
                    and handler.get("type") == "command"
                    and handler.get("command") in commands
                )
            ]
            if len(after) != len(before):
                changed = True
            if after:
                if len(after) != len(before):
                    group = dict(group)
                    group["hooks"] = after
                kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            hooks.pop(event, None)

if changed:
    mode = os.stat(path).st_mode & 0o777
    handle, temporary = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".agentic-uninstall-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as destination:
            json.dump(root, destination, indent=2, ensure_ascii=False)
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Removed agentic hook registrations from {path}")
PY
}

prune_codex_registration() {
  local hooks_path="$CODEX_DIR/hooks.json"
  local config_path="$CODEX_DIR/config.toml"
  [ -f "$hooks_path" ] || [ -f "$config_path" ] || return 0
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required to update Codex hook registration safely." >&2
    exit 1
  }
  python3 - "$hooks_path" "$config_path" "$HOOK_STATUS" "$HOOK_STATE_COMMENT" <<'PY'
import json
import os
import re
import sys
import tempfile

hooks_path, config_path = map(os.path.abspath, sys.argv[1:3])
status, state_comment = sys.argv[3:5]
owned_headers = set()

def atomic_write(path, text):
    mode = os.stat(path).st_mode & 0o777
    handle, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".agentic-uninstall-")
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

if os.path.exists(hooks_path):
    with open(hooks_path, encoding="utf-8") as source:
        root = json.load(source)
    if not isinstance(root, dict):
        raise SystemExit(f"ERROR: {hooks_path} must contain a JSON object.")
    hooks = root.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        raise SystemExit(f"ERROR: {hooks_path} field 'hooks' must be a JSON object.")
    changed = False
    if isinstance(hooks, dict) and "PreToolUse" in hooks:
        groups = hooks["PreToolUse"]
        if not isinstance(groups, list):
            raise SystemExit(f"ERROR: {hooks_path} hooks.PreToolUse must be a JSON array.")
        kept_groups = []
        for group_index, group in enumerate(groups):
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise SystemExit(f"ERROR: invalid PreToolUse group {group_index} in {hooks_path}.")
            kept_handlers = []
            for handler_index, handler in enumerate(group["hooks"]):
                if isinstance(handler, dict) and handler.get("statusMessage") == status:
                    key = f"{hooks_path}:pre_tool_use:{group_index}:{handler_index}"
                    owned_headers.add(f"[hooks.state.{json.dumps(key, ensure_ascii=False)}]")
                    changed = True
                else:
                    kept_handlers.append(handler)
            if kept_handlers:
                if len(kept_handlers) != len(group["hooks"]):
                    group = dict(group)
                    group["hooks"] = kept_handlers
                kept_groups.append(group)
        if kept_groups:
            hooks["PreToolUse"] = kept_groups
        else:
            hooks.pop("PreToolUse", None)
    if changed:
        atomic_write(hooks_path, json.dumps(root, indent=2, ensure_ascii=False) + "\n")
        print(f"Removed agentic PreToolUse handler from {hooks_path}")

if os.path.exists(config_path):
    with open(config_path, encoding="utf-8") as source:
        config = source.read()
    lines = config.splitlines(keepends=True)
    header_pattern = re.compile(r'^\[hooks\.state\.("(?:[^"\\]|\\.)*")\]$')
    key_pattern = re.compile(re.escape(hooks_path) + r":pre_tool_use:\d+:0$")
    for index, line in enumerate(lines[:-1]):
        if line.strip() != state_comment:
            continue
        match = header_pattern.match(lines[index + 1].strip())
        if match and key_pattern.match(json.loads(match.group(1))):
            owned_headers.add(lines[index + 1].strip())

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
    updated = "".join(kept)
    if updated != config:
        atomic_write(config_path, updated)
        print(f"Removed agentic trust state from {config_path}")
PY
}

if [ "$CLAUDE" = 1 ]; then
  for path in \
    "$CLAUDE_DIR/agents/decision-advisor.md" \
    "$CLAUDE_DIR/agents/pipeline-code-reviewer.md" \
    "$CLAUDE_DIR/agents/pipeline-developer.md" \
    "$CLAUDE_DIR/agents/pipeline-functional-reviewer.md" \
    "$CLAUDE_DIR/agents/pipeline-planner.md" \
    "$CLAUDE_DIR/agents/pipeline-tester.md" \
    "$CLAUDE_DIR/commands/autodev.md" \
    "$CLAUDE_DIR/commands/autodev-cron.md" \
    "$CLAUDE_DIR/commands/ticket.md" \
    "$CLAUDE_DIR/commands/task.md" \
    "$CLAUDE_DIR/hooks/agentic-pending-decisions.sh" \
    "$CLAUDE_DIR/hooks/agentic-push-gate.sh" \
    "$CLAUDE_DIR/hooks/agentic-push-gate.py" \
    "$CLAUDE_DIR/rules/jira.md" \
    "$CLAUDE_DIR/rules/plandb.md"
  do
    remove_file "$path"
  done
  remove_marked_block "$CLAUDE_DIR/CLAUDE.md"
  prune_claude_settings
fi

if [ "$CODEX" = 1 ]; then
  for path in \
    "$CODEX_DIR/prompts/autodev.md" \
    "$CODEX_DIR/prompts/autodev-cron.md" \
    "$CODEX_DIR/prompts/ticket.md" \
    "$CODEX_DIR/prompts/task.md" \
    "$CODEX_DIR/automations/autodev-runner.sh" \
    "$CODEX_DIR/automations/install-git-prepush.sh" \
    "$CODEX_DIR/automations/pending-issue-sync.sh" \
    "$CODEX_DIR/hooks/agentic-push-gate.sh" \
    "$CODEX_DIR/hooks/agentic-push-gate.py"
  do
    remove_file "$path"
  done
  remove_marked_block "$CODEX_DIR/AGENTS.md"
  prune_codex_registration
fi

echo "Reminder: per-repo git hooks are unchanged; run 'git config --unset core.hooksPath' if configured, or remove .git/hooks/pre-push manually."
echo "Reminder: crontab entries are unchanged; remove onboard-autodev entries manually."
echo "Uninstall complete."
