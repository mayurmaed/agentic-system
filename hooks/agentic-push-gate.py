"""Parser for agentic-push-gate.sh: reads hook JSON from $AGENTIC_HOOK_INPUT.

Prints one of: NOPUSH | PUSH:<dir-or-empty> | UNRESOLVED:<dir> | MALFORMED:<reason>
"""
import json
import os
import re
import sys

# Fail CLOSED on malformed/missing input: emit MALFORMED so the shell wrapper blocks the push.
try:
    raw = os.environ.get("AGENTIC_HOOK_INPUT")
    if raw is None or not raw.strip():
        raise ValueError("hook input missing/empty")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("hook input is not a JSON object")
    cmd = data.get("tool_input", {}).get("command", "")
    if not isinstance(cmd, str):
        raise ValueError("tool_input.command is not a string")
except Exception as e:
    print("MALFORMED:%s" % e)
    sys.exit(0)

# git ... push at a command position (line start or after ; & |), not inside a quoted string
m = re.search(r'(?:^|[;&|\n]\s*)(git\b[^;&|\n]*?\bpush\b[^;&|\n]*)', cmd)
if not m:
    print("NOPUSH")
    sys.exit(0)

seg = m.group(1)
QUOTED_OR_BARE = r'("([^"]+)"|\'([^\']+)\'|(\S+))'
d = ""
mc = re.search(r'-C\s+' + QUOTED_OR_BARE, seg)
if mc:
    d = mc.group(2) or mc.group(3) or mc.group(4)
else:
    # last `cd <path>` at a command position before the push segment
    for mcd in re.finditer(r'(?:^|[;&|\n]\s*)cd\s+("([^"]+)"|\'([^\']+)\'|([^\s;&|]+))',
                           cmd[:m.start(1)]):
        d = mcd.group(2) or mcd.group(3) or mcd.group(4)

if d:
    d = os.path.expanduser(os.path.expandvars(d))
    if not os.path.isdir(d):
        print("UNRESOLVED:" + d)
        sys.exit(0)
print("PUSH:" + d)
