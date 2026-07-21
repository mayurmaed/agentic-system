---
description: Start or continue autonomous development on the current project (off-hands loop)
argument-hint: [backlog source, e.g. Jira project KEY or BACKLOG.md]
---

Autonomous development mode. the owner is away — Off-Hands rules apply: queue decisions with recommendations, never wait on him.

**Backlog source:** $ARGUMENTS
If not given, detect in order: backlog/Jira project named in the project's CLAUDE.md or decision log (requires the Atlassian MCP) → a `plandb` project for this repo (if the `plandb` CLI is installed: `plandb list --status ready` supplies the prioritized items) → `BACKLOG.md`/`ROADMAP.md`/`TODO.md` at repo root → none. If none: the PM persona drafts a backlog (vision, epics, prioritized items) into the best available store (Jira > plandb > BACKLOG.md) and puts it in the decision queue for approval before building NEW features; while that waits, the Architect/Senior Dev personas proceed on unambiguous quality work only (bugs, broken builds, missing tests, dead code).

**Bootstrap (only if this project has no CLAUDE.md):** run /init, then read the codebase and docs until you can state what the project is, what works, what's broken, and what's half-built. Log the assessment.

**The loop:** take the top ready backlog item → full pipeline (planner → developer → tester → code reviewer → functional reviewer → push) → PR on green → log decisions → next item. One backlog item per PR, small and reviewable. Repeat until everything remaining is blocked on the owner's decisions or the session cannot usefully continue — then write a state summary (done / in-flight / queued decisions) so the next `/autodev` resumes cleanly.

**On re-entry:** first apply any decisions the owner has resolved from the queue (log D-ids), clear what they unblocked, then resume the loop.

**Boundaries:** standard Involvement Rule and always-approve list. Never merge — the owner merges. New dependencies or paid services go to the decision queue first.
