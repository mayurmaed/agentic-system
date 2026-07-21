# Mode example prompts

An automation's "mode" is nothing but its `prompt.md`. The runner (`autodev-runner.sh`) and cron line never change — to scope an automation to a kind of work, copy an example into its state dir and fill the `<PLACEHOLDERS>`:

```bash
cp examples/prompts/bug.md ~/.codex/automations/autodev-<slug>/prompt.md
```

- `bug.md` — bug-resolution-only lane (distilled from a production bug lane that runs every 10 minutes).
- `fe.md` — frontend maintenance lane: visual fixes and polish with mandatory in-browser verification and a hard no-unilateral-redesign guardrail.

Cadence is orthogonal: whatever crontab schedule you give the automation applies to any mode. A generic do-everything lane needs no template — that's the default prompt you already write at onboarding.
