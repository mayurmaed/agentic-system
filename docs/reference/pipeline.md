# Delivery pipeline

This pipeline prevents three common failures: code that passes tests but misses the request, changes reviewed only by their author, and pushes made before verification is complete. It turns an implementation request into six explicit stages with observable gates, bounded retries, and an exact-commit push marker. A green result means the requested outcome was demonstrated, not merely that code was written.

## The contract at a glance

The pipeline is:

```text
planner -> developer -> tester -> code reviewer -> functional reviewer -> push
```

Each stage consumes the planner's contract and produces evidence for the next gate.
The planner's acceptance criteria are the single definition of done.
Later stages may refine evidence or report a plan misread, but they must not silently substitute their own scope.

| Stage | Owner | Required input | Gate | Failure route |
| --- | --- | --- | --- | --- |
| Planner | Planning agent | Original ask, repository state, applicable project rules | Every requirement maps to an observable criterion | Revise the plan |
| Developer | Implementation agent | Planner contract and any returned findings | Developer criteria pass with evidence | Retry implementation within its attempt cap |
| Tester | Test agent | Planner contract and implementation diff | Relevant tests pass; actual output is recorded | Return implementation failures to developer |
| Code reviewer | Independent review agent | Planner contract and complete diff | No blocker or should-fix finding remains | Return verified findings to developer |
| Functional reviewer | Outcome review agent | Original ask, contract, diff, test evidence | Requested use works at the planned depth | Developer, or planner for `PLAN-MISREAD` |
| Push | Orchestrator | Green results for every required gate and a committed HEAD | Marker matches HEAD; branch and pull request policy pass | Stop without pushing |

The orchestrator owns transitions and publication; stage agents own their checks, not the whole pipeline.

## 1. Planner: define done once

The planner reads the original request and the relevant code before proposing work.
It does not edit files.
Its output is a contract against which development, testing, and both reviews are judged.

The contract must contain:

1. Every explicit requirement from the request.
2. Implied requirements necessary for the requested behavior to be usable.
3. The files expected to change and why.
4. One blast-radius class: `small`, `large-simple`, or `large-complex`.
5. Any approval flags required by project policy.
6. Observable acceptance criteria grouped by later stage.
7. Risks and behavior that must not change.

Use this copy-pasteable contract shape:

```markdown
## Requirements
- R1: <observable outcome from the original ask>
- R2: <compatibility or error-path requirement>

## Files to touch
- `<path>` — <why this file owns the change>

## Blast radius
`small | large-simple | large-complex`

## Approval flags
`none | NEEDS-OWNER-APPROVAL: <reason>`

## Stage acceptance criteria

### Developer criteria
- D1: `<file>` contains/implements <specific behavior>.

### Tester criteria
- T1: `<command>` exits 0 and reports <expected result>.

### Code review criteria
- C1: All callers of `<changed interface>` remain valid.

### Functional criteria
- F1: Given <state>, when <action>, then <user-visible outcome>.

## Risks / must-not-change
- <existing behavior> remains unchanged.
```

### What makes a criterion valid

| Weak criterion | Valid replacement |
| --- | --- |
| “Feature is complete” | “Given an expired session, the request returns the documented unauthorized response.” |
| “Tests pass” | “`<targeted-test-command>` exits 0 and reports zero failures.” |
| “UI looks right” | “At the supported viewport, the primary action is visible, named, keyboard reachable, and completes the flow.” |
| “No regressions” | “The existing tests for the changed callers pass, and the named must-not-change flow is exercised.” |
| “Documentation updated” | “`<document>` contains the new option, default, and one runnable example.” |

A criterion is observable when another agent can independently decide PASS or FAIL from a command result, file excerpt, diff, or exercised behavior.
“Implemented,” “handled,” and “looks good” are assertions, not evidence.

Before returning, map each requirement to one or more criteria. A requirement without a criterion leaves the plan incomplete; a criterion serving no requirement or risk is likely scope creep.

### Ambiguity and approval flags

The planner may choose a reasonable, reversible reading of ordinary ambiguity and record it.
It must flag decisions that project policy reserves for an owner.
Typical hard stops include schema or migration changes, destructive operations beyond obvious task scope, and deployment or production configuration.
These remain hard stops even when all technical gates are green.

## 2. Developer: implement the contract

The developer receives the plan, not a vague summary. It changes only planned or clearly implied files and reports any addition.

The developer should:

- inspect neighboring code and reuse existing helpers;
- fix the shared root cause when all affected callers route through it;
- avoid unrelated refactors and speculative abstractions;
- add the smallest check that would fail if non-trivial new logic broke;
- run every developer criterion and capture real output;
- respond to returned findings one by one.

Developer output should use a stable evidence shape:

```markdown
### Diff summary
- `<path>`: <what changed and why>

### Developer self-check
| Criterion | Verdict | Evidence |
| --- | --- | --- |
| D1 | PASS | `<command>` -> `<relevant final output>` |
| D2 | FAIL | `<actual mismatch>` |
```

A failed self-check stays inside the developer's bounded execution loop.
The developer changes its approach before retrying; repeating an identical attempt is not progress.
If the developer cannot satisfy the contract within its execution attempt cap, it returns FAIL with the attempt trail.

## 3. Tester: prove the change breaks when it should

The tester verifies the planner's tester criteria and writes or updates the smallest relevant tests.
It first looks for existing test patterns and nearby suites.
It does not create a new framework when the repository already has one.

The tester runs focused suites for small and mechanical work.
It expands coverage when the plan marks a broad regression surface.
The final output must include the command, exit status, pass/fail counts, and failing test names when applicable.

If a test exposes a product-code defect, the tester does not repair product code.
It returns the failing output and a one-line diagnosis to the developer.
If the test itself is wrong, the tester may correct the test and rerun it, while reporting that change.

“The suite should pass” is invalid.
“The command exited 0 with 18 passed” is evidence.

## 4. Code reviewer: use an independent track

The code reviewer must be independent from the developer.
On a two-track installation, the reviewer runs on the opposite execution track from the developer.
If only one track is available, use a fresh context that has not participated in implementation.

The reviewer reads the complete diff and the planner contract, then checks in this order:

1. Correctness and edge cases.
2. Callers of changed interfaces.
3. Security and trust-boundary validation.
4. Scope compliance.
5. Existing conventions and reusable helpers.
6. Every code-review criterion in the contract.

The reviewer does not edit the code it reviews.
Every finding includes a location, severity, defect, and concrete failure scenario.
An unverified concern is labeled a question, not promoted to a finding.
Nits alone do not fail the gate.

Opposite-track review reduces shared blind spots; it does not excuse shallow review.
The reviewer still traces the changed paths and searches for callers.

## 5. Functional reviewer: verify delivered use

Functional review compares the result with the original ask as well as the contract.
It judges outcomes, not formatting or implementation taste.
A page that renders, an endpoint that responds, or a test suite that passes can still fail if the promised user capability is absent.

The planner selects review depth by blast radius:

| Blast radius | Typical shape | Required functional review |
| --- | --- | --- |
| `small` | Isolated file or narrow fix | Read the complete diff and tie each requirement to visible evidence |
| `large-simple` | Multi-file but mechanical or low-risk | Diff plus surrounding code and reasoned walkthrough of affected flows |
| `large-complex` | Cross-cutting behavior, shared paths, or wide regression surface | Run the affected end-to-end flow and relevant regression suites; record actual output |

The class measures verification need, not line count alone.
A one-line authorization change may be `large-complex`.
A large generated rename may be `large-simple`.

Functional output names the promised outcome, reports PASS/FAIL with evidence for every requirement, and returns a final verdict. An implementation gap returns to the developer.
A `PLAN-MISREAD` returns to the planner because fixing code against the wrong contract only creates more wrong code.

## 6. Push: publish only the verified commit

Push is a stage, not a casual command at the end of development.
The orchestrator performs it only after all required gates pass and approval flags are clear.

Before publication, verify:

- the branch contains one scoped work item;
- the diff contains a meaningful code, test, configuration, or requested documentation change;
- the code host shows no open or merged change already covering the item;
- every required gate is PASS with evidence;
- the target is the project's integration branch, never the protected default branch;
- the commit to push is the commit that was reviewed;
- the pull request title and body reference the work item;
- no owner-only action is being smuggled into publication.

Commit first, then write the exact-commit green marker:

```bash
git rev-parse HEAD > "$(git rev-parse --git-dir)/AGENTIC_GREEN"
git push -u origin <feature-branch>
```

The first command is the canonical green-marker command shape.
The repository's pre-push hook compares the marker content with the current HEAD and fails closed on mismatch.
Any new commit after marking invalidates the marker and requires the affected gates to run again.

Install the repository-local mechanical gate with:

```bash
scripts/install-git-prepush.sh <repo>
```

The marker records that gates passed; it is not a substitute for running them.
For a deliberate non-pipeline push, perform equivalent verification before writing the marker and record why the normal pipeline did not apply.

Publication opens a pull request against the integration branch.
It never merges the pull request and never promotes the integration branch to the protected default branch.

## Skip logic

Skipping is based on task shape and invocation, not impatience.

| Request shape | Stages | Rule |
| --- | --- | --- |
| Plain question or read-only research | No implementation pipeline | Answer with evidence; do not create a branch or pull request |
| Normal implementation request | All six stages | Default behavior |
| Explicit full-pipeline command | All six stages | Overrides trivial-task skipping |
| Explicit ticket workflow | All six stages | Ticket text remains the original ask |
| Truly trivial docs-only or one-line low-risk change | Developer -> tester -> push | Skip planner and both reviewers only when project rules permit |

“Trivial” means both narrow and low-risk.
Authentication, authorization, money, data loss, schema, deployment, and user-visible accessibility behavior are not trivial because the diff is short.
When uncertain, run the full pipeline.

The reduced path still requires a real check and a matching green marker.
It does not mean “edit and push.”

## Failure routing and bounce caps

The failing gate returns evidence to the stage capable of correcting the cause.
Reviewers do not bounce findings among themselves.

```text
tester FAIL ---------------------------> developer
code reviewer FAIL --------------------> developer
functional reviewer implementation FAIL -> developer
functional reviewer PLAN-MISREAD ------> planner
push policy or marker FAIL ------------> orchestrator stops
```

A return from a gate to the developer or planner is one bounce for that gate.
Each gate permits at most two bounces.
After the second corrective pass, the gate runs one final time; if it remains red, the item halts with the trail instead of cycling again.

| Gate failure | Return package | After cap |
| --- | --- | --- |
| Developer self-check | Failed criterion, output, attempted approaches | Return task-level FAIL |
| Tester | Command, failing output, diagnosis | Halt item and preserve branch |
| Code reviewer | Verified findings with locations and scenarios | Halt item and preserve branch |
| Functional reviewer | Per-requirement evidence and optional `PLAN-MISREAD` | Halt item and preserve branch |
| Push | Policy, coverage, branch, or marker error | Do not push; report exact blocker |

The halt report includes the original item, planner contract version, attempts, gate evidence, current branch/commit, and recommended next action.
An unattended run may resume that in-flight work later, but it must not claim a new item first.

Use this handoff shape:

```markdown
Status: HALTED
Gate: <stage>
Bounce count: 2/2
Commit: <sha>
Failed criteria: <ids>
Evidence: <commands and relevant output>
Attempts: <what changed between attempts>
Next action: <specific repair or owner decision>
```

## Lane prompt skeleton

An autonomous lane should supply policy and scope while leaving the six-stage contract intact.
The following is intentionally generic:

```markdown
# Lane: <lane-name>

Repository: <repo>
Integration branch: <integration-branch>
Backlog source: <tracker-or-file>
Allowed work: <labels, component, or explicit allowlist>
Excluded work: <owner-only, blocked, or competing lanes>
Run limit: one work item

1. Apply resolved decisions.
2. Query the code host; resume an in-flight branch or pull request first.
3. Select one eligible, explicitly committed item and claim it atomically.
4. Run planner -> developer -> tester -> code reviewer -> functional reviewer.
5. Enforce at most two bounces per gate.
6. On green, commit and write:
   `git rev-parse HEAD > "$(git rev-parse --git-dir)/AGENTIC_GREEN"`
7. Push the feature branch and open a pull request against the integration branch.
8. Never merge or promote to the protected default branch.
9. If idle, log blockers or create a proposal in the tracker; never open an empty or tracker-only pull request.
10. Record commands, outputs, pull request link, and final state.

Acceptance criteria:
- <criterion with command and expected result>

Self-check:
- Return PASS/FAIL for every criterion with actual output, not assertion.
```

## Code-host coverage before claiming and publishing

The tracker says what should happen.
The code host proves what has happened.
Use both, and give the code host authority for deduplication.

Before claiming an item:

1. Search open pull requests for its stable reference.
2. Search recently merged pull requests for the same reference and outcome.
3. Inspect matching branches when a prior run may have stopped before opening a pull request.
4. Resume real in-flight work instead of starting a competing implementation.
5. If work is merged, reconcile the tracker and stop.

Repeat the coverage check immediately before opening the pull request.
A claim is not coverage, and an empty branch is not implementation.
A closed claim-only pull request should be treated as abandoned unless its diff or merge evidence proves otherwise.

If a lane is idle, it may record a proposal in the configured backlog.
It must not turn that proposal, a status edit, or evidence-only tracker update into a pull request.
A pull request needs a meaningful diff that delivers part of the item.

## Evidence standards

Every gate result should be independently auditable.

| Evidence | Acceptable | Not acceptable |
| --- | --- | --- |
| Tests | Command, exit status, counts, failing names | “Tests pass” |
| File change | Path plus focused excerpt or diff | “File updated” |
| Behavior | Inputs, action, observed output | “Works locally” |
| Review | Location, defect, failure scenario | Untraced suspicion presented as fact |
| Publication | Commit, branch, target, pull request link | “Pushed successfully” without identifiers |

Keep evidence focused: enough to reproduce the verdict, not entire noisy logs.
Redact credentials and environment values.
If a command cannot run, record the exact limitation and do not convert “not run” into PASS.

## Failure modes and guards

| Failure mode | What goes wrong | Guard |
| --- | --- | --- |
| Vague planner criteria | Every later agent invents a different definition of done | Require observable criteria and requirement-to-criterion coverage |
| Tester edits product code | The independent gate becomes another developer pass | Return product defects to the developer with failing output |
| Author reviews its own diff | Shared assumptions survive review | Opposite execution track, or at minimum a fresh context |
| Reviewers hand findings to each other | Nobody owns the repair | All implementation findings return to the developer |
| Plan misread treated as a code bug | More code is written toward the wrong outcome | Route explicit `PLAN-MISREAD` to the planner |
| Gate loops forever | Automation consumes time without converging | Maximum two bounces per gate, then halt with trail |
| Lint or test command hangs | The lane never reaches a verdict | Put a timeout around each subprocess and a watchdog around the run |
| Tracker status is trusted for dedupe | A stale item produces duplicate work | Query open and merged changes on the code host |
| Two agents claim the same item | Competing implementations reach review | Atomic claim plus a second coverage check before publication |
| Idle lane opens a tracker-only pull request | Review noise looks like delivery | Proposal or idle log only; require a meaningful implementation diff |
| Claim-only empty pull request is treated as work | An abandoned reservation blocks later delivery | Inspect diff and merge evidence; close or clean up empty claims |
| Marker written before the final commit | Unreviewed content is pushed | Commit first; marker must equal current HEAD |
| Version tag is cut before the content it names | Release identity points at incomplete content | Verify the target commit contains the named content before tagging |
| Push targets the protected default branch | Integration review is bypassed | Require the integration branch as the pull request base |
| Prompt says “do not merge” but credentials allow it | A wording mistake can cross the boundary | Enforce least privilege and branch protection outside the prompt |
| Owner-only change is technically green | Schema, destructive, or production risk bypasses approval | Planner approval flag plus a hard stop before push |

## What this deliberately does not do

- It does not merge pull requests.
- It does not promote the integration branch to the protected default branch.
- It does not deploy or mutate production infrastructure.
- It does not replace repository CI, branch protection, or human approval policy.
- It does not prescribe one tracker; a stable work-item reference is enough.
- It does not make tracker state authoritative over code-host evidence.
- It does not run the entire test universe for every narrow change.
- It does not let passing tests substitute for functional delivery.
- It does not open empty, claim-only, proposal-only, or tracker-only pull requests.
- It does not choose model tiers; delegation policy handles execution routing.
- It does not guarantee correctness; it makes claims bounded, independent, and auditable.

The pipeline's promise is narrower and useful: one scoped item reaches a reviewable pull request only when the exact commit has passed every required gate, with evidence another person can verify.
