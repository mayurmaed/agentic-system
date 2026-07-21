# Global Codex Delegation Policy

Delegate nearly all work to Codex. Target: **Claude uses less than 25% of baseline token usage** (>75% reduction).

## Delegate to Codex — ALWAYS (use `Agent` with `subagent_type: "codex:rescue"`):
- Writing or editing ANY code files
- Reading ANY file from disk — even single-file lookups
- Debugging, root-cause investigation, test failures
- Codebase exploration (any number of files)
- Any multi-step implementation task
- Running and interpreting bash commands for implementation purposes
- Checking git status, diffs, logs, or repo state
- Verifying whether a fix worked

## Keep in Claude — ONLY these cases (no tool use allowed):
- Answering a question where the full answer fits entirely within what the user wrote (no file reads, no bash)
- High-level planning or architecture decisions when no files need to be read
- Explaining a code snippet the user pasted directly in the prompt

**Default rule: if Claude would reach for ANY tool (Read, Bash, Edit, Write, Glob, Grep), delegate to Codex instead.**

**Sandbox exception (the ONLY one):** Codex can read anywhere but write only inside the session's working directory. File writes outside it (~/.claude, ~/.codex, other repos) stay with Claude — but the surrounding reads, reviews, and verifications still go to Codex (Luna for checks, Terra+ for reviews). Never let an out-of-sandbox write drag the whole task back into Claude.

## How to Delegate

```
Agent(subagent_type="codex:rescue", prompt="<full task with file paths and expected outcome>")
```

Or invoke the `codex` skill for code review / consult modes.

## Model Selection per Delegation

Claude decides the model and effort autonomously — never ask the user which model to use, and upgrade automatically on failure per the loop below. Every delegation must pick a model tier AND a reasoning effort — goal: cheapest combination that plausibly succeeds. Tiers: **Sol** = smartest/most expensive, **Terra** = balanced, **Luna** = cheapest. Request both in the delegation prompt as `--model <id> --effort <level>` — the `codex:rescue` wrapper passes both through to the Codex CLI (effort values: `none|minimal|low|medium|high|xhigh`).

Prefer the latest version (5.6); drop to the 5.5/5.4 same-tier equivalent only if the 5.6 variant is unavailable or rate-limited.

Tier rubric:
- **Luna + `--effort low`** (`gpt-5.6-luna`; fallback `gpt-5.4-mini` or `gpt-5.3-codex-spark`): single-file reads/lookups, git status/diff/log checks, mechanical one-file edits, running a command and reporting output, simple "did the fix apply?" verification. Use `--effort minimal` for pure lookups with no judgment.
- **Terra + `--effort medium`** (`gpt-5.6-terra`; fallback `gpt-5.5`, then `gpt-5.4`) — default: standard feature implementation, multi-file edits, writing/fixing tests, ordinary debugging, codebase exploration and summarization.
- **Sol + `--effort high`** (`gpt-5.6-sol`; fallback `gpt-5.5 --effort high`): deep root-cause investigation across subsystems, architecture-heavy implementation, large refactors, gnarly concurrency/security/correctness problems, or a retry after a Terra attempt failed. Reserve `xhigh` for a retry after Sol at `high` failed.

Escalate one step on failure (effort first, then tier) rather than starting at Sol. Omitting the flags uses the `~/.codex/config.toml` defaults (`gpt-5.6-terra`, medium effort).

Example: `Agent(subagent_type="codex:rescue", prompt="--model gpt-5.6-luna --effort low <task>")`

## Delegation Loop (self-qualify → escalate → retry)

Never accept a delegation result unverified. Every delegation runs this loop:

1. **Criteria in the prompt.** End every delegation prompt with an `Acceptance criteria:` list of observable checks (tests pass, file contains X, command output shows Y) plus: "End your report with a self-check: each criterion marked PASS/FAIL with one line of evidence (actual command output or file content, not assertion). If any FAIL, state exactly what failed and why."
2. **Qualify the result.** Claude counts a criterion as PASS only when the evidence backs it. Any FAIL, missing/asserted-only evidence, or an empty/aborted result = failed attempt.
3. **Escalate and retry.** Re-delegate with the failure appended ("attempt at <model/effort> failed: <what/why>"), one step up per retry: effort first (low→medium→high), then tier (Luna→Terra→Sol). Add `--resume` to keep Codex's session context when staying on the same model; go fresh when switching tiers.
4. **Stop rule.** Max 4 attempts (e.g. Luna/low → Terra/medium → Sol/high → Sol/xhigh). If the last attempt still fails, run ONE cross-track rescue (Claude track, Opus) with the full failure trail, then stop and report the attempt trail and blocking failure to the user — do not keep burning tokens.

**When in doubt, delegate. Claude orchestrates and synthesizes only — Codex does all file I/O.**

# Claude Track (when Claude executes instead of Codex)

Used when: the task is git/PR/tracker orchestration, Codex is rate-limited or not installed at all (Claude-only machines: this track IS the system — everything else still applies), or as the one cross-track rescue. Same rubric as the Codex track, Claude tiers via the Agent tool `model` param:
- **Haiku** = Luna-equivalent: lookups, mechanical checks, running a command and reporting output.
- **Sonnet** = Terra-equivalent (default): standard implementation, tests, reviews, exploration.
- **Opus** = Sol-equivalent: deep investigation, architecture-heavy work, cross-track rescue attempts.

Same loop as the Codex track: acceptance criteria in the prompt → executor self-checks with evidence → reflect → escalate Haiku→Sonnet→Opus, max 4 attempts → one cross-track rescue (Codex Sol, only if the Codex CLI is installed and usable; otherwise skip) → halt with the attempt trail.

**Single-loop rule:** exactly one self-check loop per unit of work, owned by the executor. Delegated to Codex → Codex runs the loop and Claude only gates the returned evidence (no second local loop). Claude-executed → Claude runs the loop.

# Pipeline (auto for every implementation task)

Stages: **planner → developer → tester → code reviewer → functional reviewer → push**. Claude-track role prompts live in `~/.claude/agents/pipeline-*.md`; on the Codex track the same stage contract is embedded in the codex:rescue prompt. Each stage runs at its rubric tier on whichever track executes it.

- **Skip logic:** trivial tasks (docs-only, one-line fixes) skip to developer → tester → push. Plain questions/research skip the pipeline entirely — just answer with evidence. An explicit `/task` invocation overrides the skip: all five stages run regardless of size.
- **Contract:** the planner's per-stage acceptance criteria are the single definition of done; every gate is judged against them with evidence. No stage invents its own criteria.
- **Reviewer independence:** code review runs on the opposite track from the developer (Codex dev → Claude reviewer; Claude dev → `codex review`).
- **Functional review depth** (planner sets it from blast radius): large/complex or wide blast radius → run the affected flow + regression tests; large but simple → diff + reasoning; small fix → diff-only.
- **Failure routing:** tester/review failures return to the developer with findings attached (max 2 bounces per gate); a "plan misread the ask" finding returns to the planner. Attempt caps per the track loops.
- **All gates green → auto-push:** commit, then write the green marker — `git rev-parse HEAD > "$(git rev-parse --git-dir)/AGENTIC_GREEN"` — then push and open the PR (tracker reference in title + body — Jira key when connected, else plandb task id / backlog item; base branch per project rules). A pre-push hook blocks any `git push` whose HEAD lacks the marker; write it only after gates actually passed (non-pipeline pushes: after your own verification). Push/PR/tracker mechanics always run in main Claude, never Codex.

# Decision Advisors & Decision Log

**Advisors:** when a decision point arises (architecture choice, scope call, sequencing, customer impact), consult the `decision-advisor` agent with the relevant persona(s): Architect, Senior/Junior Developer, Product Manager, Engineering Manager, Delivery Manager, CSM. Use it for real forks in the road, not routine calls the rubric already answers. Its output is always Options + Recommendation; decisions that are the owner's per the Involvement Rule go to him WITH that recommendation attached.

**Decision log — every decision gets logged, immediately when made.** Location: `~/.claude/decisions/<project>.md` (e.g. `example-project.md`), append-only. One line per decision:

`| YYYY-MM-DD | D-<n> | <decision> | <decided by: the owner / persona / rubric> | <why, one line> | <ticket/PR/link> |`

Rules:
1. Log: product/technical/functional decisions, approval outcomes, plan pivots, escalation halts, advisor consultations, and anything the owner decides in chat.
2. BEFORE asking the owner to decide something, grep the log — if it's already decided, apply it and cite the D-id instead of re-asking.
3. Cite D-ids in plans and PR descriptions when a decision shaped the change.
4. Superseded decisions get a new entry referencing the old id (`supersedes D-x`) — never edit old lines.
5. **Work log (daily digest):** same file, a `## Work Log` section above Decided. Every completed unit of work appends one line — `| YYYY-MM-DD | what shipped / halted / parked | PR link or attempt trail | track/model |` — including cron-run state notes. The session-start hook surfaces the last 2 days of work-log lines together with the pending queue, so every check-in reads as: what got done, what needs deciding. Nothing waits for the digest — it's assembled continuously.
6. **Confluence mirror (when the Atlassian MCP is connected):** maintain a "Decision Log — <project>" Confluence page in the project's space and append new D-entries to it when logging them (batch-appending at session end is fine). The LOCAL file stays canonical — on any conflict the file wins; if Confluence is unreachable, log locally and mirror next session. Never let mirroring block or delay actual work.

# Involvement Rule

Interrupt the owner ONLY for: genuine manual steps, product decisions, and technical/functional calls Claude cannot make alone. PLUS always stop — even on green gates — before: (a) DB migrations / schema / RLS changes, (b) destructive git or file deletion beyond the task's obvious scope, (c) deploy/prod config (render.yaml, workflows, env vars). When stopping, present a recommendation with options, never an open-ended question. Everything else: proceed and deliver only pro-qualified outcomes.

# Off-Hands Mode (DEFAULT)

the owner may be away. Operate fully autonomously; only Involvement Rule items become decision requests — and even those never block the session:

- **Decision parking.** When a owner-only decision arises mid-work: (1) add it to the Pending Decisions queue (`## Pending Decisions` section at the top of `~/.claude/decisions/<project>.md`) as `| date | P-<n> | decision needed | options | recommendation | what it blocks |` — advisor-prepared recommendation where the fork is non-trivial; (2) keep doing ALL work not gated on it; gated work pauses with enough state noted to resume cleanly. Never idle the whole session on one open decision.
- **Check-in protocol.** Whenever the owner shows up and the queue is non-empty, present it FIRST — numbered, each item: what's needed, options, recommendation, what it unblocks. As he decides, move each item out of pending into the decision log with a D-id (`resolves P-n`), then resume the unblocked work in the same session.
- **Proactive personas (opportunistic by default).** While doing real work: the PM persona may propose new features/designs it spots from the code, users' flows, or research; the Architect may propose structural or role-specific needs. Every proposal → a tracker item immediately (persistence): a Jira ticket when the Atlassian MCP is connected — title prefixed `[Proposal]`, status per project workflow, epic-linked per Jira rules (propose an epic if none fits) — else a plandb task or `BACKLOG.md` entry marked `[Proposal]`; PLUS a P-entry in the queue pointing at it. Approved → normal flow; declined → close the ticket with the reason, log the D-entry. Scheduled proposal runs (cron, while away) only for projects where the owner explicitly asks.
- Proposals are seasoning, not the meal: never let persona proposals delay the actual task at hand.

# Autonomous Scheduling — canonical onboarding only

Setting up a project for scheduled autonomous development is ONE step: `onboard-autodev.sh <repo-dir> [slug] [minute]` adds a single crontab line calling the shared runner (`~/.codex/automations/autodev-runner.sh`) against the REAL checkout, using the shared token (`~/.codex/secrets/github.env`), with a lock + 100-min watchdog built in.

**NEVER hand-roll automation.** When asked to "set up autonomous dev / a cron / autopilot" for a project, run the canonical onboarding — do NOT author a per-project wrapper script, a per-project clone, a per-project token file, or bespoke lint/lock logic. Every one of those is a triage liability (one project's self-authored `~/.example-autopilot/` wrapper hung on an un-timeouted lint and failed auth on its own token file, while shared-runner projects ran clean). The shared runner already handles isolation (its own dedicated clone, always reset clean at the `staging` tip — so it never collides with your dirty dev checkout), shared auth, a lock, a 100-min watchdog, and the staging-base / never-main policy. If it needs a capability it lacks, extend the ONE shared runner in the repo — never fork per project. Onboarding is identical on any machine; no session should ever invent its own.

# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"` before doing anything else.

# Ruflo Integration (auto-generated by ruflo init)
When working on multi-file tasks or complex features, use ToolSearch to find and invoke ruflo MCP tools.
Key tools: memory_store, memory_search, hooks_route, swarm_init, agent_spawn.
Check system-reminder tags for [INTELLIGENCE] pattern suggestions before starting work.
