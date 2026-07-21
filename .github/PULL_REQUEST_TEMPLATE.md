## Description

Explain the problem and the intended outcome. Call out any change to installed files, hooks, cron behavior, token use, `git push`, or autonomous agent permissions.

## What changed

- 

## How it was tested

This repository has no automated test suite. List the manual commands you ran and their results. For shell changes, include ShellCheck output if available; for Python changes, include `python3 -m py_compile ...`; for dashboard changes, say whether you generated and inspected `dashboard/index.html`.

## Checklist

- [ ] The change is scoped to the Claude track, Codex track, shared scripts/hooks, dashboard, or documentation described above.
- [ ] I preserved the macOS-only assumptions (`caffeinate`, `osascript`, and Homebrew paths) or documented a deliberate change.
- [ ] I did not add a per-project runner, clone, or token file.
- [ ] I described any destructive, cron, hook, authentication, commit, push, or PR side effect.
- [ ] I updated documentation and prompts where the installed behavior changes.
- [ ] I did not include tokens, decision logs, machine-local automation state, or other secrets.
