# Autonomous runner

## Why this exists

A scheduled agent that works in a developer checkout can destroy uncommitted work, overlap with itself, or silently stop running after its scheduler entry is replaced. Per-project wrappers make those failures harder to fix because every project acquires a slightly different lock, timeout, credential path, and branch rule. This reference defines one shared runner whose configuration varies by project while its safety behavior remains identical.

## The operating rule

Install and maintain one runner for the machine. Onboarding a project creates project state and one marked scheduler entry; it does not create another runner.

The runner receives a repository location and a stable slug, resolves the remote URL and configured integration branch, and then works in a dedicated disposable clone. A project-specific prompt is configuration, not a fork of the orchestration code.

| Concern | Shared runner owns | Project configuration owns |
|---|---|---|
| Process isolation | Lock, process group, watchdog | Stable project slug |
| Repository isolation | Dedicated clone, clean reset | Remote URL |
| Delivery base | Reject default branch | Integration branch name |
| Authentication | One managed credential source | Repository authorization only |
| Work selection | Resume, coverage, claim, idle rules | Tracker or backlog location |
| Instructions | Generic unattended prompt | Optional scoped prompt |
| Observability | Run log, result, duration, rotation | Project label and links |
| Scheduling | Marker-owned crontab entry | Cadence and minute offset |

Do not generate a wrapper, token file, clone manager, lock implementation, or lint launcher per project. If a project exposes a missing requirement, add the smallest general capability to the shared runner and cover it with a runner-level check.

## Canonical onboarding

Onboarding is a one-time command. Use absolute paths because scheduled shells have a minimal environment and an unpredictable working directory.

```bash
<install-root>/onboard-autodev.sh \
  <repo-dir> \
  <project-slug> \
  10 \
  --every 30 \
  --base integration \
  --hook
```

The command validates the repository, records the remote URL and integration branch, prepares the remote integration branch when allowed, installs the repository push gate, and adds or replaces the scheduler line identified by the project marker.

Conceptually, the resulting crontab entry has this shape:

```cron
10,40 * * * * <install-root>/automations/autodev-runner.sh <repo-dir> <project-slug>  # autodev:<project-slug>
```

The onboarding program owns the exact expression. Users provide a supported cadence and offset; they should not calculate or paste the expression by hand.

### Onboarding acceptance check

After editing the scheduler, read it back and assert that exactly one line carries the marker. Writing a temporary crontab and receiving exit code zero is not enough: a filtering mistake can remove the new line or unrelated jobs.

```bash
marker='# autodev:<project-slug>'
count="$(crontab -l 2>/dev/null | grep -F -c "$marker" || true)"
test "$count" -eq 1
crontab -l | grep -F "$marker"
```

Before replacement, back up the current crontab. Remove only the line ending in the exact owned marker, append the new line, install the result, and perform the read-back check. Re-running onboarding must be idempotent.

## Project state

Keep project data in a state directory keyed by slug. The minimum durable state is small:

| State | Purpose | Required property |
|---|---|---|
| `origin-url` | Clone without reading the developer checkout | Canonical remote URL |
| `base-branch` | Reset and target PRs consistently | Integration branch, never default |
| `prompt.md` | Optional project scope | Data-only override |
| `run.log` | Human-readable history | Append-only with rotation |
| `last-result` | Watchdog and dashboard input | Atomic replacement |
| `lock/` | Mutual exclusion | Atomic acquisition |

Do not represent one environmental fact twice. For example, do not combine a sentinel file that enables fallback with an environment variable that independently disables it; two authorities eventually disagree. Choose one source of truth and derive all behavior from it.

Secrets are machine configuration, not project state. The runner may load a shared credential source, but onboarding must not copy credentials into each lane.

## Dedicated-clone lifecycle

The source checkout is an input to onboarding, not the runner's workspace. A scheduled run uses a dedicated clone so it cannot collide with editor changes, local build artifacts, or another worktree's metadata.

Each run follows this order:

1. Acquire the project lock.
2. Load and validate the project state.
3. Clone if the dedicated clone does not exist.
4. Fetch the remote with pruning.
5. Abort if the configured base is the default branch.
6. Abort if the dedicated clone has an unexpected in-progress Git operation.
7. Reset the clone to the remote integration tip.
8. Clean only inside the validated dedicated clone.
9. Resolve current work coverage from the code host.
10. Run one bounded autonomous work item.
11. Record the result and release the lock.

A reset must name the remote-tracking integration reference explicitly. Never reset to a stale local branch.

```bash
git -C "$clone_dir" fetch --prune origin
git -C "$clone_dir" reset --hard "origin/$integration_branch"
git -C "$clone_dir" clean -ffd
```

These commands are safe only after the runner has proved that `clone_dir` is its own dedicated clone for the expected remote. Never substitute an unresolved variable, a developer checkout, the filesystem root, or a home directory.

### Clone identity guard

Before destructive cleanup, verify all of the following:

- the path is non-empty and under the runner's state root;
- the directory is a Git worktree;
- its `origin` URL matches recorded state;
- the resolved integration branch exists on the remote;
- no merge, rebase, cherry-pick, or bisect is in progress.

Fail closed on any mismatch. Re-cloning the dedicated clone is cheaper than guessing which state is safe to preserve.

## Integration branch policy

Feature branches and pull requests target the configured integration branch. They never target the repository's default or production branch.

Onboarding should fetch the code host's default branch and compare its name with the requested base. Reject equality even if the branch happens to be called something other than a conventional default name.

```bash
test "$integration_branch" != "$default_branch" || {
  echo "refusing autonomous work against the default branch" >&2
  exit 1
}
```

Promotion from integration to production is a separate, human-authorized workflow. The runner does not merge its own pull requests and does not create a promotion request unless that exact action was explicitly authorized.

## Locking and time bounds

Use one lock per project lane. An atomic directory creation works across ordinary scheduled shell invocations and makes ownership inspectable.

```bash
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "skip: another run owns $project_slug"
  exit 0
fi
printf '%s\n' "$$" >"$lock_dir/pid"
cleanup_lock() {
  rm -f -- "$lock_dir/pid"
  rmdir -- "$lock_dir"
}
trap cleanup_lock EXIT INT TERM HUP
```

Do not delete a lock merely because its timestamp is old. A slow live process still owns it. Validate the recorded process identity; let the watchdog terminate the process group; remove a stale lock only when its owner is demonstrably gone.

There are two timeout layers:

| Layer | Protects against | Expected response |
|---|---|---|
| Command timeout | Lint, tests, network calls, or CLIs that hang | Fail the stage with captured output |
| Whole-run watchdog | Agent tree exceeds the scheduled window | TERM process group, grace period, then KILL |

The whole run must occupy its own process group so the watchdog stops children as well as the parent. Killing only the wrapper leaves compilers, agents, or credential helpers running and the next tick can overlap them.

Choose the watchdog longer than the normal useful work window but shorter than the scheduler interval in which overlap becomes harmful. The reference implementation uses a bounded long-run watchdog; deployments may tune the duration, but must not remove the bound.

## Work selection and ticket coverage

The tracker describes intent and eligibility. The code host is authoritative for existing branches, pull requests, merges, and published coverage.

At the start of every tick, build a coverage set from open and recently merged pull requests. Extract stable work-item references from titles and bodies, not from branch names alone. A covered item is ineligible for new implementation.

```text
resolved decisions
    -> resumable in-flight work
    -> red CI or requested review changes
    -> highest-priority eligible item not in code-host coverage
    -> idle handling
```

Re-query coverage immediately before publishing. The interval between selection and push is a race: another lane may have opened a pull request after this lane selected the item.

Claiming must be atomic in the system that owns claims. A tracker status change without a corresponding implementation state is not sufficient deduplication.

### Pull-request validity

A shippable pull request must contain implementation, tests, documentation, or another requested repository artifact. Tracker-only edits and empty branches are coordination events, not delivery.

Do not open an empty pull request to reserve an item. If an older lane left a claim-only empty pull request, verify that it has no meaningful diff, observe a bounded grace period, close it as abandoned, clear the stale claim, and record the cleanup before selecting the item.

## Idle behavior

Idle is a valid successful outcome. When no eligible work remains, the runner should:

1. record that coverage and eligibility were checked;
2. optionally create a deduplicated proposal if scheduled proposals were explicitly enabled;
3. never manufacture a repository diff merely to produce a pull request;
4. exit zero so the next scheduled tick can resume normally.

Proposals belong in the configured tracker or backlog and in the pending-decision queue. They are not implementation-ready until their category and approval state allow selection.

Quota exhaustion is also normally a quiet, resumable outcome. Log it, make no state mutation that requires cleanup, and let the next tick retry. Notifications should be reserved for events that need action.

## Lane prompt skeleton

The runner should pass a bounded unattended contract to the agent. A project override may narrow scope, but it must retain the safety clauses.

```text
Run one autonomous development tick for <project>.

Base branch: <integration-branch>; never target the default branch.
Workspace: the validated dedicated clone supplied by the runner.
Authority: do not merge, promote, deploy, mutate runtime infrastructure,
or make destructive/schema changes without explicit approval.

Order:
1. Apply resolved decisions.
2. Resume one in-flight item or red review/CI item.
3. Otherwise select one eligible item after code-host coverage checks.
4. Run planner -> developer -> tester -> independent code reviewer
   -> functional reviewer -> push.
5. If no item is eligible, record idle and stop; do not open an empty PR.

Acceptance criteria:
- The selected item is absent from current open/merged coverage at claim
  time and again immediately before publication.
- Every required pipeline gate reports PASS with command evidence.
- The PR targets <integration-branch> and contains a meaningful diff.
- The run log records selected, changed, reviewed, published, parked,
  failed, or idle status with duration and evidence links.

End with a criterion-by-criterion PASS/FAIL self-check using actual output.
```

## Observability

Each tick writes enough information to answer: Did it run? What did it select? Where did it stop? What evidence supports that outcome?

| Field | Example value | Why it matters |
|---|---|---|
| Run ID | Timestamp plus project slug | Correlates files and messages |
| Start/end | ISO-8601 timestamps | Detects missed and slow runs |
| Base commit | Full commit ID | Reproduces the starting point |
| Selection | Work item or `idle` | Explains activity |
| Coverage count | Open and merged matches | Supports dedupe decision |
| Pipeline result | Stage and PASS/FAIL | Routes recovery |
| Published artifact | Pull-request URL | Gives the operator an action |
| Exit class | success, idle, blocked, timeout, quota | Separates expected outcomes |
| Duration | Elapsed seconds | Reveals regressions |

Capture raw executor output in a per-run file rather than holding it in shell variables. Large captured output can block a waiting process or exceed shell limits. Append a concise terminal result to the lane log and rotate that log at a bounded size.

A watchdog or dashboard should identify a missed expected tick, a run exceeding its bound, repeated failures at the same stage, and a scheduler marker that disappeared. It should not infer success merely from a process exit; success requires the expected result record.

## Failure modes and guards

| Failure mode | What caused it | Guard |
|---|---|---|
| Project wrapper hangs forever | A lint command had no timeout | Bound commands and the whole process group |
| Two ticks edit concurrently | Timestamp-based stale lock was removed early | Atomic lock plus verified process ownership |
| Dirty local files disappear | Runner used a developer checkout | Dedicated validated clone only |
| Work lands on production | Base defaulted from repository metadata | Explicit integration base and equality rejection |
| Duplicate implementation | Lane trusted tracker status | Build coverage from code-host PRs before claim and publish |
| Idle lane opens a tracker-only PR | Success was measured as “opened a PR” | Idle is success; require a meaningful diff |
| Empty claim PR blocks work forever | Placeholder was treated as delivery | Bounded grace, close abandoned claim, clear coverage |
| Version tag names missing content | Tag was cut before the change landed | Assert named content exists in the target commit before tagging |
| Fallback behaves inconsistently | File flag and environment flag diverged | One authoritative representation per fact |
| Scheduled job silently vanishes | Crontab rewrite dropped the owned line | Backup, exact marker replacement, read-back assertion |
| Installer duplicates a job | Onboarding appended on every run | Idempotent marker-owned replacement |
| Child agent survives timeout | Watchdog killed only the wrapper PID | Dedicated process group; TERM then KILL |
| Run appears healthy but did nothing | Required CLI was unavailable | Preflight dependencies and record an explicit no-op class |
| Logs consume the disk | Unbounded raw output | Per-run files, size rotation, retention policy |

## Adoption checklist

- [ ] One shared runner is installed from a versioned source.
- [ ] Onboarding is the only supported scheduling interface.
- [ ] Each project has one stable slug and one scheduler marker.
- [ ] Scheduler installation is backed up and read back.
- [ ] The runner uses a dedicated clone whose identity is validated.
- [ ] Every run fetches and resets to the remote integration tip.
- [ ] The configured base cannot equal the default branch.
- [ ] Destructive cleanup is scoped to the validated clone.
- [ ] Locks are atomic and process ownership is checked.
- [ ] Commands and whole runs have time bounds.
- [ ] The watchdog terminates the complete process group.
- [ ] Code-host coverage is checked before claim and publication.
- [ ] Pull requests require meaningful repository changes.
- [ ] Idle and quota outcomes are explicit and quiet.
- [ ] Logs capture start, result, duration, and evidence links.
- [ ] One source of truth represents each environment decision.

## What this deliberately does not do

- It does not merge pull requests or promote the integration branch.
- It does not deploy software or mutate hosted infrastructure.
- It does not approve schema, destructive, security-policy, or paid-service changes.
- It does not use the developer's working checkout for scheduled edits.
- It does not create per-project credentials, wrappers, or runner forks.
- It does not treat tracker state as proof that code exists or does not exist.
- It does not open empty or tracker-only pull requests to signal activity.
- It does not promise exactly-once execution; locks and coverage checks make retries safe.
- It does not hide failures behind a zero exit without a result record.
- It does not replace branch protection, least-privilege credentials, or human merge review.

The runner is deliberately narrow: prepare a safe lane, select at most one eligible unit, enforce the pipeline, publish only on green, and leave an auditable result. Everything else belongs either in project configuration or behind an explicit governance gate.
