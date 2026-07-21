#!/usr/bin/env python3
"""Static dashboard for all autodev / autodev-cron automations across projects.

Reads: crontab (schedule + which automations are live), each automation's
state dir under ~/.codex/automations/ (RUN_LOG.md, last-message.md,
prompt.md, decisions-slug) for live status, and each project's decision log
under ~/.claude/decisions/<slug>.md for Pending Decisions + recent Decided
entries. Writes one self-contained HTML file with a tab per project.

Regenerate: run this script (cron does this every 15 min). No server, no deps.
"""
import html
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
AUTOMATIONS = HOME / ".codex/automations"
DECISIONS = HOME / ".claude/decisions"
SCHEDULED = HOME / ".claude/scheduled-tasks"
OUT = Path(__file__).parent / "index.html"

CRON_LINE_RE = re.compile(r"^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$")
SLUG_FROM_CMD_RE = re.compile(r"autodev-runner\.sh\s+\"([^\"]+)\"\s+(\S+)")
COMMENT_RE = re.compile(r"#\s*(.*)$")
RUN_RE = re.compile(r"^## Run (\S+ \S+)(?:\s+—\s+\S+)?(?:\s+\(model=(\S+)\s+effort=(\S+)\))?", re.M)
END_RE = re.compile(r"^## End (\S+ \S+) \(exit (-?\d+)\)", re.M)
TOKENS_RE = re.compile(r"^tokens used\s*\n\s*([\d,]+)\s*$", re.M)


def get_crontab_lines():
    try:
        out = subprocess.run(["crontab", "-l"], capture_output=True, text=True, check=True).stdout
    except Exception:
        return []
    return [l.strip() for l in out.splitlines() if l.strip() and not l.strip().startswith("#")]


def parse_cron_automations():
    """Returns list of dicts: schedule, repo_path, slug, comment."""
    entries = []
    for line in get_crontab_lines():
        m = CRON_LINE_RE.match(line)
        if not m:
            continue
        schedule, rest = m.groups()
        cm = SLUG_FROM_CMD_RE.search(rest)
        if not cm:
            continue
        repo_path, slug = cm.groups()
        comment_m = COMMENT_RE.search(rest)
        comment = comment_m.group(1).strip() if comment_m else ""
        entries.append({
            "schedule": schedule,
            "repo_path": repo_path,
            "slug": slug,
            "comment": comment,
        })
    return entries


def parse_all_runs(state_dir):
    """Returns every run recorded in RUN_LOG.md(.1), newest first: start, model, effort,
    end, exit_code, duration_s, tokens, outcome (prefers the archived per-run message file
    over raw log-tail text, since last-message.md only ever holds the single latest run)."""
    chunks = []
    for name in ("RUN_LOG.md.1", "RUN_LOG.md"):  # older rotated file first -> chronological
        f = state_dir / name
        if f.exists():
            try:
                chunks.append(f.read_text(errors="replace"))
            except Exception:
                pass
    text = "\n".join(chunks)
    if not text:
        return []

    matches = list(RUN_RE.finditer(text))
    runs = []
    for i, m in enumerate(matches):
        block = text[m.start(): matches[i + 1].start() if i + 1 < len(matches) else len(text)]
        start, model, effort = m.group(1), m.group(2), m.group(3)

        end_m = END_RE.search(block)
        end_time, exit_code = (end_m.group(1), end_m.group(2)) if end_m else (None, None)

        tok_m = TOKENS_RE.search(block)
        tokens = int(tok_m.group(1).replace(",", "")) if tok_m else None

        duration_s = None
        if start and end_time:
            try:
                t0 = datetime.strptime(start, "%Y-%m-%d %H:%M:%S")
                t1 = datetime.strptime(end_time, "%Y-%m-%d %H:%M:%S")
                duration_s = max(0, int((t1 - t0).total_seconds()))
            except ValueError:
                pass

        outcome = ""
        try:
            file_ts = datetime.strptime(start, "%Y-%m-%d %H:%M:%S").strftime("%Y%m%dT%H%M%S")
            archive = state_dir / "runs" / f"{file_ts}.md"
            if archive.exists():
                raw = archive.read_text(errors="replace")
                outcome = re.sub(r"^<!--.*?-->\s*", "", raw, count=1, flags=re.S).strip()
        except ValueError:
            pass
        if not outcome:
            # Pre-archival runs (before this feature existed) only have raw log-tail text.
            tail_lines = [l for l in block.splitlines() if l.strip() and not l.startswith("## ")]
            outcome = "\n".join(tail_lines[-6:])

        runs.append({"start": start, "model": model, "effort": effort, "end": end_time,
                      "exit_code": exit_code, "duration_s": duration_s, "tokens": tokens,
                      "outcome": outcome[:400]})

    runs.reverse()
    return runs


def read_state(slug):
    """Reads an autodev-<slug> state dir: full run history, decisions-slug, type blurb."""
    state_dir = AUTOMATIONS / f"autodev-{slug}"
    info = {"exists": state_dir.is_dir(), "decisions_slug": slug, "type_blurb": "", "runs": [],
            "last_run": None, "last_end": None, "exit_code": None, "outcome": "",
            "model": None, "effort": None, "duration_s": None, "tokens": None}
    if not info["exists"]:
        return info

    ds_file = state_dir / "decisions-slug"
    if ds_file.exists():
        info["decisions_slug"] = ds_file.read_text().strip() or slug

    prompt_file = state_dir / "prompt.md"
    if prompt_file.exists():
        first_line = prompt_file.read_text().strip().splitlines()[0] if prompt_file.stat().st_size else ""
        info["type_blurb"] = first_line[:160]

    runs = parse_all_runs(state_dir)
    info["runs"] = runs
    latest = runs[0] if runs else {}
    info["last_run"] = latest.get("start")
    info["last_end"] = latest.get("end")
    info["exit_code"] = latest.get("exit_code")
    info["model"] = latest.get("model")
    info["effort"] = latest.get("effort")
    info["duration_s"] = latest.get("duration_s")
    info["tokens"] = latest.get("tokens")
    info["outcome"] = latest.get("outcome", "")

    return info


def parse_decisions_file(path):
    """Extracts Pending Decisions rows and the most recent N Decided rows."""
    text = path.read_text(errors="replace")

    def section(name):
        m = re.search(rf"^## {re.escape(name)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
        return m.group(1) if m else ""

    def table_rows(block):
        rows = []
        for line in block.splitlines():
            line = line.strip()
            if not line.startswith("|"):
                continue
            cells = [c.strip() for c in line.strip("|").split("|")]
            if not cells or set("".join(cells)) <= set("-: "):
                continue
            if cells and cells[0].lower() == "date":
                continue
            rows.append(cells)
        return rows

    pending = table_rows(section("Pending Decisions"))
    decided = table_rows(section("Decided"))
    return pending, decided[-8:][::-1]  # most recent 8, newest first


def discover_projects():
    return sorted(p.stem for p in DECISIONS.glob("*.md"))


def discover_scheduled_tasks():
    tasks = []
    if not SCHEDULED.is_dir():
        return tasks
    for d in sorted(SCHEDULED.iterdir()):
        skill = d / "SKILL.md"
        if not skill.exists():
            continue
        text = skill.read_text(errors="replace")
        name_m = re.search(r"^name:\s*(.+)$", text, re.M)
        desc_m = re.search(r"^description:\s*(.+)$", text, re.M)
        tasks.append({
            "name": (name_m.group(1).strip() if name_m else d.name),
            "description": (desc_m.group(1).strip() if desc_m else ""),
        })
    return tasks


def esc(s):
    return html.escape(str(s or ""))


def fmt_duration(seconds):
    if seconds is None:
        return ""
    m, s = divmod(int(seconds), 60)
    return f"{m}m{s:02d}s" if m else f"{s}s"


def fmt_tokens(n):
    if n is None:
        return ""
    if n >= 1000:
        return f"{n/1000:.1f}k"
    return str(n)


def one_line(text, limit=150):
    """First non-empty line of a multi-line outcome, truncated — used for the always-visible
    card preview. Full multi-line text lives in the Run history table instead of a clipped
    block with no indication anything was hidden (that was the original, unreadable version)."""
    for line in (text or "").splitlines():
        line = line.strip().lstrip("-*# ").strip()
        if line:
            return line[:limit] + ("…" if len(line) > limit else "")
    return ""


HISTORY_SHOWN = 30


def render_history(runs):
    if not runs:
        return ""
    shown = runs[:HISTORY_SHOWN]
    rows = ""
    for r in shown:
        exit_class = "ok" if r.get("exit_code") == "0" else ("warn" if r.get("exit_code") is not None else "unknown")
        stats = " · ".join(filter(None, [
            fmt_duration(r.get("duration_s")),
            f'{fmt_tokens(r["tokens"])} tok' if r.get("tokens") is not None else "",
            f'{r["model"]}/{r["effort"]}' if r.get("model") else "",
        ]))
        # Full-width Outcome column now has room to show the whole summary with its line
        # structure preserved (- QA / - Review / - Delivery Readiness bullets) rather than a
        # truncated one-liner. Cap generously so a runaway message can't make one row huge.
        outcome_full = (r.get("outcome") or "").strip()
        outcome_full = outcome_full[:1200] + ("…" if len(outcome_full) > 1200 else "")
        rows += f"""
        <tr>
          <td class="hist-time">{esc(r.get('start'))}</td>
          <td><span class="dot {exit_class}"></span>{esc(r.get('exit_code', '?'))}</td>
          <td class="hist-stats">{esc(stats)}</td>
          <td class="hist-outcome">{esc(outcome_full)}</td>
        </tr>"""
    overflow = ""
    if len(runs) > HISTORY_SHOWN:
        overflow = f'<div class="muted" style="margin-top:6px;">+{len(runs) - HISTORY_SHOWN} older run(s) not shown (retention caps archived messages at 200; raw logs rotate at 500KB).</div>'
    return f"""
    <details class="history">
      <summary>Run history ({len(runs)})</summary>
      <div class="hist-table-wrap">
        <table class="hist-table">
          <thead><tr><th>Started</th><th>Exit</th><th>Stats</th><th>Outcome</th></tr></thead>
          <tbody>{rows}</tbody>
        </table>
      </div>
      {overflow}
    </details>"""


def age_note(ts_str):
    if not ts_str:
        return "never run"
    for fmt in ("%Y-%m-%d %H:%M:%S",):
        try:
            dt = datetime.strptime(ts_str, fmt)
            delta = datetime.now() - dt
            mins = int(delta.total_seconds() // 60)
            if mins < 60:
                return f"{mins}m ago"
            hrs = mins // 60
            if hrs < 48:
                return f"{hrs}h ago"
            return f"{hrs // 24}d ago"
        except ValueError:
            continue
    return ts_str


def build_html():
    cron_entries = parse_cron_automations()
    projects = discover_projects()
    scheduled_tasks = discover_scheduled_tasks()

    # Group cron automations by project (via decisions-slug), independent of decisions-file existing.
    by_project = {p: [] for p in projects}
    unmatched = []
    for entry in cron_entries:
        state = read_state(entry["slug"])
        proj = state["decisions_slug"]
        entry_full = {**entry, **state}
        if proj in by_project:
            by_project[proj].append(entry_full)
        else:
            unmatched.append(entry_full)

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    tabs_html = []
    panels_html = []
    for i, proj in enumerate(projects):
        active = "active" if i == 0 else ""
        tabs_html.append(f'<button class="tab {active}" onclick="showTab(\'{proj}\')" id="tab-{proj}">{esc(proj)}</button>')

        autos = by_project.get(proj, [])
        auto_cards = ""
        if autos:
            for a in autos:
                exit_class = "ok" if a.get("exit_code") == "0" else ("warn" if a.get("exit_code") not in (None,) else "unknown")
                auto_cards += f"""
                <div class="card">
                  <div class="card-head">
                    <span class="slug">{esc(a['slug'])}</span>
                    <span class="schedule">{esc(a['schedule'])}</span>
                  </div>
                  <div class="blurb">{esc(a.get('type_blurb') or a.get('comment'))}</div>
                  <div class="status-row">
                    <span class="dot {exit_class}"></span>
                    <span>last run {esc(age_note(a.get('last_run')))}</span>
                    {f'<span class="exit-code">exit {esc(a["exit_code"])}</span>' if a.get('exit_code') is not None else ''}
                  </div>
                  <div class="stat-row">
                    {f'<span class="stat">{esc(a["model"])} · {esc(a["effort"])}</span>' if a.get('model') else ''}
                    {f'<span class="stat">{esc(fmt_duration(a["duration_s"]))}</span>' if a.get('duration_s') is not None else ''}
                    {f'<span class="stat">{esc(fmt_tokens(a["tokens"]))} tok</span>' if a.get('tokens') is not None else ''}
                  </div>
                  {f'<div class="outcome" title="{esc(a["outcome"])}">{esc(one_line(a["outcome"]))}</div>' if a.get('outcome') else ''}
                  {render_history(a.get('runs', []))}
                </div>"""
        else:
            auto_cards = '<div class="empty">No scheduled Codex-track automations found for this project.</div>'

        decisions_path = DECISIONS / f"{proj}.md"
        pending_rows, decided_rows = ([], [])
        if decisions_path.exists():
            pending_rows, decided_rows = parse_decisions_file(decisions_path)

        pending_html = ""
        if pending_rows:
            for row in pending_rows:
                date = row[0] if len(row) > 0 else ""
                rid = row[1] if len(row) > 1 and len(row[1]) < 20 else ""
                rest = " | ".join(row[2:] if rid else row[1:])
                pending_html += f"""
                <div class="decision-row pending">
                  <div class="decision-meta"><span class="date">{esc(date)}</span>{f'<span class="id-badge">{esc(rid)}</span>' if rid else ''}</div>
                  <div class="decision-text">{esc(rest[:600])}{'…' if len(rest) > 600 else ''}</div>
                </div>"""
        else:
            pending_html = '<div class="empty">No pending decisions.</div>'

        decided_html = ""
        if decided_rows:
            for row in decided_rows:
                date = row[0] if len(row) > 0 else ""
                rid = row[1] if len(row) > 1 and len(row[1]) < 30 else ""
                rest = " | ".join(row[2:] if rid else row[1:])
                decided_html += f"""
                <div class="decision-row decided">
                  <div class="decision-meta"><span class="date">{esc(date)}</span>{f'<span class="id-badge done">{esc(rid)}</span>' if rid else ''}</div>
                  <div class="decision-text">{esc(rest[:600])}{'…' if len(rest) > 600 else ''}</div>
                </div>"""
        else:
            decided_html = '<div class="empty">No decisions logged yet.</div>'

        panels_html.append(f"""
        <div class="panel {active}" id="panel-{proj}">
          <section>
            <h2>Automations</h2>
            <div class="cards">{auto_cards}</div>
          </section>
          <section>
            <h2>Pending Decisions <span class="count">{len(pending_rows)}</span></h2>
            {pending_html}
          </section>
          <section>
            <h2>Recently Decided <span class="count">{len(decided_rows)}</span></h2>
            {decided_html}
          </section>
        </div>""")

    unmatched_html = ""
    if unmatched:
        items = "".join(f"<li><code>{esc(u['slug'])}</code> — {esc(u['comment'])}</li>" for u in unmatched)
        unmatched_html = f'<div class="footnote">Scheduled but no matching project decision log: <ul>{items}</ul></div>'

    scheduled_html = ""
    if scheduled_tasks:
        items = "".join(
            f'<li><strong>{esc(t["name"])}</strong> — {esc(t["description"])} '
            f'<span class="muted">(schedule/last-run not visible to this dashboard — Claude Code manages it internally; check /loop or the scheduled-tasks list in-app)</span></li>'
            for t in scheduled_tasks
        )
        scheduled_html = f'<div class="claude-track"><h3>Claude-track scheduled tasks (best-effort listing)</h3><ul>{items}</ul></div>'

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Autodev Dashboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {{
    --bg: #0b0d10; --panel: #12151a; --border: #23272e; --text: #e6e8eb; --muted: #8a919c;
    --accent: #4f8cff; --ok: #37c26b; --warn: #e0a72e; --unknown: #5b6270;
  }}
  @media (prefers-color-scheme: light) {{
    :root {{ --bg: #f5f6f8; --panel: #ffffff; --border: #e2e4e8; --text: #16181d; --muted: #666d78; }}
  }}
  :root[data-theme="dark"] {{ --bg: #0b0d10; --panel: #12151a; --border: #23272e; --text: #e6e8eb; --muted: #8a919c; }}
  :root[data-theme="light"] {{ --bg: #f5f6f8; --panel: #ffffff; --border: #e2e4e8; --text: #16181d; --muted: #666d78; }}
  * {{ box-sizing: border-box; min-width: 0; }}
  body {{ margin: 0; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
  header {{ padding: 20px 24px 8px; }}
  header h1 {{ margin: 0 0 2px; font-size: 20px; }}
  header .meta {{ color: var(--muted); font-size: 13px; }}
  .tabs {{ display: flex; gap: 4px; padding: 12px 24px 0; flex-wrap: wrap; border-bottom: 1px solid var(--border); }}
  .tab {{ background: none; border: none; color: var(--muted); padding: 8px 16px; font-size: 14px; cursor: pointer; border-radius: 8px 8px 0 0; }}
  .tab.active {{ color: var(--text); background: var(--panel); font-weight: 600; }}
  .panel {{ display: none; padding: 20px 24px 40px; max-width: 1600px; }}
  .panel.active {{ display: block; }}
  section {{ margin-bottom: 28px; }}
  h2 {{ font-size: 15px; margin: 0 0 10px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }}
  h2 .count {{ background: var(--border); color: var(--text); border-radius: 10px; padding: 1px 8px; font-size: 12px; margin-left: 6px; }}
  /* Single-column, full-width cards: each automation's history table then gets the whole
     panel width, so the Outcome column is readable instead of crushed into a narrow strip. */
  .cards {{ display: grid; grid-template-columns: 1fr; gap: 12px; }}
  .card {{ background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; }}
  .card-head {{ display: flex; justify-content: space-between; align-items: baseline; }}
  .slug {{ font-weight: 600; font-size: 14px; }}
  .schedule {{ font-family: ui-monospace, monospace; font-size: 11px; color: var(--muted); }}
  .blurb {{ color: var(--muted); font-size: 12px; margin: 6px 0; line-height: 1.4; overflow-wrap: break-word; }}
  .status-row {{ display: flex; align-items: center; gap: 6px; font-size: 12px; margin-top: 6px; }}
  .stat-row {{ display: flex; gap: 8px; margin-top: 4px; flex-wrap: wrap; }}
  .stat {{ font-size: 11px; color: var(--muted); background: var(--bg); border: 1px solid var(--border); border-radius: 5px; padding: 1px 6px; font-family: ui-monospace, monospace; }}
  .dot {{ width: 8px; height: 8px; border-radius: 50%; display: inline-block; }}
  .dot.ok {{ background: var(--ok); }}
  .dot.warn {{ background: var(--warn); }}
  .dot.unknown {{ background: var(--unknown); }}
  .exit-code {{ color: var(--muted); margin-left: auto; }}
  /* Single-line preview, ellipsis when it doesn't fit — hover for the full text (title attr).
     Previously this was a multi-line block hard-clipped at 80px with NO indication anything
     was hidden, which is what made cards unreadable. Full text lives in Run history below. */
  .outcome {{ margin-top: 8px; font-size: 12px; color: var(--muted); border-top: 1px solid var(--border); padding-top: 6px;
              white-space: nowrap; overflow: hidden; text-overflow: ellipsis; cursor: help; }}
  .history {{ margin-top: 8px; border-top: 1px solid var(--border); padding-top: 6px; }}
  .history summary {{ cursor: pointer; font-size: 11px; color: var(--accent); user-select: none; }}
  .hist-table-wrap {{ overflow-x: auto; }}
  .hist-table {{ width: 100%; table-layout: fixed; border-collapse: collapse; margin-top: 8px; font-size: 11px; }}
  .hist-table th {{ text-align: left; color: var(--muted); font-weight: 500; padding: 3px 6px; border-bottom: 1px solid var(--border); position: sticky; top: 0; background: var(--panel); }}
  .hist-table td {{ padding: 4px 6px; border-bottom: 1px solid var(--border); vertical-align: top; overflow-wrap: break-word; }}
  .hist-table tr:last-child td {{ border-bottom: none; }}
  .hist-table th:nth-child(1), .hist-table td:nth-child(1) {{ width: 150px; }}
  .hist-table th:nth-child(2), .hist-table td:nth-child(2) {{ width: 52px; }}
  .hist-table th:nth-child(3), .hist-table td:nth-child(3) {{ width: 260px; }}
  /* Outcome (4th col) is intentionally left auto so it takes ALL remaining width. */
  .hist-time {{ font-family: ui-monospace, monospace; white-space: nowrap; color: var(--muted); }}
  .hist-table .dot {{ margin-right: 4px; vertical-align: middle; }}
  /* No nowrap here — a long stats string (duration · tokens · model/effort) must wrap inside
     its own cell, never overflow into the Outcome column (that was the visual "overlap" bug). */
  .hist-stats {{ font-family: ui-monospace, monospace; color: var(--muted); overflow-wrap: break-word; }}
  .hist-outcome {{ color: var(--text); overflow-wrap: break-word; white-space: pre-line; }}
  .decision-row {{ border-left: 3px solid var(--border); padding: 6px 0 6px 12px; margin-bottom: 8px; }}
  .decision-row.pending {{ border-left-color: var(--warn); }}
  .decision-row.decided {{ border-left-color: var(--ok); }}
  .decision-meta {{ display: flex; gap: 8px; align-items: center; margin-bottom: 2px; }}
  .date {{ font-size: 11px; color: var(--muted); font-family: ui-monospace, monospace; }}
  .id-badge {{ font-size: 11px; background: var(--border); padding: 1px 6px; border-radius: 6px; }}
  .id-badge.done {{ background: rgba(55,194,107,.18); }}
  .decision-text {{ font-size: 13px; line-height: 1.45; overflow-wrap: break-word; }}
  .empty {{ color: var(--muted); font-size: 13px; font-style: italic; }}
  .footnote {{ color: var(--muted); font-size: 12px; padding: 0 24px 24px; }}
  .claude-track {{ padding: 0 24px 24px; }}
  .claude-track h3 {{ font-size: 13px; color: var(--muted); text-transform: uppercase; }}
  .claude-track ul {{ font-size: 13px; line-height: 1.6; }}
  .muted {{ color: var(--muted); font-size: 11px; }}
</style>
</head>
<body>
<header>
  <h1>Autodev Dashboard</h1>
  <div class="meta">Generated {esc(generated_at)} · regenerate: <code>python3 ~/.codex/automations/dashboard/generate.py</code></div>
</header>
<div class="tabs">{''.join(tabs_html)}</div>
{''.join(panels_html)}
{scheduled_html}
{unmatched_html}
<script>
function showTab(id) {{
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
  document.getElementById('tab-' + id).classList.add('active');
  document.getElementById('panel-' + id).classList.add('active');
}}
</script>
</body>
</html>"""


if __name__ == "__main__":
    OUT.write_text(build_html())
    print(f"wrote {OUT}")
