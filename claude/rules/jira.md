# Jira Rules (all projects)

## Status workflow
Before creating, moving, or referencing a Jira ticket's status, check the project's Jira status workflow (statuses and their order). A project-level workflow defined in the project itself (project memory, CLAUDE.md/AGENTS.md, or repo docs) supersedes any default or remembered workflow. Only fall back to the remembered/default workflow when the project defines none.

## Ticket number on every PR
Every PR must reference its Jira ticket key.

- Put the ticket key at the start of the PR title (e.g. `PROJ-123: ...`) and repeat it in the body (a `Jira: PROJ-123` line or the full issue URL) so Jira's GitHub integration auto-links it.
- If no relevant ticket exists, **ask** whether to create one before opening the PR. First search for related/existing tickets and offer them as options; only create a new ticket if none fit.

## Epic linkage
Every ticket must belong to an epic.

- Link the ticket to an existing epic where it fits.
- If no suitable epic exists, propose creating one — grouped with other similar tickets/epics it belongs with — rather than leaving it epic-less.
