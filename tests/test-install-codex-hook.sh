#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentic-codex-install.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'test -n "${TEST_ROOT:-}" && rm -rf -- "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/home"
TEST_CODEX_DIR="$TEST_ROOT/codex home"
mkdir -p "$TEST_HOME" "$TEST_CODEX_DIR"

cat > "$TEST_CODEX_DIR/hooks.json" <<'JSON'
{
  "description": "hooks sentinel",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "printf preserved"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "printf stale-one",
            "statusMessage": "Checking AGENTIC_GREEN push gate"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "printf stale-two",
            "statusMessage": "Checking AGENTIC_GREEN push gate"
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "printf index-preserved"
          }
        ]
      }
    ]
  }
}
JSON

cat > "$TEST_CODEX_DIR/config.toml" <<TOML
model = "preserved-model"

[hooks.state."/private/tmp/unrelated/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

[hooks.state."$TEST_CODEX_DIR/hooks.json:pre_tool_use:3:0"]
trusted_hash = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
TOML

HOME="$TEST_HOME" CODEX_DIR="$TEST_CODEX_DIR" "$REPO_DIR/install-codex.sh" --yes
cat >> "$TEST_CODEX_DIR/config.toml" <<'TOML'

[projects."/private/tmp/preserved-project"]
trust_level = "trusted"
TOML
HOME="$TEST_HOME" CODEX_DIR="$TEST_CODEX_DIR" "$REPO_DIR/install-codex.sh" --yes

python3 - "$TEST_CODEX_DIR" <<'PY'
import hashlib
import json
import pathlib
import sys
import tomllib

codex_dir = pathlib.Path(sys.argv[1])
hooks_path = codex_dir / "hooks.json"
config_path = codex_dir / "config.toml"
wrapper_path = codex_dir / "hooks" / "agentic-push-gate.sh"
expected_command = "'" + str(wrapper_path) + "'"

with hooks_path.open(encoding="utf-8") as source:
    root = json.load(source)
assert root["description"] == "hooks sentinel"
groups = root["hooks"]["PreToolUse"]
assert groups[0] == {
    "matcher": "Read",
    "hooks": [{"type": "command", "command": "printf preserved"}],
}
assert groups[3] == {
    "matcher": "Write",
    "hooks": [{"type": "command", "command": "printf index-preserved"}],
}

managed = []
for group_index, group in enumerate(groups):
    for handler_index, handler in enumerate(group.get("hooks", [])):
        if handler.get("statusMessage") == "Checking AGENTIC_GREEN push gate":
            managed.append((group_index, handler_index, group, handler))
assert len(managed) == 1, managed
group_index, handler_index, group, handler = managed[0]
assert group["matcher"] == "Bash"
assert len(group["hooks"]) == 1
assert handler == {
    "type": "command",
    "command": expected_command,
    "timeout": 5,
    "statusMessage": "Checking AGENTIC_GREEN push gate",
}

identity = {
    "event_name": "pre_tool_use",
    "matcher": "Bash",
    "hooks": [{**handler, "async": False}],
}
canonical = json.dumps(
    identity, sort_keys=True, separators=(",", ":"), ensure_ascii=False
).encode()
expected_hash = "sha256:" + hashlib.sha256(canonical).hexdigest()
expected_key = f"{hooks_path}:pre_tool_use:{group_index}:{handler_index}"

config_text = config_path.read_text(encoding="utf-8")
config = tomllib.loads(config_text)
assert config["model"] == "preserved-model"
assert config["projects"]["/private/tmp/preserved-project"]["trust_level"] == "trusted"
state = config["hooks"]["state"]
assert state["/private/tmp/unrelated/hooks.json:pre_tool_use:0:0"]["trusted_hash"] == (
    "sha256:" + "0" * 64
)
assert state[f"{hooks_path}:pre_tool_use:3:0"]["trusted_hash"] == "sha256:" + "1" * 64
managed_keys = [
    key for key in state
    if key.startswith(f"{hooks_path}:pre_tool_use:")
]
assert set(managed_keys) == {
    f"{hooks_path}:pre_tool_use:3:0",
    expected_key,
}, managed_keys
assert state[expected_key]["trusted_hash"] == expected_hash
assert config_text.count("# agentic-push-gate: exact trusted hook definition") == 1

assert wrapper_path.is_file()
assert wrapper_path.stat().st_mode & 0o111
assert (codex_dir / "hooks" / "agentic-push-gate.py").is_file()
print(f"PASS managed handler: {expected_key}")
print(f"PASS trusted hash: {expected_hash}")
print("PASS preserved unrelated hooks.json and config.toml content")
print("PASS preserved unrelated hook index and trust state")
print("PASS preserved following Codex project trust table")
print("PASS installed wrapper and parser")
PY

if command -v codex >/dev/null 2>&1; then
  CODEX_HOME="$TEST_CODEX_DIR" codex --strict-config app-server </dev/null
  echo "PASS Codex strict config parse"
else
  echo "SKIP Codex strict config parse (codex not installed)"
fi
