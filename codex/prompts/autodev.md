Autonomous development mode (Codex track — see the Agentic System section of AGENTS.md). The owner is away: queue decisions with recommendations, never wait.

Backlog source: $ARGUMENTS — if empty, detect: Jira project named in repo docs/decision log → plandb project (`plandb list --status ready`) → `BACKLOG.md`/`ROADMAP.md`/`TODO.md` → none (PM persona drafts one into the best available store and queues it for approval; meanwhile do unambiguous quality work only).

Loop: top ready item → full pipeline (plan → develop → test → independent code review → functional review) → green marker → push → PR → next. One item per PR. On re-entry, first apply decisions the owner resolved from the queue, then resume. Stop when everything left is blocked on the owner; write a state summary.

Boundaries: Involvement Rule + always-approve list; never merge; new dependencies or paid services go to the decision queue first.
