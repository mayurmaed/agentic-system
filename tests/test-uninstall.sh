#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentic-uninstall.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'test -n "${TEST_ROOT:-}" && rm -rf -- "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
TEST_CLAUDE_DIR="$TEST_ROOT/claude home"
TEST_CODEX_DIR="$TEST_ROOT/codex home"
mkdir -p "$TEST_HOME" "$TEST_CLAUDE_DIR" "$TEST_CODEX_DIR"

cat > "$TEST_CLAUDE_DIR/CLAUDE.md" <<'EOF'
preserved Claude content
EOF
cat > "$TEST_CLAUDE_DIR/settings.json" <<'JSON'
{
  "theme": "preserved-theme",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {"type": "command", "command": "printf preserved-session"}
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {"type": "command", "command": "printf preserved-pretool"}
        ]
      }
    ]
  }
}
JSON

cat > "$TEST_CODEX_DIR/AGENTS.md" <<'EOF'
preserved Codex content
EOF
cat > "$TEST_CODEX_DIR/hooks.json" <<'JSON'
{
  "description": "preserved-hooks-sentinel",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {"type": "command", "command": "printf preserved-codex-hook"}
        ]
      }
    ]
  }
}
JSON
cat > "$TEST_CODEX_DIR/config.toml" <<EOF
model = "preserved-model"

[hooks.state."$TEST_CODEX_DIR/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

[projects."/private/tmp/preserved-project"]
trust_level = "trusted"
EOF

HOME="$TEST_HOME" CLAUDE_DIR="$TEST_CLAUDE_DIR" "$REPO_DIR/install.sh" --yes
HOME="$TEST_HOME" CODEX_DIR="$TEST_CODEX_DIR" "$REPO_DIR/install-codex.sh" --yes

test -f "$TEST_CLAUDE_DIR/agents/pipeline-planner.md"
test -f "$TEST_CODEX_DIR/hooks/agentic-push-gate.py"
grep -qF '<!-- agentic-system:start -->' "$TEST_CLAUDE_DIR/CLAUDE.md"
grep -qF '<!-- agentic-system:start -->' "$TEST_CODEX_DIR/AGENTS.md"
echo "PASS both installers populated the temporary Claude and Codex tracks"

HOME="$TEST_HOME" CLAUDE_DIR="$TEST_CLAUDE_DIR" CODEX_DIR="$TEST_CODEX_DIR" \
  "$REPO_DIR/uninstall.sh" --yes

for path in \
  "$TEST_CLAUDE_DIR/agents/decision-advisor.md" \
  "$TEST_CLAUDE_DIR/agents/pipeline-code-reviewer.md" \
  "$TEST_CLAUDE_DIR/agents/pipeline-developer.md" \
  "$TEST_CLAUDE_DIR/agents/pipeline-functional-reviewer.md" \
  "$TEST_CLAUDE_DIR/agents/pipeline-planner.md" \
  "$TEST_CLAUDE_DIR/agents/pipeline-tester.md" \
  "$TEST_CLAUDE_DIR/commands/autodev.md" \
  "$TEST_CLAUDE_DIR/commands/autodev-cron.md" \
  "$TEST_CLAUDE_DIR/commands/ticket.md" \
  "$TEST_CLAUDE_DIR/commands/task.md" \
  "$TEST_CLAUDE_DIR/hooks/agentic-pending-decisions.sh" \
  "$TEST_CLAUDE_DIR/hooks/agentic-push-gate.sh" \
  "$TEST_CLAUDE_DIR/hooks/agentic-push-gate.py" \
  "$TEST_CLAUDE_DIR/rules/jira.md" \
  "$TEST_CLAUDE_DIR/rules/plandb.md" \
  "$TEST_CODEX_DIR/prompts/autodev.md" \
  "$TEST_CODEX_DIR/prompts/autodev-cron.md" \
  "$TEST_CODEX_DIR/prompts/ticket.md" \
  "$TEST_CODEX_DIR/prompts/task.md" \
  "$TEST_CODEX_DIR/automations/autodev-runner.sh" \
  "$TEST_CODEX_DIR/automations/pending-issue-sync.sh" \
  "$TEST_CODEX_DIR/hooks/agentic-push-gate.sh" \
  "$TEST_CODEX_DIR/hooks/agentic-push-gate.py"
do
  test ! -e "$path"
done
echo "PASS all installer-owned files are absent"

! grep -qF '<!-- agentic-system:start -->' "$TEST_CLAUDE_DIR/CLAUDE.md"
! grep -qF '<!-- agentic-system:end -->' "$TEST_CLAUDE_DIR/CLAUDE.md"
! grep -qF '<!-- agentic-system:start -->' "$TEST_CODEX_DIR/AGENTS.md"
! grep -qF '<!-- agentic-system:end -->' "$TEST_CODEX_DIR/AGENTS.md"
test "$(cat "$TEST_CLAUDE_DIR/CLAUDE.md")" = "preserved Claude content"
test "$(cat "$TEST_CODEX_DIR/AGENTS.md")" = "preserved Codex content"
echo "PASS agentic blocks are gone and surrounding markdown is unchanged"

python3 - "$TEST_CLAUDE_DIR" "$TEST_CODEX_DIR" <<'PY'
import json
import pathlib
import shlex
import sys
import tomllib

claude_dir = pathlib.Path(sys.argv[1])
codex_dir = pathlib.Path(sys.argv[2])

with (claude_dir / "settings.json").open(encoding="utf-8") as source:
    settings = json.load(source)
assert settings["theme"] == "preserved-theme"
assert settings["hooks"] == {
    "SessionStart": [
        {"hooks": [{"type": "command", "command": "printf preserved-session"}]}
    ],
    "PreToolUse": [
        {
            "matcher": "Write",
            "hooks": [{"type": "command", "command": "printf preserved-pretool"}],
        }
    ],
}
owned_claude_commands = {
    "bash " + shlex.quote(str(claude_dir / "hooks" / "agentic-pending-decisions.sh")),
    "bash " + shlex.quote(str(claude_dir / "hooks" / "agentic-push-gate.sh")),
}
assert not any(
    handler.get("command") in owned_claude_commands
    for groups in settings["hooks"].values()
    for group in groups
    for handler in group.get("hooks", [])
)

hooks_path = codex_dir / "hooks.json"
with hooks_path.open(encoding="utf-8") as source:
    hooks_root = json.load(source)
assert hooks_root == {
    "description": "preserved-hooks-sentinel",
    "hooks": {
        "PreToolUse": [
            {
                "matcher": "Read",
                "hooks": [
                    {"type": "command", "command": "printf preserved-codex-hook"}
                ],
            }
        ]
    },
}
assert not any(
    handler.get("statusMessage") == "Checking AGENTIC_GREEN push gate"
    for group in hooks_root["hooks"]["PreToolUse"]
    for handler in group["hooks"]
)

config_path = codex_dir / "config.toml"
config_text = config_path.read_text(encoding="utf-8")
config = tomllib.loads(config_text)
assert config["model"] == "preserved-model"
assert config["projects"]["/private/tmp/preserved-project"]["trust_level"] == "trusted"
expected_state_key = f"{hooks_path}:pre_tool_use:0:0"
assert config["hooks"]["state"] == {
    expected_state_key: {
        "trusted_hash": "sha256:" + "0" * 64,
    }
}
assert "# agentic-push-gate: exact trusted hook definition" not in config_text
print("PASS unrelated Claude setting and hook entries survived unchanged")
print("PASS unrelated Codex hook group and hooks.state table survived unchanged")
print("PASS owned Claude/Codex hook registrations and trust state are absent")
PY

test -d "$TEST_HOME/.claude/decisions"
echo "PASS decisions directory was preserved"

HOME="$TEST_HOME" CLAUDE_DIR="$TEST_CLAUDE_DIR" CODEX_DIR="$TEST_CODEX_DIR" \
  "$REPO_DIR/uninstall.sh" --yes
echo "PASS second uninstall exited 0 (idempotent)"

HOME="$TEST_HOME" CLAUDE_DIR="$TEST_CLAUDE_DIR" "$REPO_DIR/install.sh" --yes >/dev/null
HOME="$TEST_HOME" CODEX_DIR="$TEST_CODEX_DIR" "$REPO_DIR/install-codex.sh" --yes >/dev/null
HOME="$TEST_HOME" CLAUDE_DIR="$TEST_CLAUDE_DIR" CODEX_DIR="$TEST_CODEX_DIR" \
  "$REPO_DIR/uninstall.sh" --claude --yes >/dev/null
test ! -e "$TEST_CLAUDE_DIR/agents/pipeline-planner.md"
test -e "$TEST_CODEX_DIR/prompts/autodev.md"
grep -qF '<!-- agentic-system:start -->' "$TEST_CODEX_DIR/AGENTS.md"
echo "PASS --claude removed only the Claude track"

HOME="$TEST_HOME" CLAUDE_DIR="$TEST_CLAUDE_DIR" CODEX_DIR="$TEST_CODEX_DIR" \
  "$REPO_DIR/uninstall.sh" --codex --yes >/dev/null
test ! -e "$TEST_CODEX_DIR/prompts/autodev.md"
echo "PASS --codex removed only the Codex track"
