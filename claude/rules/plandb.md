<!-- plandb-agent-instructions -->
# PlanDB — Task Planning for Agents

<plandb-philosophy>
You have `plandb` installed. It is your task graph — use it to decompose every non-trivial task into a dependency graph, track progress, and coordinate parallel work.

**BEFORE you start any task, ask yourself: can this be done in a single action with no dependencies?**
- If YES (one action, no parallelism possible, no follow-up steps) — just do it.
- If NO — **STOP. Plan in PlanDB first.** This includes: multiple steps, parallel work, research + execution, anything with dependencies between parts.
- If there are **2+ independent actions** — that's parallelism. Use PlanDB even if each action is simple.

This is non-negotiable. Do NOT justify skipping PlanDB because individual steps are "simple." If there are multiple steps or any opportunity to parallelize, the graph must exist before work begins. PlanDB is for any work you do — not just a specific kind of task.

PlanDB is a compound graph with two orthogonal structures:
- **Containment** (place graph): tasks contain subtasks recursively, to any depth
- **Dependencies** (link graph): edges between tasks at ANY level, crossing containment boundaries

This is more general than a flat list or a simple DAG. A subtask at depth 3 can depend on a task in a completely different branch.
</plandb-philosophy>

<plandb-core-loop>
## Core Loop

Every task follows this cycle. No exceptions.

```bash
plandb init "project-name"                            # 1. Create project (once)
plandb add "title" --description "spec" --dep t-xxx   # 2. Build the task graph
plandb go                                             # 3. Claim next ready task
# ... do the work ...
plandb done --next                                    # 4. Complete + claim next
plandb status --detail                                # 5. Reassess after each task
```

**Description is mandatory.** Every task's `--description` must be a self-contained work order: what to do, what to produce, acceptance criteria. The title is a label — the description is the spec.
</plandb-core-loop>

<plandb-decomposition>
## Decomposition

Break tasks down aggressively — not just at the project level, but within each task. The more granular your graph, the more parallelism you unlock and the faster you recover from failures.

```bash
# Split into independent subtasks (creates parallelism)
plandb split --into "A, B, C"

# Split with dependency chain (sequential)
plandb split --into "A > B > C"

# Scope into a composite task to add deeper subtasks
plandb use t-xxx
plandb add "sub-subtask" --description "..."
plandb use ..                                         # Zoom back out
```

**The decomposition rule:** if a task would take more than ~30 seconds to complete, split it further. Keep splitting until each leaf task is a single focused action. Every split is a new opportunity for parallelism — the more leaves your graph has, the more work can happen simultaneously. Composite tasks auto-complete when all children finish.
</plandb-decomposition>

<plandb-parallelism>
## Parallel Execution

**When `plandb list --status ready` returns multiple tasks, run them concurrently.** This is where PlanDB creates the most value — it tells you exactly which tasks are independent and safe to parallelize.

**Use sub-agents for parallelism.** If a task would take more than ~30 seconds to complete, and there are other ready tasks, dispatch sub-agents to work on them simultaneously. Don't serialize work that the graph says is independent.

```bash
plandb list --status ready                            # See what can run NOW
plandb what-unlocks t-xxx                             # What opens up when this completes
plandb ahead --depth 3                                # Preview next 3 layers of work
```

Sub-agent workflow:
1. Run `plandb list --status ready` to find independent tasks
2. Spawn a sub-agent per ready task — each claims with `plandb go --agent <name>`
3. Each completes with `plandb done --next --agent <name>`
4. Atomic claiming prevents conflicts — two agents cannot claim the same task
5. Collect results and continue with the next wave of ready tasks

Set `PLANDB_AGENT=<name>` to avoid passing `--agent` on every command.
</plandb-parallelism>

<plandb-adaptation>
## Mid-Flight Adaptation

Plans are hypotheses. Adapt as you learn — don't abandon PlanDB when reality diverges from the plan.

| Situation | Command |
|-----------|---------|
| Missed a step | `plandb task insert --after t-a --before t-b --title "..."` |
| Task too large | `plandb split --into "A, B, C"` |
| New info for a future task | `plandb task amend t-xxx --prepend "NOTE: ..."` |
| Need to replace a subtree | `plandb task pivot t-xxx --file new-tasks.yaml` |
| Unsure about cancelling | `plandb what-if cancel t-xxx` |
</plandb-adaptation>

<plandb-introspection>
## Introspection

Use these to decide what to work on and where effort is wasted.

```bash
plandb status --detail                                # Per-task breakdown with status
plandb status --full                                  # Compound graph: containment + deps
plandb critical-path                                  # Longest chain — prioritize this
plandb bottlenecks                                    # Tasks blocking the most downstream work
plandb watch                                          # Live-updating dashboard
```
</plandb-introspection>

<plandb-knowledge>
## Knowledge Store

Record discoveries as you work. Context persists across sessions and auto-surfaces when relevant.

```bash
plandb context "what you learned" --kind discovery    # Record project knowledge
plandb search "query"                                 # BM25 search across context + tasks
plandb contexts                                       # List all context entries
```

`--kind` is freeform: `discovery`, `decision`, `pattern`, `blocker`, `reference`, `constraint`, `insight` — use whatever fits. Context auto-links to the running task and auto-surfaces on `plandb go` (lazy recall).
</plandb-knowledge>

<plandb-strategy>
## Planning Strategy

Your goal is maximum quality at maximum speed. PlanDB enables this — but only if you plan deliberately.

**Think before you add tasks.** Before building the graph, reason about the problem structure:
- What are the independent dimensions? Those become parallel branches.
- What has to happen in sequence? Those get `--dep` chains.
- What will you only learn by doing? Keep those tasks small so pivoting is cheap.

**Maximize the width of your graph.** The more tasks that are `ready` simultaneously, the more work runs in parallel. Structure dependencies to unlock breadth early:
- Front-load research and design tasks — they unblock everything downstream.
- Split work by independent outcome, not by sequential phase. "Fetch ad performance" and "Check audience status" can parallelize. "Gather all data" then "analyze everything" cannot.
- Use `plandb ahead --depth 3` to check if your graph has enough width.

**Use the critical path to prioritize.** `plandb critical-path` shows the longest chain to completion — that's your bottleneck. If you have a choice between working on something on the critical path or off it, always choose the critical path. `plandb bottlenecks` shows which tasks block the most downstream work.

**Record context aggressively.** Every discovery, constraint, or decision you make is knowledge that a future task (or a future agent) may need. Use `plandb context` immediately — don't wait until later. It costs almost nothing and compounds over time.
</plandb-strategy>

<plandb-rules>
## Rules

1. **Use PlanDB for every non-trivial task.** Multiple steps, parallel actions, or dependencies between parts — plan it.
2. **Description is the spec.** `--description` must contain everything needed to execute: context, approach, files, acceptance criteria.
3. **Maximize graph width.** Structure tasks to unlock as many parallel branches as possible.
4. **Parallelize ready tasks.** When `plandb list --status ready` returns multiple tasks, run them concurrently — with sub-agents if available.
5. **Prioritize the critical path.** `plandb critical-path` determines completion time. Focus there first.
6. **Adapt, don't abandon.** When reality changes, use `insert`, `split`, `amend`, `pivot`. Don't stop using PlanDB.
7. **Record what you learn.** Use `plandb context` for discoveries, blockers, patterns. It auto-surfaces later.
8. **Dependencies flow data.** `feeds_into` = data flows, `blocks` = ordering only, `suggests` = soft/optional.
9. **Kinds are freeform.** Common: `code`, `research`, `review`, `test`, `shell`, `generic`.
10. **Status is automatic.** `pending` → `ready` (deps done) → `claimed` → `running` → `done`/`failed`. Don't manage state manually.
</plandb-rules>
<!-- plandb-agent-instructions -->
