# Governance

## Why this exists

An autonomous agent can make a reasonable local choice and still create an irreversible system-wide mistake, especially when an old decision is forgotten or a privileged action is treated as routine. This governance model prevents repeated questions, rewritten history, unapproved production changes, and proposal queues that quietly turn into implementation queues. It keeps work moving by parking only the blocked branch of work while preserving a durable trail of who decided what and why.

## The operating contract

Governance is a routing layer, not a meeting process. Most reversible work proceeds through the normal delivery pipeline; only a narrow set of decisions is reserved for the operator.

| Artifact or control | Purpose | Source of truth | Mutation rule |
|---|---|---|---|
| Pending Decisions | Holds unresolved operator choices | Project decision log | Add, reconcile, then resolve |
| Decided | Records final decisions and rationale | Project decision log | Append only |
| Work Log | Records shipped, halted, parked, and idle outcomes | Project decision log | Append one row per work unit |
| Tracker item | Preserves proposals and implementation intent | Configured tracker | Read back every write |
| Code-host state | Proves branches, change requests, and merges | Code host | Query live before acting |
| Capability gate | Prevents privileged actions | Credential scope or mechanical hook | Fail closed |

Before changing a tracker item's status, read that project's actual workflow states rather than assuming a remembered or default sequence — a project-defined workflow always supersedes it. Every tracker item belongs under a parent epic or equivalent grouping; if none fits, propose one instead of leaving the item ungrouped.

Use one decision file per project:

```text
<state-root>/decisions/<project>.md
```

Both execution tracks must use the same file. A mirror, dashboard, tracker comment, or chat transcript may improve visibility, but none of them supersedes this record.

When a wiki or knowledge-base integration is connected for the project, mirror new decision entries to it as they are logged. The local decision log stays canonical; if the mirror is unreachable, log locally and mirror on a later pass rather than letting the outage block the decision itself.

## Canonical file shape

Create the file once and preserve these three sections. Extra prose is acceptable outside the tables, but automation should parse only the documented columns.

```markdown
# <project> Decision Log

## Pending Decisions

| Date | ID | Decision needed | Options | Recommendation | Blocks |
|---|---|---|---|---|---|

## Work Log

| Date | What shipped / halted / parked | PR or trail | Track/model |
|---|---|---|---|

## Decided

Append-only. Corrections create a new row that supersedes an earlier ID.

| Date | ID | Decision | Decided by | Why | Link |
|---|---|---|---|---|---|
```

Keep the headings stable. Stable headings let session hooks, dashboards, and optional mirrors extract the queue without understanding free-form prose.

## Decision IDs and row format

Resolved decisions use monotonically increasing `D-<n>` identifiers. IDs are unique within a project, never recycled, and remain meaningful even if the referenced tracker item later moves or closes.

The exact row interface is:

```markdown
| YYYY-MM-DD | D-<n> | <decision> | <operator, advisor, or rubric> | <one-line rationale> | <evidence or work link> |
```

Example:

```markdown
| 2030-04-18 | D-17 | Keep automated changes on the integration branch | rubric | Preserves a deliberate promotion boundary | change request 142 |
```

Log a decision immediately when it is made. Do not wait until the end of a long run, when the rationale and rejected alternatives are easiest to lose.

### What earns a decision row

Record:

- product, functional, technical, and architectural choices;
- approval or rejection of a pending item;
- plan pivots that change scope or acceptance criteria;
- an escalation halt after attempts are exhausted;
- advisor recommendations that determine the chosen path;
- operator choices made in chat, review, or a tracker;
- release and promotion decisions;
- deliberate exceptions to a normal gate.

Do not record routine mechanics such as opening a file, running a normal test, or using an already-approved library exactly as documented. Those belong in execution evidence or the work log.

### Search before asking

Before creating a pending item or asking the operator, search decisions and existing pending rows using the concepts involved, not only an exact sentence.

```bash
DECISION_LOG="${AGENT_STATE_ROOT:?}/decisions/${PROJECT_SLUG:?}.md"
QUESTION_TERMS="integration branch|promotion|schema"
rg -n --ignore-case "$QUESTION_TERMS" "$DECISION_LOG"
```

If an applicable decision exists, apply it and cite its D-ID. If the situation is materially different, say why the earlier row does not control before opening a new pending item.

### Supersede; never edit history

An incorrect or obsolete decision is evidence about how the project arrived at its current state. Do not rewrite or delete it.

Append a new row that names the old ID:

```markdown
| 2030-05-02 | D-24 | Use the replacement validation flow; supersedes D-11 | operator | The prior interface was retired | change request 188 |
```

Consumers resolve conflicts by taking the newest applicable row with an explicit `supersedes D-<n>` relationship. Silent edits are not corrections; they are lost audit history.

## Pending-decision parking

Unresolved operator choices use `P-<n>` IDs in the Pending Decisions table:

```markdown
| YYYY-MM-DD | P-<n> | <decision needed> | <two or three bounded options> | <recommended option and reason> | <exact work blocked> |
```

A useful pending row lets someone decide without reconstructing the entire task. It names a concrete fork, bounded options, a recommendation, and the smallest affected unit of work.

Actionable pending item:

```markdown
| 2030-04-18 | P-8 | Add the new uniqueness constraint? | A: add now; B: retain application validation | A, because concurrent writes bypass application checks | schema portion of TASK-142 |
```

The agent may finish analysis, tests, documentation, or unrelated tickets while `P-8` remains open. It may not perform the gated schema change.

### Parking protocol

When an operator-only decision appears:

1. Search the Decided and Pending sections for an existing answer or duplicate.
2. Consult an advisor when the fork is non-trivial.
3. Append one P-row with options, recommendation, and exact blocking scope.
4. Preserve resumable state in the tracker or work log.
5. Continue every independent unit of work.
6. If nothing ready remains, stop with a `parked` outcome rather than waiting.

One pending decision must not idle an entire run unless it genuinely blocks every eligible item.

### Reconciliation protocol

Pending does not mean permanent. At startup and before each check-in, reconcile every P-row against current reality:

| Current reality | Action |
|---|---|
| Operator answered | Append a D-row with `resolves P-<n>`, then remove the P-row |
| Work shipped by another path | Append a D-row explaining the outcome; remove the P-row |
| Proposal was rejected | Close or mark the proposal declined; append a D-row; remove the P-row |
| Duplicate of another pending item | Retain the canonical P-row, resolve the duplicate with a cross-reference |
| External change made it obsolete | Append a D-row with evidence; remove the P-row |
| Still genuinely open | Keep it and refresh stale links or blocking text |

Removing a resolved P-row is not rewriting history because the resolution is preserved in Decided. Do not remove a row without a D-entry or explicit evidence trail.

## Check-in protocol

When the operator returns, pending decisions come before progress narration. This minimizes context switching and unblocks the highest-value work first.

Present each item as:

```text
P-<n> — <decision needed>
Options: A) ... B) ...
Recommendation: <one option and why>
Unblocks: <specific work>
```

As answers arrive:

1. repeat the interpreted decision in one sentence;
2. append a D-row containing `resolves P-<n>`;
3. remove the P-row;
4. update the tracker with a read-back;
5. resume the newly unblocked work in the same session when practical.

Do not ask open-endedly when bounded options are available. Do not bury pending decisions beneath a long activity summary.

## Off-Hands Mode

Off-Hands Mode is the default operating posture: proceed on reversible, in-scope work and deliver only evidence-backed outcomes. It does not grant authority beyond the repository or project policy.

| Situation | Autonomous action |
|---|---|
| Existing approved task, reversible implementation | Run the normal pipeline |
| Unambiguous defect with an in-scope fix | Reproduce, fix, test, and review |
| Owner-only fork affects one branch of work | Park it and continue independent work |
| All eligible work is parked or externally blocked | Write a state note and stop |
| A proposal is discovered during delivery | Persist it without interrupting current work |
| A gate cannot pass within its retry cap | Park the blocker with the attempt trail |

Autonomy is about eliminating unnecessary waiting, not eliminating review or authority boundaries.

## The always-ask list

Stop before the action, even when all quality gates are green, for:

- database migrations, schema changes, and row- or tenant-access policy changes;
- destructive git operations or file deletion beyond the obvious scope of the task;
- deployment, production configuration, environment-variable changes, or release workflow changes;
- merging a change request or promoting the integration branch to the default branch;
- creating, deleting, suspending, restarting, scaling, or otherwise mutating hosted runtime infrastructure;
- paid services, purchases, or changes that create ongoing spend;
- new third-party dependencies unless project policy has already delegated that choice;
- legal, compliance, customer-facing policy, or content sign-off;
- manual third-party setup or any step requiring an operator-held credential.

This list is deliberately a superset of the minimum hard stops named in the pipeline reference. A project may widen it, and several of these entries exist because one project widened it after an incident, but no project narrows it below that minimum.

The approval must name the exact action. Approval to implement, test, open a change request, or deploy to a test environment does not imply permission to merge, promote, or change production.

When stopping, provide two or three options and a recommendation. Continue work outside the gated action.

## Capability boundaries are stronger than prompts

Instructions such as “never merge” are policy, but a credential that can merge is still a latent failure path. Enforce high-impact boundaries mechanically wherever the platform permits it.

| Boundary | Preferred control |
|---|---|
| No direct default-branch writes | Branch protection and scoped credentials |
| No autonomous merge | Credential without merge authority or required human review |
| No unverified push | Commit-bound green-marker pre-push gate |
| No production mutation | Separate production credentials unavailable to the runner |
| No destructive storage changes | Approval workflow plus restricted service role |

A prompt is useful guidance; it is not a security boundary. Fail closed when a required guard is missing or malformed.

## Advisors at real decision forks

Use an independent advisor for choices with meaningful tradeoffs, not for routine calls already answered by policy.

| Persona | Optimizes for |
|---|---|
| Architect | coupling, reversibility, scalability, migration cost |
| Senior Developer | correctness, edge cases, maintainability |
| Junior Developer | readability and onboarding |
| Product Manager | user value and scope discipline |
| Engineering Manager | throughput, slicing, and review load |
| Delivery Manager | sequencing, rollback, and critical path |
| Customer advocate | user impact, compatibility, and support burden |

Advisor output follows one shape:

```markdown
Decision needed: <one sentence>

Options:
- A — <tradeoff>
- B — <tradeoff>

Recommendation: <A or B, with reason>

Reversibility: <cheap to reverse or one-way door, with reason>
```

Ground recommendations in inspectable code, tracker state, metrics, or platform behavior. A recommendation based only on preference is not decision evidence.

## Proposal categories and gates

A proposal records a possible future change. It is not an approved task and must not become selectable work merely because it exists in the tracker.

| Category | Examples | Gate |
|---|---|---|
| Quality | focused tests, validation, reliability, bounded maintainability | May enter normal review only when project policy pre-approves this category |
| Product | new capability, changed workflow, altered user promise | Operator approval |
| Design direction | redesign, layout restructuring, theme or visual-language change | Operator approval |
| Architecture | cross-cutting structure or expensive-to-reverse interface | Advisor recommendation, then operator approval |
| Supply chain | new dependency, external service, paid integration | Operator approval |
| Data and access | migration, schema, retention, access-control rule | Operator approval plus manual handoff where required |
| Operations | deployment, promotion, hosted service mutation | Operator performs or explicitly authorizes the exact action |

### Proposal lifecycle

1. Search the tracker, decision log, and code-host changes for existing coverage.
2. Consolidate strict duplicates under one canonical proposal.
3. Create a tracker item clearly marked `[Proposal]`.
4. Add a P-row pointing to it, unless its category is already pre-approved by written policy.
5. Return to the task that surfaced the idea.
6. On approval, append a D-row and move the item into the normal planning pipeline.
7. On rejection, close the proposal with the reason and append a D-row.

Proposals are seasoning, not the meal. Discovery must not delay the active task.

### Queue hygiene

Large undifferentiated proposal queues become another source of stale truth. Periodically:

- merge exact duplicates;
- cluster related ideas behind one canonical decision;
- close proposals already delivered by another change;
- retire proposals invalidated by current architecture or product direction;
- preserve the disposition in a D-row;
- never release a category for autonomous implementation without recorded approval.

## Work log and digest

Append one Work Log row for every completed unit, including halted, parked, proposed, and idle scheduled runs.

```markdown
| YYYY-MM-DD | <shipped, halted, parked, proposed, or idle: concise result> | <change request, evidence, or attempt trail> | <track/model> |
```

Example:

```markdown
| 2030-04-18 | parked: schema portion; completed validation tests | TASK-142; P-8; test command exited 0 | primary/Terra |
```

The four-column row stays compact; the linked run record carries detailed commands and output.

A daily digest should summarize:

| Field | Meaning |
|---|---|
| Attempted | Work units entered during the period |
| Selected | Item chosen and why it was eligible |
| Changed | Code, test, or configuration surface modified |
| Reviewed | Quality and functional gates completed |
| Published | Change requests opened or updated, never implied merges |
| Idle or proposed | Explicit no-op reason or proposal IDs |
| Failed or parked | Failed gate, attempt trail, and P-ID |
| Duration | Wall-clock run duration |
| Evidence | Code-host, tracker, test, or archived-run links |

At session start, surface unresolved pending rows and a recent window of Work Log entries. Keep this digest generated from durable rows; do not maintain a second hand-written status system.

Never copy credentials, private machine paths, raw environment dumps, or unredacted customer data into logs or dashboards.

## External-state reconciliation

The tracker expresses intent. The code host is authoritative for branch, change-request, and merge state.

Before claiming work, publishing a change, closing a duplicate, or telling the operator something awaits review:

1. query the code host live;
2. derive whether the work is already covered by an open or merged change;
3. reconcile the tracker and decision queue to that fact;
4. record the evidence link.

Never declare work delivered from a tracker status alone. Never reopen a settled governance question because the tracker lagged behind the code host.

## Release decisions

Version markers and tags name repository content; they must never predict content that has not landed. Before creating a version marker:

```bash
TARGET_COMMIT="${TARGET_COMMIT:?set the commit to release}"
git cat-file -e "${TARGET_COMMIT}^{commit}"
git show --stat --oneline "$TARGET_COMMIT"
git merge-base --is-ancestor "$TARGET_COMMIT" "origin/${INTEGRATION_BRANCH:?}"
```

Only after those checks prove the intended content is present may an authorized operator create the marker. Promotion and merge remain operator actions.

This content-before-marker rule is operational hardening beyond the high-level public overview; it makes the stated release boundary mechanically checkable.

## Failure modes and guards

| Failure mode | Why it happens | Guard |
|---|---|---|
| The same question is asked repeatedly | Chat memory is treated as the record | Search the decision log before asking; cite the D-ID |
| Earlier reasoning silently changes | A row is edited in place | Append a superseding D-row; never edit Decided |
| One blocked choice stalls all work | The queue is treated as a global lock | Record exact blocked scope and continue independent work |
| A pending item survives after work ships | Queue is not reconciled with external reality | Reconcile pending rows at startup and check-in |
| Two agents implement the same proposal | Proposal existence is mistaken for a claim | Require approval, live coverage checks, and atomic claim |
| Proposal backlog becomes unreviewable | Every observation becomes a separate item | Deduplicate, cluster, and periodically retire stale proposals |
| A prompt-only prohibition is bypassed | Credential still permits the action | Use least privilege, branch protection, and mechanical gates |
| A tracker says “done” but no change exists | Tracker is treated as delivery evidence | Query the code host and link the actual change |
| A version tag precedes its content | Release metadata is created optimistically | Verify target commit and integration ancestry first |
| Sensitive local data leaks into a digest | Raw logs are copied wholesale | Publish structured summaries and redacted evidence links |
| An exception becomes permanent policy | Override rationale is not recorded | Log the exact exception, scope, approver, and expiry condition |

## Conformance checks

A project follows this governance model when all of these are true:

- one canonical decision file contains Pending Decisions, Work Log, and Decided;
- every resolved governance choice has a unique D-ID;
- superseded choices remain visible and point forward to the replacement;
- every P-row has bounded options, a recommendation, and exact blocked scope;
- check-ins present pending items before the activity digest;
- independent work continues while a decision is parked;
- proposal categories cannot silently become eligible implementation work;
- code-host state is checked before claims, dedupe, and delivery claims;
- merge, promotion, schema, destructive, deploy, and runtime authority remain operator-controlled;
- credentials and platform controls enforce high-impact boundaries;
- every work unit leaves a compact outcome row with evidence;
- logs contain no credentials, private paths, or sensitive payloads.

## What this deliberately does not do

This model does not replace project-specific product ownership, security review, legal review, or incident response. It does not grant the agent merge, production, schema, destructive, purchasing, or runtime-infrastructure authority.

The decision log stands on its own and does not require an external tracker, hosted dashboard, or mirror to function. But where a project is governed by a tracker, that requirement is not optional: every pull request references its tracker item. A hosted dashboard or decision-log mirror remains an optional view over the same canonical record, and may fail without blocking delivery.

It does not turn every implementation detail into a committee decision. Reversible, in-scope choices already covered by the planner's contract and project conventions remain autonomous.

It does not treat a proposal, tracker claim, branch, empty commit, or empty change request as shipped work. Delivery requires a meaningful reviewed change and code-host evidence.

It does not auto-merge, auto-promote, or interpret silence as approval. When explicit approval is required and absent, the affected action stays parked.
