Complete tracker item $ARGUMENTS end-to-end (Codex track — see the Agentic System section of AGENTS.md). Off-hands rules apply.

1. Resolve the item: Jira ticket (if available), plandb task id (`plandb go`), or BACKLOG.md heading. Read it fully; grep the decision log for related D-ids. Mark it in progress in its tracker.
2. Run the full pipeline with the item text as the original ask; ambiguous product points → park a P-entry with a recommendation and implement the recommended reading (note it in the PR).
3. On green: branch per project convention, commit, write the AGENTIC_GREEN marker, push, open the PR with the item referenced in title + body, move the item to review/done per its tracker.
4. Log decisions, link the PR on the item, report what shipped with evidence.

If a gate cannot go green within the caps: leave the item in progress, log the attempt trail, park the blocker, report.
