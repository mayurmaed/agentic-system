# Automations Dashboard

One static HTML page showing every autodev / autodev-cron automation on this machine: cron schedule, last run status, tokens, and each project's pending/decided decision-log entries.

- Generate: `python3 dashboard/generate.py` (writes `dashboard/index.html`, gitignored — it contains machine-local data)
- Keep fresh: add a cron line, e.g. `*/15 * * * * python3 ~/.codex/automations/dashboard/generate.py`
- Install: copy `generate.py` to `~/.codex/automations/dashboard/` on each machine (one dashboard per machine covers all projects — automations are discovered automatically)

No server, no dependencies (Python 3 stdlib only).
