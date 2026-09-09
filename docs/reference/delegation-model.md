# Delegation model

Delegation fails when the coordinator asks a weak executor to solve a hard problem,
accepts an unevidenced success claim, or retries forever without changing the conditions.
This model prevents those failures by making routing, evidence, escalation, and stopping
rules explicit while keeping routine work on the least expensive capable tier.

## Core contract

The coordinator owns decomposition, routing, evidence qualification, and synthesis.
The executor owns the bounded unit of work and one complete self-check loop.

For every delegated unit:

1. Select a capability tier and reasoning effort.
2. State the outcome and observable acceptance criteria in the prompt.
3. Require the executor to run the checks and attach evidence.
4. Qualify the evidence, not the confidence of the prose.
5. On failure, preserve the failure trail and escalate deliberately.
6. Stop after the bounded retry sequence and one independent rescue.

Before any of this runs, non-trivial or parallelizable delegated work is decomposed into a dependency task graph rather than handed out as one undifferentiated request. Independent branches become separate graph items the coordinator can dispatch concurrently; sequential dependencies become edges between them. Decomposition is itself part of the coordinator's job, done once up front, not something each executor works out on its own.

The operator does not choose models for routine work.
Routing is an implementation concern of the agent system.

## The three tiers

Tier names describe capability roles, not permanent provider product names.
Map each tier to the current model available in your installation.

| Tier | Default effort | Use it for | Do not use it for |
|---|---|---|---|
| Luna | `minimal` or `low` | Lookups, mechanical checks, one-command verification, narrow edits | Ambiguous behavior, cross-file design, security-sensitive reasoning |
| Terra | `medium` | Normal implementation, tests, ordinary debugging, multi-file exploration | Problems already shown to exceed its reasoning depth |
| Sol | `high` | Cross-subsystem diagnosis, architecture, concurrency, security, difficult correctness work | Routine work that Luna or Terra can verify cheaply |

Two consequences follow from tiers being roles rather than products.

First, always name the model explicitly on every delegation. A CLI's configured
default follows each new flagship release, so a delegation that omits the model
flag silently promotes routine lookups to the most expensive tier the day a new
model ships. Pinning the model is what keeps the routing decision in the rubric
instead of in a config file that changes underneath it.

Second, do not assume a new flagship arrives with a full tier family. A release
may provide only a top-tier model, in which case it fills the Sol role alone and
the cheaper tiers stay on the previous generation. Map tiers to what actually
exists, one role at a time.

The default rule is: choose the cheapest tier that can plausibly satisfy every
acceptance criterion, not the cheapest tier that can produce a plausible answer.

That distinction matters.
A lookup can sound correct without being checked.
A refactor can compile while violating an invariant.
The expected verification burden is part of the routing decision.

## Reasoning effort

The supported effort ladder is:

```text
none -> minimal -> low -> medium -> high -> xhigh
```

Effort controls how much reasoning budget an executor receives within a tier.
It does not turn a small model into a large one.

| Effort | Intended use | Typical signal |
|---|---|---|
| `none` | Deterministic pass-through where reasoning is unnecessary | Emit or relay a known value |
| `minimal` | Literal lookup with no judgment | Find a declaration or report an exact status |
| `low` | Mechanical action with a narrow check | Apply a localized edit and run one check |
| `medium` | Standard engineering reasoning | Implement a feature and test its behavior |
| `high` | Deep diagnosis or consequential review | Trace interacting components or prove invariants |
| `xhigh` | Final same-tier retry after `high` failed | Exhaust the strongest configured reasoning path |

Do not start at `xhigh`.
It is a recovery setting, not a default.

Do not use `none` merely to save cost.
If the work contains a branch, ambiguity, or judgment call, begin at `minimal` or above.

## Routing decision table

Route the whole delegated unit, including its checks.
If writing the change is easy but proving it is correct is hard, route for the proof.

| Task class | Initial route | Why |
|---|---|---|
| Read one known file and return one exact value | Luna / `minimal` | Bounded lookup with no synthesis |
| Report branch, status, diff, or command output | Luna / `low` | Mechanical operation plus interpretation |
| Verify that a known fix appears in one location | Luna / `low` | Narrow inspection against an explicit expectation |
| Make a mechanical one-file edit | Luna / `low` | Small change with a local check |
| Summarize several related files | Terra / `medium` | Requires synthesis across context |
| Implement a normal feature across a few files | Terra / `medium` | Default implementation path |
| Add or repair tests for known behavior | Terra / `medium` | Requires behavior and failure-path reasoning |
| Diagnose an ordinary test failure | Terra / `medium` | Cause is unknown but scope is usually bounded |
| Review a normal implementation independently | Terra / `medium` | Needs judgment, not only syntax checks |
| Design a cross-component change | Sol / `high` | Requires trade-offs and invariant tracing |
| Diagnose a failure spanning multiple subsystems | Sol / `high` | Wide causal search and competing hypotheses |
| Review concurrency, authorization, or data-loss risk | Sol / `high` | Failure cost and subtlety justify the strongest tier |
| Retry work that failed at Terra for reasoning reasons | Sol / `high` | The failure is evidence that the default tier was insufficient |

### Route by uncertainty, not file count

A one-line authorization change may deserve Sol.
A twenty-file version replacement may deserve Luna.

Use these questions in order:

1. Is the desired result completely specified?
2. Are the relevant files and interfaces already known?
3. Can correctness be shown with a narrow deterministic check?
4. Could a wrong answer affect security, data integrity, concurrency, or releases?
5. Has a lower route already failed for a reasoning-related cause?

If questions 1 through 3 are yes and question 4 is no, Luna is usually enough.
If discovery or normal engineering judgment is required, use Terra.
If question 4 or 5 is yes, use Sol unless the action is purely mechanical.

## Delegation prompt contract

A delegation prompt is a work order, not a conversational hint.
It must give the executor enough information to work without guessing and enough
criteria to prove completion without inventing a private definition of done.

### Required fields

Every prompt should include:

- The selected tier and effort.
- One bounded task outcome.
- Relevant context and interfaces.
- Explicit in-scope and out-of-scope boundaries.
- The deliverable and allowed write locations.

State the write boundary explicitly, because it is the one place where delegation is legitimately incomplete. An executor confined to a workspace sandbox can read widely but write only inside its own working directory; a change it needs to make elsewhere will fail there no matter how the prompt is worded. Route that write to the coordinator's own track and keep everything around it delegated — the reads, the review, the verification. A single out-of-boundary write is not a reason to pull the whole unit of work back.

Two fields are not optional polish; they are mandatory on every delegation, with no exception for a task that looks small: observable acceptance criteria, and a self-check format that requires the executor to return each criterion marked PASS or FAIL with real evidence — command output or file content, never asserted confidence. A prompt missing either field has not defined a bounded unit of work; it has issued a hope.

### Copy-pasteable prompt

```text
Route: --model <tier-model-id> --effort <effort>

Task:
<one bounded outcome stated as an imperative>

Context:
- Repository or workspace: <workspace>
- Relevant paths or interfaces: <paths-or-interfaces>
- Existing behavior or failure: <observable current state>

Scope:
- You may change: <explicit targets>
- You must not change: <explicit exclusions>
- Preserve: <compatibility, security, or data constraints>

Deliverable:
<artifact or behavior that must exist when finished>

Acceptance criteria:
1. `<check command>` exits successfully and shows <expected signal>.
2. <file, API, or behavior> contains or performs <specific result>.
3. No changes exist outside <allowed scope>, shown by `<scope check>`.

End your report with a self-check. Mark every criterion PASS or FAIL and
include one line of actual command output or file content as evidence for each.
If any criterion fails, state exactly what failed and why. Do not replace
evidence with an assertion that the work is complete.
```

Add only context that changes execution.
Long prompts full of history hide the contract and increase error rates.

## Writing acceptance criteria

Acceptance criteria are the executable definition of done.
They should identify a signal that another agent can independently inspect.

| Weak criterion | Strong criterion |
|---|---|
| “The change works.” | “The focused test exits zero and names the new case.” |
| “The file was updated.” | “The file contains the required heading and no deprecated key.” |
| “Tests look good.” | “The test command exits zero; include its summary line.” |
| “No unrelated changes.” | “The scope check lists only the allowed targets.” |
| “The bug is fixed.” | “The original reproduction now produces the expected value.” |

Prefer one check that proves behavior over several checks that only inspect syntax.

When a command cannot demonstrate the result, quote a small, identifying file excerpt
or report a reproducible interaction with exact inputs and outputs.

Do not require the executor to prove facts it cannot observe.
For example, a local agent can prove that a migration file exists,
but it cannot claim that production was migrated unless it has authorized runtime evidence.

## Evidence standards

Evidence is a captured observation, not a sentence saying an observation happened.

Acceptable evidence includes:

- A command, exit status, and identifying output line.
- A focused test name and its passing summary.
- A file path plus a short excerpt containing the required content.
- A before-and-after reproduction with exact inputs and outputs.
- A diff or status listing that proves write scope.

Insufficient evidence includes:

- “Done,” “verified,” or “all tests pass” without output.
- A command name without its result.
- A generated summary of code that was never read.
- A passing unrelated test suite.
- A screenshot where machine-readable output was available.
- Evidence from before the final edit.

### Minimal evidence block

```text
Criterion 1 — PASS
$ <focused-check>
<one identifying output line>

Criterion 2 — PASS
$ <scope-check>
<only the allowed target is listed>

Criterion 3 — FAIL
$ <behavior-check>
<actual failing line>
Reason: <specific blocker>
```

Keep raw evidence short enough to inspect.
If output is large, include the command, exit status, summary, and the relevant failure lines.
Store full logs only when the project already has a standard location for them.

## Single-loop ownership

The executor performs the checks required by its acceptance criteria.
The coordinator reads the returned evidence and decides whether it proves the criteria.

The coordinator should not automatically rerun the entire executor check suite.
That creates two qualification loops, doubles cost, and can produce conflicting results
from different workspace states.

The coordinator may run a narrow meta-check when qualification itself requires it,
such as confirming that the evidence came from the intended revision.
That is evidence gating, not a second implementation loop.

## Self-qualify, escalate, retry

Treat a result as failed when any criterion is marked FAIL, lacks evidence,
contains assertion-only evidence, or the executor returns empty or aborted output.

The retry prompt must include:

- The previous route.
- Which criterion failed.
- The relevant observed output.
- What changed in the new route or instructions.
- The same definition of done unless the planner explicitly changes it.

### Escalation order

Increase effort before capability when more careful reasoning on the same context
has a plausible chance of success.
Increase tier when the failure shows a capability, context-window, or problem-depth gap.

| Failure signal | Next move |
|---|---|
| Missed a stated detail, otherwise sound | Resume same tier at the next effort level |
| Incomplete exploration or shallow diagnosis | Raise effort, then retry with the missing evidence attached |
| Repeated reasoning error or cross-component confusion | Move up one tier with a fresh run |
| Tool outage, permission denial, or unavailable dependency | Do not spend a stronger model; report or route the environmental blocker |
| Task was too broad | Split it and retry bounded units at the original tier |
| Acceptance criteria were wrong | Return to planning; do not optimize against a broken contract |

### Four-attempt cap

Four attempts is a ceiling, not a quota.
Stop early when the blocker is environmental, authority-bound, or proven impossible.

A common sequence for work initially routed to Luna is:

| Attempt | Route | Context handling |
|---|---|---|
| 1 | Luna / `low` | Start bounded task |
| 2 | Luna / `medium` | Resume with failed criterion and evidence |
| 3 | Terra / `medium` | Fresh run with the complete failure trail |
| 4 | Sol / `high` or `xhigh` | Fresh final primary-track attempt |

For work that starts at Terra, use Terra / `medium`, Terra / `high`,
Sol / `high`, then Sol / `xhigh` if each step remains justified.

For work that starts at Sol / `high`, the next meaningful route is Sol / `xhigh`.
Do not manufacture two more identical attempts merely to reach four.

Use session resume only while staying on the same model and when its accumulated
context is useful.
Switching tiers should start fresh so the new executor independently reconstructs
the problem from the prompt and failure trail.

### Retry prompt suffix

```text
Previous attempt:
- Route: <tier> / <effort>
- Failed criterion: <criterion number and text>
- Evidence: <actual output or file excerpt>
- Diagnosis: <why the attempt was insufficient>

Retry instruction:
<what to inspect or reason about differently>

The original acceptance criteria remain unchanged.
Run the self-check again and report PASS/FAIL evidence for every criterion.
```

## Cross-track rescue

After the primary track reaches its attempt cap, allow one rescue on an independent
execution track using the strongest appropriate tier.

Independence matters more than branding.
The rescue should use a different model family or execution environment so it does
not repeat the same blind spot.

The rescue receives:

- The original work order.
- All acceptance criteria.
- Every attempted route.
- The compact failure trail and evidence.
- The current workspace state.
- A warning that this is the final attempt.

If rescue fails, stop.
Report the attempts, the last observed blocker, and what authority or environmental
change would make another attempt useful.

Never bounce indefinitely between tracks.

## Failure modes and guards

| Failure mode | Why it happens | Guard |
|---|---|---|
| A weak tier returns polished but shallow prose | Routing considered output size, not verification depth | Route for the hardest acceptance criterion |
| Every task starts at the strongest tier | “Safer” feels easier than classifying work | Use the decision table and promote only on evidence |
| Vague prompts cause scope drift | The executor invents its own definition of done | State explicit scope, exclusions, and observable criteria |
| Assertion is accepted as proof | Coordinator trusts confidence language | Require actual output or file content per criterion |
| Empty or aborted output is treated as success | No explicit qualification rule | Classify missing evidence as a failed attempt |
| Retry repeats the same mistake | Failure output is omitted from the next prompt | Append the failed criterion and observed evidence |
| A stronger model inherits a bad frame | Session context is resumed across tiers | Use a fresh run when switching tiers |
| Cost grows without progress | Attempts are unbounded | Four primary attempts, one independent rescue, then halt |
| Rescue repeats the same blind spot | Rescue uses the same execution track | Require a genuinely opposite track |
| Capability is escalated for an environment failure | The system mistakes access for reasoning | Classify permissions, service, and dependency failures first |
| Coordinator and executor both run full verification | Ownership is unclear | Executor owns one loop; coordinator gates its evidence |
| A broad task overwhelms every tier | Scope was never decomposed | Split into bounded units before further escalation |
| Criteria change during retry | An executor optimizes toward easier success | Only planning may revise the contract, with the change recorded |
| A delegated action crosses an authority boundary | Autonomy rules were absent from the prompt | Put destructive, schema, and release exclusions in scope |

## When not to delegate

Delegation has coordination cost and creates another context boundary.
Keep work in the coordinator when all of the following are true:

- The full answer is already contained in the operator's message.
- No file, command, network, or repository inspection is required.
- No independent implementation or verification step is needed.

Typical examples are:

- Answering a direct question from supplied facts.
- Explaining a code snippet pasted into the conversation.
- Making a high-level sequencing choice that requires no additional evidence.
- Synthesizing already-qualified executor reports into one result.

Also keep orchestration actions with the orchestration owner when project policy assigns
them there, such as publishing a branch, opening a pull request, or changing tracker state.
An executor may prepare evidence for those actions without owning the external mutation.

Do not delegate merely to satisfy a percentage target.
Delegate because the task needs tools, isolated execution, independent judgment,
or parallel work.

## What this deliberately does not do

This model does not guarantee correctness from model confidence.
Only evidence can satisfy an acceptance criterion.

It does not replace the implementation pipeline.
Planning, testing, independent review, functional review, and the push gate remain
separate controls.

It does not grant deployment, destructive, schema, or production authority.
Those boundaries come from project governance and remain in force at every tier.

It does not pin tier names to one vendor's permanent model catalog.
Installations may update tier-to-model mappings without changing this contract.

It does not prescribe parallelism for tightly coupled work.
Use dependency-aware planning and delegate only units that can be verified coherently.

It does not retry external outages with increasingly expensive reasoning.
Environmental failures need an environmental change.

It does not treat four attempts as mandatory.
Four is the maximum before rescue, and obvious blockers should stop sooner.

It does not hide failure.
A halted trail with precise evidence is a valid, actionable outcome.
