# Agentic System — Codex Track (standalone)

These rules apply when Codex runs this system without Claude Code (Claude absent, or its tokens exhausted). Same system, one track.

## Model & effort per unit of work

Tiers: **Sol** = smartest/most expensive, **Terra** = balanced (default), **Luna** = cheapest. The main session runs on whatever model was chosen; delegate sub-work to the cheapest tier that plausibly succeeds via a subprocess:

```
codex exec -m gpt-5.6-luna -c model_reasoning_effort="low" "<mechanical subtask>"
```

- **Luna + low**: single-file lookups, git status/diff checks, mechanical one-file edits, run-a-command-and-report, "did the fix apply?" verification.
- **Terra + medium** (default): feature implementation, multi-file edits, tests, ordinary debugging, exploration.
- **Sol + high** (`gpt-6-astra`; fallback `gpt-5.6-sol`): deep cross-subsystem root-cause, architecture-heavy work, large refactors, or a retry after Terra failed. `xhigh` only after Sol/high failed.

Always pass `-m` explicitly. The CLI's configured default moves to each new flagship, so an unpinned `codex exec` runs mechanical subtasks on the priciest tier. A new flagship may also ship without a full tier family — `gpt-6-astra` has no cheap or balanced sibling, so Luna and Terra stay on 5.6.

## The loop (every unit of work)

1. Acceptance criteria first — observable checks (command exits 0, file contains X).
2. Execute, then self-check each criterion with real evidence (actual output, not assertion).
3. On FAIL: one line on what failed and why, change something, retry — effort first, then tier. Never repeat an identical attempt.
4. Max 4 attempts, then ONE cross-track rescue via `claude` CLI if it is installed and authenticated; otherwise halt and report the attempt trail.

## Pipeline (auto for every implementation task)

Stages run as explicit sequential phases in this session: **plan → develop → test → code review → functional review → push**.

- **Plan** writes the contract: requirements, files, blast radius (`small`/`large-simple`/`large-complex`), approval flags, per-stage acceptance criteria. Later stages are judged only against it.
- **Code review runs in a fresh context for independence**: `codex review` in a repo, or `codex exec -m gpt-5.6-terra "adversarially review this diff: ..."` — never review your own diff in the same session.
- **Functional review depth** by blast radius: large-complex → run the affected flow + regression tests; large-simple → diff + reasoning; small → diff-only.
- Failures return to the develop phase with findings (max 2 bounces per gate).
- **Green → push**: commit, write the marker `git rev-parse HEAD > "$(git rev-parse --git-dir)/AGENTIC_GREEN"`, push, open the PR (tracker reference in title + body). Install the optional git pre-push hook (`scripts/install-git-prepush.sh <repo>`) to enforce the marker mechanically.
- Skip logic: trivial tasks (docs-only, one-liners) skip to develop → test → push; plain questions skip the pipeline.

## Trackers, decisions, off-hands

Identical to the Claude track, same files:
- Tracker chain: Jira (if available) → plandb project (if `plandb` installed) → `BACKLOG.md`.
- Decision log: `~/.claude/decisions/<project>.md` — shared with the Claude track on dual machines. Pending queue at the top (`P-<n>` rows with options + recommendation); decided entries append-only with `D-<n>` ids. Grep it before re-asking the owner anything.
- Work log: same file, `## Work Log` section — append one line per completed unit (`| date | what shipped/halted/parked | PR or trail | track/model |`), including cron state notes. It feeds the owner's daily check-in digest.
- Off-Hands Mode is the default: owner-only decisions get parked with a recommendation, unblocked work continues. Always-approve even on green: DB migrations/schema, destructive git/file deletion, deploy/prod config.

## Autonomous scheduling — canonical onboarding only

Scheduling a project for autonomous runs is ONE crontab line to the shared runner (`~/.codex/automations/autodev-runner.sh <repo-dir> <slug>`), added by `onboard-autodev.sh`. It runs in its own always-clean dedicated clone with the shared token (`~/.codex/secrets/github.env`), a lock, and a 100-min watchdog. NEVER author a per-project wrapper, clone, or token file — if the shared runner lacks something, extend it in the repo, don't fork per project.

## Personas

Consult at real decision forks (fresh `codex exec` for independence when it matters): **Architect** (structure, reversibility), **Senior Developer** (correctness, maintainability), **Junior Developer** (readability), **Product Manager** (user value, scope — may proactively propose features into the tracker as `[Proposal]`), **Engineering Manager** (throughput, slicing), **Delivery Manager** (sequencing, rollback), **CSM** (existing-user impact). Output format: Decision needed / Options / Recommendation / Reversibility.
