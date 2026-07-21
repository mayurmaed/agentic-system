---
description: Take a Jira ticket end-to-end through the agentic pipeline to a PR
argument-hint: <TICKET-KEY, e.g. PROJ-123>
---

Complete Jira ticket $ARGUMENTS end-to-end. Off-Hands rules apply: queue owner-only decisions with recommendations and keep going on what's unblocked.

1. **Fetch & stage.** Read the ticket via the Atlassian MCP (summary, description, comments, linked issues). Grep the decision log for D-ids that touch this area. Transition the ticket to In Progress per the project's Jira status workflow.
2. **Pipeline.** Run the full flow — planner → developer → tester → code reviewer → functional reviewer — with the ticket text as the original ask. The planner's contract must cover every acceptance criterion stated or implied in the ticket; if the ticket is ambiguous on a product point, park a P-entry with a recommendation and implement the recommended reading (note it in the PR).
3. **Ship.** On green gates: branch per project convention, commit, write the green marker, push, open the PR with the ticket key in title + body, base branch per project rules. Transition the ticket to Review (or the project's equivalent). Cite relevant D-ids in the PR description.
4. **Close the loop.** Log any decisions made, comment the PR link on the ticket, and report: what shipped, evidence summary, anything parked in the queue.

If a gate cannot go green within the attempt caps, stop per the loop rules: leave the ticket In Progress, log the attempt trail, park the blocker as a P-entry, and report.

**No Atlassian?** Treat $ARGUMENTS as a `plandb` task id (claim with `plandb go`, complete with `plandb done`) or a `BACKLOG.md` item heading. Skip the Jira transitions/comments; everything else — pipeline, gates, PR with the item referenced in title + body — runs identically.
