---
description: Run any ask through the full agentic pipeline (explicit trigger; implementation asks do this by default)
argument-hint: <what you want done>
---

Run this ask through the FULL agentic pipeline — no skip logic, even if it looks trivial: planner → developer → tester → code reviewer → functional reviewer → push on green. Off-Hands rules apply.

The ask: $ARGUMENTS

Notes:
- Treat the ask text as the original requirement the functional reviewer judges against.
- A PR needs a tracker reference. With Jira connected: search for an existing ticket that covers this ask; if none fits, park a P-entry proposing one (with epic) and hold the push until resolved — all other stages proceed. Without Jira: record the item in the project's tracker (plandb task or BACKLOG.md entry) and reference it in the PR body; no hold needed.
- Everything else per the standard system: model tiers, loops, decision log, green marker before push.
