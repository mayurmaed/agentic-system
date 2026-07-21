# Contributing

Thanks for improving the agentic-system template. This repository contains the source material installed onto a developer's Mac; keep changes explicit, portable within macOS, and safe for unattended automation.

## Local setup

Prerequisites are macOS, Python 3, the GitHub CLI (`gh`), and at least one of Claude Code or the Codex CLI — the system runs on either alone, or both together (the dual-track setup additionally uses Claude's Codex connector plugin). Clone the repository, then install the Claude track:

```bash
git clone https://github.com/mayurmaed/agentic-system-template.git
cd agentic-system-template
./install.sh
```

`install.sh` asks before it writes to `~/.claude`; use `./install.sh --yes` only when that is intentional. To install just the Codex track, run `./install-codex.sh`; it writes the marked instructions block to `~/.codex/AGENTS.md`, installs prompts, and copies the shared automation scripts. To schedule a project after installing the Codex track, use the canonical onboarding command:

```bash
./onboard-autodev.sh /absolute/path/to/repo [slug] [minute 0-29] [--hook]
```

That command changes the user's crontab and requires `~/.codex/secrets/github.env` with a `GH_TOKEN` that can push to the target repository. Do not use it for routine template edits unless you intend to create that automation.

## Repository layout

- `claude/` contains the Claude Code instructions, role agents, slash commands, and standing rules copied by `install.sh`.
- `codex/` contains the Codex `AGENTS.agentic.md` block and the custom prompts copied by `install-codex.sh`.
- `scripts/` contains the shared unattended runner (`autodev-runner.sh`), pending-decision issue sync, and per-repository pre-push hook installer.
- `hooks/` contains Claude hook programs. `agentic-push-gate.sh` and its Python parser fail closed when a push lacks the `AGENTIC_GREEN` marker; `agentic-pending-decisions.sh` supplies decision context at session start.
- `dashboard/` contains `generate.py`, a dependency-free static HTML dashboard generator for the automation state under `~/.codex/automations` and `~/.claude/decisions`.

## Testing changes

There is no automated test suite in this repository. Validate the changed surface directly:

```bash
# Parse every Python source file without executing it.
python3 -m py_compile dashboard/generate.py hooks/agentic-push-gate.py

# Generate the static dashboard, then inspect dashboard/index.html in a browser.
python3 dashboard/generate.py

# If ShellCheck is installed, lint the shell sources (same bar as CI).
shellcheck --severity=warning $(find . -type f -name '*.sh' -not -path './.git/*' -print)
```

For installer changes, read the confirmation output first and test against temporary `CLAUDE_DIR` or `CODEX_DIR` locations where practical; do not point the runner or onboarding at a checkout you need to preserve. For hook changes, test both a green-marker push path and the expected fail-closed path in a disposable repository.

## Conventions and pull requests

Shell files currently use `#!/bin/bash`, but their failure settings are intentionally mixed: installers and onboarding use `set -e`, while the runner and pending-issue sync use `set -u`. Preserve that behavior unless a focused change justifies changing it; do not claim the repository uniformly uses `set -euo pipefail`.

Existing commits use concise imperative summaries such as `docs: add mode example prompts`, `feat: update dashboard generator to final iteration`, and `Sync: canonical autonomous scheduling`. Follow that style: a scoped lower-case prefix where useful, followed by a short concrete summary.

Keep pull requests narrow, explain any install-time or cron-side effect, and include the manual commands and outcomes used to validate the change. Avoid adding per-project automation wrappers, clones, or token files: `scripts/autodev-runner.sh` is the shared supported runner. Changes that affect autonomous commands, token handling, generated prompts, hooks, or `git push` behavior need especially clear safety notes.

## Platform scope

This template is macOS-only. The automation uses `caffeinate`, `osascript`, and Homebrew locations such as `/opt/homebrew/bin` and `/usr/local/bin`; Linux and Windows support should not be implied by documentation or CI linting.
