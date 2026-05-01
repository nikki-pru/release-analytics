"""
apps/triage/render_html.py

Render a triage run bundle as a single self-contained HTML report.
Reads run.yml, diff_list.csv, and results.json from a runs/r_<id>/
bundle and writes report.html alongside them.

Style modeled on sandro-test-analyzer's analysis-*.html: a sticky-header
table of every classified case up top, expanded detail sections below.
BUG / NEEDS_REVIEW rows render individually; FALSE_POSITIVE and
AUTO_CLASSIFIED rows that share a reason fingerprint are consolidated
into one detail block per cluster (so 200 identical compile failures
collapse to one section).

Usage:
    python3 -m apps.triage.render_html runs/r_<id>
"""

import argparse
import html
import json
from collections import OrderedDict, defaultdict
from pathlib import Path

import pandas as pd
import yaml

from apps.triage.prepare import (
    _testray_fetch_paginated,
    _testray_oauth_token,
    load_config,
)


_VERDICT_CLASS = {
    "BUG":             "bug",
    "NEEDS_REVIEW":    "needs",
    "FALSE_POSITIVE":  "fp",
    "AUTO_CLASSIFIED": "auto",
}

_CSS = """
  :root {
    --c-bug: #c0392b;
    --c-needs: #d68910;
    --c-fp: #5d6d7e;
    --c-auto: #7f8c8d;
    --c-bg: #fdfdfd;
    --c-fg: #1c1c1c;
    --c-muted: #5a6772;
    --c-border: #e1e4e8;
    --c-row: #f6f8fa;
    --c-code-bg: #eef1f4;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0; padding: 0;
    background: var(--c-bg); color: var(--c-fg);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
  }
  main { max-width: 1180px; margin: 0 auto; padding: 32px 28px 80px; }
  h1 { margin: 0 0 4px; font-size: 26px; }
  .summary {
    color: var(--c-muted);
    font-size: 14px;
    margin-bottom: 20px;
    padding-bottom: 14px;
    border-bottom: 1px solid var(--c-border);
  }
  h2 {
    margin: 36px 0 14px;
    font-size: 20px;
    border-bottom: 1px solid var(--c-border);
    padding-bottom: 6px;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 13px;
    table-layout: fixed;
  }
  thead th {
    position: sticky; top: 0;
    background: #f0f3f6;
    text-align: left;
    padding: 10px;
    border-bottom: 2px solid var(--c-border);
    font-weight: 600;
  }
  thead th:nth-child(1) { width: 40px; }
  thead th:nth-child(2) { width: 24%; }
  thead th:nth-child(3) { width: 14%; }
  thead th:nth-child(4) { width: 12%; }
  thead th:nth-child(5) { width: 11%; }
  thead th:nth-child(6) { width: 9%; }
  thead th:nth-child(7) { width: auto; }
  tbody td {
    padding: 10px;
    border-bottom: 1px solid var(--c-border);
    vertical-align: top;
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  tbody tr:nth-child(even) td { background: var(--c-row); }
  td.col-num { color: var(--c-muted); }
  td code, dd code, section.detail code {
    overflow-wrap: anywhere;
    word-break: break-word;
    white-space: normal;
  }
  .verdict {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 10px;
    font-size: 12px;
    font-weight: 600;
    color: white;
    white-space: nowrap;
  }
  .verdict.bug { background: var(--c-bug); }
  .verdict.needs { background: var(--c-needs); }
  .verdict.fp { background: var(--c-fp); }
  .verdict.auto { background: var(--c-auto); }
  .conf {
    display: inline-block;
    font-size: 12px;
    color: var(--c-muted);
    text-transform: lowercase;
  }
  .conf.high { color: #1e8449; font-weight: 600; }
  .conf.medium { color: #b9770e; font-weight: 600; }
  .conf.low { color: #7d3c98; }
  .status {
    display: inline-block;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 11px;
    color: var(--c-muted);
  }
  .status .arrow { color: var(--c-muted); margin: 0 3px; }
  .status .failed { color: var(--c-bug); font-weight: 600; }
  .status .passed { color: #1e8449; }
  .status .untested { color: var(--c-needs); }
  .status .blocked { color: var(--c-needs); }
  code {
    background: var(--c-code-bg);
    padding: 1px 5px;
    border-radius: 3px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 0.92em;
  }
  section.detail {
    margin: 22px 0;
    padding: 16px 18px;
    background: var(--c-row);
    border-left: 3px solid var(--c-border);
    border-radius: 4px;
  }
  section.detail.bug { border-left-color: var(--c-bug); }
  section.detail.needs { border-left-color: var(--c-needs); }
  section.detail.fp { border-left-color: var(--c-fp); }
  section.detail.auto { border-left-color: var(--c-auto); }
  section.detail h3 {
    margin: 0 0 10px;
    font-size: 15px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    word-break: break-all;
  }
  section.detail dl {
    margin: 0;
    display: grid;
    grid-template-columns: 130px minmax(0, 1fr);
    gap: 6px 14px;
  }
  section.detail dt { font-weight: 600; color: var(--c-muted); font-size: 13px; }
  section.detail dd { margin: 0; font-size: 13px; min-width: 0; overflow-wrap: anywhere; word-break: break-word; }
  section.detail ul { margin: 4px 0; padding-left: 18px; }
  section.detail li { margin-bottom: 3px; overflow-wrap: anywhere; word-break: break-word; }
  pre.error { white-space: pre-wrap; margin: 0; font-size: 12px; }
  .totals {
    display: flex;
    gap: 16px;
    flex-wrap: wrap;
    margin: 0 0 14px;
    padding: 12px 14px;
    background: var(--c-row);
    border-radius: 4px;
    border: 1px solid var(--c-border);
  }
  .totals .pill {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    font-size: 13px;
  }
  .totals .pill .n { font-weight: 700; font-size: 16px; }
  thead th { cursor: pointer; user-select: none; }
  thead th .sort-ind { color: var(--c-muted); font-size: 11px; margin-left: 4px; }
  thead th.sorted .sort-ind { color: var(--c-fg); }
  section.rationale {
    margin: 14px 0 8px;
    padding: 14px 18px;
    background: #fff8e7;
    border-left: 3px solid var(--c-needs);
    border-radius: 4px;
    font-size: 13.5px;
  }
  section.rationale h2 {
    margin: 0 0 8px;
    font-size: 15px;
    border: none;
    padding: 0;
  }
  section.rationale ol { margin: 6px 0 0; padding-left: 22px; }
  section.rationale li { margin-bottom: 5px; }
"""

_RATIONALE_HTML = """
<section class="rationale">
  <h2>Why 0 BUGs? — conservative classification, not "no bugs exist"</h2>
  <ol>
    <li><strong>BUG gate is strict.</strong> Requires <em>high</em>
        confidence + a named <code>culprit_file</code> + a hunk clearly
        causing the failure. A plausible theory at medium confidence is
        NEEDS_REVIEW.</li>
    <li><strong>Multi-cause rule fires on most failures.</strong> When 2+
        ticket clusters in the diff plausibly affect a failing test
        (common in multi-week build pairs with shared-UI churn),
        classification is forced to NEEDS_REVIEW even at high confidence
        — the human reviewer disambiguates rather than the model locking
        in a single theory.</li>
    <li><strong>Session-budget triage.</strong> Per-case source-file
        tracing across hundreds of failures and a multi-MB diff isn't
        feasible in one pass. NEEDS_REVIEW is the safe default; clusters
        worth a human look are surfaced in the table and details below.</li>
  </ol>
</section>
"""

_SORT_JS = """
(function () {
  function cellKey(td) {
    var t = (td.textContent || '').trim();
    var n = Number(t.replace(/,/g, ''));
    return Number.isFinite(n) && t !== '' ? [0, n] : [1, t.toLowerCase()];
  }
  function cmp(a, b) {
    if (a[0] !== b[0]) return a[0] - b[0];
    if (a[1] < b[1]) return -1;
    if (a[1] > b[1]) return 1;
    return 0;
  }
  document.querySelectorAll('table').forEach(function (table) {
    var ths = table.querySelectorAll('thead th');
    ths.forEach(function (th, idx) {
      var ind = document.createElement('span');
      ind.className = 'sort-ind';
      ind.textContent = '↕';
      th.appendChild(ind);
      th.addEventListener('click', function () {
        var tbody = table.querySelector('tbody');
        var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
        var asc = !th.classList.contains('asc');
        ths.forEach(function (h) {
          h.classList.remove('sorted', 'asc', 'desc');
          h.querySelector('.sort-ind').textContent = '↕';
        });
        th.classList.add('sorted', asc ? 'asc' : 'desc');
        ind.textContent = asc ? '▲' : '▼';
        rows.sort(function (r1, r2) {
          var k1 = cellKey(r1.children[idx]);
          var k2 = cellKey(r2.children[idx]);
          return asc ? cmp(k1, k2) : cmp(k2, k1);
        });
        rows.forEach(function (r) { tbody.appendChild(r); });
      });
    });
  });
})();
"""


def _esc(s) -> str:
    if s is None:
        return ""
    if isinstance(s, float) and pd.isna(s):
        return ""
    return html.escape(str(s))


def _status_class(s: str) -> str:
    s = (s or "").lower()
    if s in ("failed", "passed", "untested", "blocked"):
        return s
    return ""


def _status_pair(a, b) -> str:
    a_s = _esc(a) or "—"
    b_s = _esc(b) or "—"
    return (
        f'<span class="status">'
        f'<span class="{_status_class(a_s)}">{a_s}</span>'
        f'<span class="arrow">→</span>'
        f'<span class="{_status_class(b_s)}">{b_s}</span>'
        f'</span>'
    )


def _build_rows(diff_list: pd.DataFrame, results: list[dict]) -> list[dict]:
    """Merge diff_list with results.json into one render row per case.

    Mirrors submit.assemble_dataframe's logic, but emits a flat dict per row
    (rather than the wider DB-bound DataFrame) and keeps confidence + culprit
    explicit so the renderer can show them. Flaky rows are dropped.
    """
    by_id = {int(r["testray_case_id"]): r for r in results
             if isinstance(r.get("testray_case_id"), int)}

    rows: list[dict] = []
    for _, row in diff_list.iterrows():
        if bool(row.get("known_flaky")):
            continue
        cid = int(row["testray_case_id"])
        pre = row.get("pre_classification")
        if pd.notna(pre) and pre:
            verdict, conf = "AUTO_CLASSIFIED", "auto"
            culprit, specific = None, None
            reason = f"pre_classification={pre}"
        else:
            r = by_id.get(cid)
            if not r:
                verdict, conf = "NEEDS_REVIEW", "low"
                culprit, specific = None, None
                reason = "No entry in results.json — defaulted to NEEDS_REVIEW"
            else:
                verdict = r["classification"]
                conf = r["confidence"]
                culprit = r.get("culprit_file")
                specific = r.get("specific_change")
                reason = r["reason"]

        rows.append({
            "case_id":         cid,
            "test_case":       row.get("test_case") or "",
            "component_name":  row.get("component_name") or "",
            "team_name":       row.get("team_name") or "",
            "status_a":        row.get("status_a") or "",
            "status_b":        row.get("status_b") or "",
            "error_message":   row.get("error_message") or "",
            "linked_issues":   row.get("linked_issues") or "",
            "verdict":         verdict,
            "confidence":      conf,
            "culprit_file":    culprit,
            "specific_change": specific,
            "reason":          reason,
        })
    return rows


def _summary_text(specific, culprit) -> str:
    parts = []
    if culprit:
        parts.append(f'<code>{_esc(culprit)}</code>')
    if specific:
        s = str(specific)
        if len(s) > 240:
            s = s[:237] + "…"
        parts.append(_esc(s))
    return "<br>".join(parts) if parts else "—"


def _render_table(rows: list[dict]) -> str:
    out = ['<table>',
           '<thead><tr>',
           '<th>#</th><th>Test</th><th>Component / Team</th>'
           '<th>Status</th><th>Verdict</th><th>Confidence</th>'
           '<th>Specific change</th>',
           '</tr></thead>',
           '<tbody>']
    for i, r in enumerate(rows, 1):
        vclass = _VERDICT_CLASS[r["verdict"]]
        comp = _esc(r["component_name"])
        team = _esc(r["team_name"])
        ct = comp + (
            f" <span style='color:var(--c-muted);'>· {team}</span>" if team else ""
        )
        if not ct.strip():
            ct = "—"
        conf_class = r["confidence"] if r["confidence"] in ("high", "medium", "low") else ""
        out.append(
            f'<tr id="case-{r["case_id"]}">'
            f'<td class="col-num">{i}</td>'
            f'<td>{_esc(r["test_case"])}</td>'
            f'<td>{ct}</td>'
            f'<td>{_status_pair(r["status_a"], r["status_b"])}</td>'
            f'<td><span class="verdict {vclass}">{_esc(r["verdict"])}</span></td>'
            f'<td><span class="conf {conf_class}">{_esc(r["confidence"])}</span></td>'
            f'<td>{_summary_text(r["specific_change"], r["culprit_file"])}</td>'
            f'</tr>'
        )
    out.append('</tbody></table>')
    return "\n".join(out)


def _detail_dl(items: list[tuple[str, str]]) -> str:
    return "<dl>" + "".join(
        f"<dt>{_esc(k)}</dt><dd>{v}</dd>" for k, v in items if v
    ) + "</dl>"


def _err_html(err) -> str:
    if not err or (isinstance(err, float) and pd.isna(err)):
        return ""
    err = str(err)
    if len(err) > 1200:
        err = err[:1200] + "…"
    return f'<pre class="error">{_esc(err)}</pre>'


def _render_individual_detail(r: dict) -> str:
    vclass = _VERDICT_CLASS[r["verdict"]]
    items = [
        ("Verdict",         f'<span class="verdict {vclass}">{_esc(r["verdict"])}</span> '
                            f'<span class="conf {r["confidence"] if r["confidence"] in ("high","medium","low") else ""}">{_esc(r["confidence"])}</span>'),
        ("Component",       _esc(r["component_name"]) or "—"),
        ("Team",            _esc(r["team_name"])),
        ("Status",          _status_pair(r["status_a"], r["status_b"])),
        ("Linked Jira",     _esc(r["linked_issues"])),
        ("Error",           _err_html(r["error_message"])),
        ("Culprit file",    f'<code>{_esc(r["culprit_file"])}</code>' if r["culprit_file"] else ""),
        ("Specific change", _esc(r["specific_change"])),
        ("Reasoning",       _esc(r["reason"])),
    ]
    return (
        f'<section class="detail {vclass}">'
        f'<h3>{r["case_id"]} · {_esc(r["test_case"])}</h3>'
        f'{_detail_dl(items)}'
        f'</section>'
    )


def _render_grouped_detail(rows: list[dict], heading: str) -> str:
    rep = rows[0]
    vclass = _VERDICT_CLASS[rep["verdict"]]
    test_list = "<ul>" + "".join(
        f"<li><code>{_esc(r['test_case'])}</code>"
        + (f" · {_esc(r['component_name'])}"
           if r['component_name'] and not (isinstance(r['component_name'], float) and pd.isna(r['component_name']))
           else "")
        + "</li>"
        for r in rows[:25]
    )
    if len(rows) > 25:
        test_list += f"<li>… ({len(rows) - 25} more, see table above)</li>"
    test_list += "</ul>"

    items = [
        ("Verdict",      f'<span class="verdict {vclass}">{_esc(rep["verdict"])}</span>'),
        ("Cluster size", f"{len(rows)} failures sharing this signature"),
        ("Affected",     test_list),
        ("Error",        _err_html(rep["error_message"])),
        ("Reasoning",    _esc(rep["reason"])),
    ]
    return (
        f'<section class="detail {vclass}">'
        f'<h3>{_esc(heading)}</h3>'
        f'{_detail_dl(items)}'
        f'</section>'
    )


def _fingerprint(r: dict) -> str:
    """Group key — rows that share a verdict + reason + culprit_file collapse
    into one detail block. Includes culprit so two BUGs with the same generic
    reason but different culprits never get merged."""
    err = (r["error_message"] or "")[:120]
    reason = (r["reason"] or "")[:160]
    culprit = r["culprit_file"] or ""
    return f"{r['verdict']}|{culprit}|{err}|{reason}"


_VERDICT_ORDER = {"BUG": 0, "NEEDS_REVIEW": 1, "FALSE_POSITIVE": 2, "AUTO_CLASSIFIED": 3}


def _render_details(rows: list[dict]) -> str:
    """Group every verdict by fingerprint; clusters of 2+ render as one
    consolidated section, singletons render individually. BUG and
    NEEDS_REVIEW sections render before FALSE_POSITIVE and AUTO so the
    actionable items are at the top."""

    bucket: "OrderedDict[str, list[dict]]" = OrderedDict()
    for r in rows:
        bucket.setdefault(_fingerprint(r), []).append(r)

    sorted_groups = sorted(
        bucket.values(),
        key=lambda g: (_VERDICT_ORDER.get(g[0]["verdict"], 9), -len(g)),
    )

    out: list[str] = []
    for group in sorted_groups:
        if len(group) == 1:
            out.append(_render_individual_detail(group[0]))
            continue
        verdict = group[0]["verdict"]
        err_short = (
            (group[0]["error_message"] or "").splitlines()[0][:60]
            if group[0]["error_message"] else ""
        )
        heading = f"{verdict} cluster — {len(group)} failures"
        if err_short:
            heading += f" · {err_short}"
        out.append(_render_grouped_detail(group, heading))
    return "\n".join(out)


def _render(meta: dict, payload: dict, rows: list[dict]) -> str:
    counts: dict[str, int] = defaultdict(int)
    for r in rows:
        counts[r["verdict"]] += 1

    bug_n = counts["BUG"]
    bug_with_culprit = sum(
        1 for r in rows if r["verdict"] == "BUG" and r["culprit_file"]
    )
    coverage_pct = (100 * bug_with_culprit / bug_n) if bug_n else 0.0

    title = (
        f"Triage report — Build A {meta.get('build_id_a', '?')} → "
        f"Build B {meta.get('build_id_b', '?')}"
    )
    summary_bits = [
        f"Run: <code>{_esc(meta.get('run_id'))}</code>",
        f"Classifier: <code>{_esc(payload.get('classifier'))}</code>",
        f"Routine: <code>{_esc(meta.get('routine_id')) or '—'}</code>",
        f"Hashes: <code>{_esc(str(meta.get('git_hash_a') or '')[:9]) or '?'}</code> → "
        f"<code>{_esc(str(meta.get('git_hash_b') or '')[:9]) or '?'}</code>",
        f"Mode: <code>{_esc(meta.get('mode') or 'per-test')}</code>",
        f"Prepared: <code>{_esc(meta.get('prepared_at'))}</code>",
    ]

    pills: list[str] = []
    for v in ("BUG", "NEEDS_REVIEW", "FALSE_POSITIVE", "AUTO_CLASSIFIED"):
        n = counts.get(v, 0)
        cls = _VERDICT_CLASS[v]
        pills.append(
            f'<span class="pill"><span class="verdict {cls}">{v}</span>'
            f'<span class="n">{n}</span></span>'
        )
    pills.append(
        f'<span class="pill"><strong>BUG culprit_file:</strong> '
        f'<span class="n">{bug_with_culprit}/{bug_n}</span> ({coverage_pct:.0f}%)</span>'
    )
    pills.append(
        f'<span class="pill"><strong>Total:</strong> <span class="n">{len(rows)}</span></span>'
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>{_esc(title)}</title>
<style>{_CSS}</style>
</head>
<body>
<main>
  <h1>{_esc(title)}</h1>
  <p class="summary">{' · '.join(summary_bits)}</p>
  <div class="totals">{''.join(pills)}</div>
  {_RATIONALE_HTML if bug_n == 0 else ""}

  <h2>All cases</h2>
  {_render_table(rows)}

  <h2>Details</h2>
  {_render_details(rows)}
</main>
<script>{_SORT_JS}</script>
</body>
</html>
"""


def _load_cluster_annotations(run_dir: Path) -> dict[int, dict[str, str]]:
    """Map subtask_id → {'cluster': str, 'root_cause_from_diff': str} from
    cluster_report.csv. The cluster_report has per-test rows; per subtask we
    take the dominant (>50%) non-empty value for each column. Stray
    minority annotations on a single test row are ignored — they belong to
    that test, not the subtask. Empty dict if file absent."""
    p = run_dir / "cluster_report.csv"
    if not p.exists():
        return {}
    df = pd.read_csv(p)
    if "testraySubtask" not in df.columns:
        return {}

    def dominant(values) -> str:
        counts: dict[str, int] = {}
        total = 0
        for v in values.fillna("").astype(str):
            v = v.strip()
            if not v or v == "—":
                continue
            counts[v] = counts.get(v, 0) + 1
            total += 1
        if not counts:
            return ""
        best, n = max(counts.items(), key=lambda kv: kv[1])
        return best if n * 2 > len(values) else ""

    cluster_col = "root-causeCluster"
    rc_col = "rootCause from diff"
    out: dict[int, dict[str, str]] = {}
    for sid, sub in df.groupby("testraySubtask"):
        entry = {"cluster": "", "root_cause_from_diff": ""}
        if cluster_col in sub.columns:
            entry["cluster"] = dominant(sub[cluster_col])
        if rc_col in sub.columns:
            entry["root_cause_from_diff"] = dominant(sub[rc_col])
        out[int(sid)] = entry
    return out


def _build_subtask_rows(diff_subtasks: pd.DataFrame,
                        diff_list: pd.DataFrame,
                        results: list[dict],
                        cluster_annotations: dict[int, dict[str, str]]) -> list[dict]:
    """One render row per subtask. Joins per-subtask metadata with
    the LLM verdict in results.json and the optional cluster_report.csv
    annotation. Flaky-only subtasks are dropped to mirror per-test
    rendering (which drops known_flaky)."""
    by_sid = {int(r["subtask_id"]): r for r in results
              if isinstance(r.get("subtask_id"), int)}
    teams_by_sid: dict[int, list[str]] = {}
    for sid, sub in diff_list.dropna(subset=["subtask_id"]).groupby("subtask_id"):
        teams = sorted({t for t in sub["team_name"].dropna().astype(str) if t})
        teams_by_sid[int(sid)] = teams

    rows: list[dict] = []
    for _, row in diff_subtasks.iterrows():
        if row.get("bucket") == "flaky-only":
            continue
        sid = int(row["subtask_id"])
        members = [m for m in str(row.get("member_test_cases") or "").split("|") if m]
        member_ids = [m for m in str(row.get("member_case_ids") or "").split("|") if m]
        teams = teams_by_sid.get(sid, [])

        if row.get("bucket") == "auto-only":
            verdict, conf = "AUTO_CLASSIFIED", "auto"
            reason = f"pre_classification={row.get('pre_classifications') or '—'}"
        else:
            r = by_sid.get(sid)
            if r:
                verdict = r["classification"]
                conf = r.get("confidence") or ""
                reason = r.get("reason") or ""
            else:
                verdict, conf = "NEEDS_REVIEW", "low"
                reason = "No entry in results.json — defaulted to NEEDS_REVIEW"

        ann = cluster_annotations.get(sid, {})
        rows.append({
            "subtask_id":          sid,
            "case_count":          int(row.get("case_count") or len(member_ids)),
            "member_test_cases":   members,
            "components":          row.get("components") or "",
            "teams":               teams,
            "status_b_breakdown":  row.get("status_b_breakdown") or "",
            "shared_error":        row.get("shared_error") or "",
            "linked_issues":       row.get("linked_issues") or "",
            "verdict":             verdict,
            "confidence":          conf,
            "reason":              reason,
            "root_cause":          ann.get("cluster", ""),
            "root_cause_from_diff": ann.get("root_cause_from_diff", ""),
        })
    return rows


_TESTRAY_SUBTASK_URL = (
    "https://testray.liferay.com/web/testray#/testflow/{flow}/subtasks/{sid}"
)

# liferay-portal project on testray.liferay.com — used to build per-case-result
# deep-links. Hardcoded; the renderer doesn't have other places to learn it.
_LRP_PROJECT_ID = 35392
_TESTRAY_CASE_RESULT_URL = (
    "https://testray.liferay.com/web/testray#/project/{project}"
    "/routines/{routine}/build/{build}/case-result/{result_id}"
)


def _fetch_caseresult_meta(build_id: int, cfg: dict) -> dict[str, dict]:
    """Pull every case-result for a build via /o/testray-rest/v1.0/testray-case-result.
    Returns {testrayCaseName: {case_result_id, issues, component, team, status}}.
    Names are unique per build so the dict key is safe.

    This endpoint returns rich fields (issues, component name, team name) in one
    paginated call — the /o/c/caseresults endpoint used in prepare.py only
    returns ids, requiring a second lookup."""
    items = _testray_fetch_paginated(
        f"/o/testray-rest/v1.0/testray-case-result/{build_id}",
        params={},
        token=_testray_oauth_token(cfg),
        base_url=cfg["base_url"],
    )
    out: dict[str, dict] = {}
    for it in items:
        name = it.get("testrayCaseName") or ""
        if not name:
            continue
        out[name] = {
            "case_result_id": it.get("testrayCaseResultId"),
            "issues":         it.get("issues") or "",
            "component":      it.get("testrayComponentName") or "",
            "team":           it.get("testrayTeamName") or "",
            "status":         it.get("status") or "",
        }
    return out


def _load_cluster_per_test(run_dir: Path) -> dict[str, dict[str, str]]:
    """Map testrayTestCaseName → {'cluster': str, 'root_cause_from_diff': str}
    from cluster_report.csv. The two duplicate names in the file are resolved
    by taking the first non-empty value. Empty dict if file absent."""
    p = run_dir / "cluster_report.csv"
    if not p.exists():
        return {}
    df = pd.read_csv(p)
    if "testrayTestCaseName" not in df.columns:
        return {}
    out: dict[str, dict[str, str]] = {}
    for _, row in df.iterrows():
        name = str(row.get("testrayTestCaseName") or "").strip()
        if not name:
            continue
        cluster = str(row.get("root-causeCluster") or "").strip()
        rcd = str(row.get("rootCause from diff") or "").strip()
        if cluster in ("nan", "—"):
            cluster = ""
        if rcd in ("nan", "—"):
            rcd = ""
        existing = out.setdefault(name, {"cluster": "", "root_cause_from_diff": ""})
        if cluster and not existing["cluster"]:
            existing["cluster"] = cluster
        if rcd and not existing["root_cause_from_diff"]:
            existing["root_cause_from_diff"] = rcd
    return out


def _build_per_test_rows(diff_list: pd.DataFrame,
                         results: list[dict],
                         api_meta: dict[str, dict],
                         cluster_map: dict[str, dict[str, str]]) -> list[dict]:
    """One render row per test case in diff_list.csv.

    Verdicts come from results.json. If results are keyed on subtask_id (the
    by-subtask classifier writes one verdict per subtask), the verdict is
    propagated to every member test of that subtask. If results are keyed on
    testray_case_id (per-test classifier), the verdict is used directly.
    Flaky and AUTO_CLASSIFIED rows behave the same way as elsewhere in the
    renderer.

    api_meta is keyed by test_case (testrayCaseName) and supplies the freshly
    fetched component, team, ticket id, and case-result id for the Testray
    deep-link. cluster_map supplies root cause + root cause from diff.
    """
    by_sid: dict[int, dict] = {}
    by_cid: dict[int, dict] = {}
    for r in results:
        sid = r.get("subtask_id")
        cid = r.get("testray_case_id")
        if isinstance(sid, int):
            by_sid[sid] = r
        if isinstance(cid, int):
            by_cid[cid] = r

    rows: list[dict] = []
    for _, row in diff_list.iterrows():
        if bool(row.get("known_flaky")):
            continue

        cid = int(row["testray_case_id"])
        sid = row.get("subtask_id")
        sid_int = int(sid) if pd.notna(sid) and sid else None

        pre = row.get("pre_classification")
        if pd.notna(pre) and pre:
            verdict, conf = "AUTO_CLASSIFIED", "auto"
            reason = f"pre_classification={pre}"
        else:
            r = by_cid.get(cid) or (by_sid.get(sid_int) if sid_int else None)
            if r:
                verdict = r["classification"]
                conf = r.get("confidence") or ""
                reason = r.get("reason") or ""
            else:
                verdict, conf = "NEEDS_REVIEW", "low"
                reason = "No entry in results.json — defaulted to NEEDS_REVIEW"

        test_case = row.get("test_case") or ""
        meta = api_meta.get(test_case, {})
        ann = cluster_map.get(test_case, {})

        rows.append({
            "case_id":              cid,
            "test_case":            test_case,
            "subtask_id":           sid_int,
            "case_result_id":       meta.get("case_result_id"),
            "component_name":       meta.get("component") or row.get("component_name") or "",
            "team_name":            meta.get("team") or row.get("team_name") or "",
            "linked_issues":        meta.get("issues") or row.get("linked_issues") or "",
            "status_a":             row.get("status_a") or "",
            "status_b":             row.get("status_b") or "",
            "error_message":        row.get("error_message") or "",
            "verdict":              verdict,
            "confidence":           conf,
            "reason":               reason,
            "root_cause":           ann.get("cluster", ""),
            "root_cause_from_diff": ann.get("root_cause_from_diff", ""),
        })
    return rows


def _render_per_test_table(rows: list[dict],
                           routine_id: str | int | None,
                           build_id: str | int | None) -> str:
    cols = [
        ("#",                    "col-idx"),
        ("Test",                 "col-test"),
        ("Testray",              "col-link"),
        ("Component",            "col-comp"),
        ("Team",                 "col-team"),
        ("Ticket",               "col-ticket"),
        ("Status",               "col-status"),
        ("Verdict",              "col-verdict"),
        ("Root cause",           "col-rc"),
        ("Root cause from diff", "col-rcd"),
    ]
    out = ['<table class="per-test-table">', '<thead><tr>']
    out += [f'<th class="{c}">{h}</th>' for h, c in cols]
    out += ['</tr></thead>', '<tbody>']
    for i, r in enumerate(rows, 1):
        vclass = _VERDICT_CLASS[r["verdict"]]
        comp = _esc(r["component_name"]) or "—"
        team = _esc(r["team_name"]) or "—"
        tickets = _esc(r["linked_issues"]) or "—"
        rc = _esc(r["root_cause"]) or "—"
        rcd = _esc(r["root_cause_from_diff"]) or "—"
        if r["case_result_id"] and routine_id and build_id:
            url = _TESTRAY_CASE_RESULT_URL.format(
                project=_LRP_PROJECT_ID,
                routine=routine_id,
                build=build_id,
                result_id=r["case_result_id"],
            )
            link_cell = (f'<a href="{url}" target="_blank" rel="noopener">open</a>')
        else:
            link_cell = "—"
        team_attr = _esc(r["team_name"]) if r["team_name"] else ""
        out.append(
            f'<tr id="case-{r["case_id"]}" data-team="{team_attr}" '
            f'data-verdict="{r["verdict"]}">'
            f'<td class="col-idx col-num">{i}</td>'
            f'<td class="col-test">{_esc(r["test_case"])}</td>'
            f'<td class="col-link">{link_cell}</td>'
            f'<td class="col-comp">{comp}</td>'
            f'<td class="col-team">{team}</td>'
            f'<td class="col-ticket">{tickets}</td>'
            f'<td class="col-status">{_status_pair(r["status_a"], r["status_b"])}</td>'
            f'<td class="col-verdict"><span class="verdict {vclass}">{_esc(r["verdict"])}</span></td>'
            f'<td class="col-rc">{rc}</td>'
            f'<td class="col-rcd">{rcd}</td>'
            f'</tr>'
        )
    out.append('</tbody></table>')
    return "\n".join(out)


def _render_per_test_details(rows: list[dict],
                             routine_id: str | int | None,
                             build_id: str | int | None) -> str:
    sorted_rows = sorted(
        rows, key=lambda r: (_VERDICT_ORDER.get(r["verdict"], 9), r["test_case"])
    )
    out: list[str] = []
    for r in sorted_rows:
        vclass = _VERDICT_CLASS[r["verdict"]]
        if r["case_result_id"] and routine_id and build_id:
            url = _TESTRAY_CASE_RESULT_URL.format(
                project=_LRP_PROJECT_ID,
                routine=routine_id,
                build=build_id,
                result_id=r["case_result_id"],
            )
            link = (f'<a href="{url}" target="_blank" rel="noopener">'
                    f'case-result {r["case_result_id"]}</a>')
        else:
            link = "—"
        items = [
            ("Verdict",         f'<span class="verdict {vclass}">{_esc(r["verdict"])}</span> '
                                f'<span class="conf {r["confidence"] if r["confidence"] in ("high","medium","low") else ""}">{_esc(r["confidence"])}</span>'),
            ("Testray",         link),
            ("Component",       _esc(r["component_name"]) or "—"),
            ("Team",             _esc(r["team_name"]) or "—"),
            ("Ticket",          _esc(r["linked_issues"]) or "—"),
            ("Status",          _status_pair(r["status_a"], r["status_b"])),
            ("Subtask",         f'<code>{r["subtask_id"]}</code>' if r["subtask_id"] else ""),
            ("Error",           _err_html(r["error_message"])),
            ("Root cause",      _esc(r["root_cause"])),
            ("Root cause from diff", _esc(r["root_cause_from_diff"])),
            ("Reasoning",       _esc(r["reason"])),
        ]
        team_attr = _esc(r["team_name"]) if r["team_name"] else ""
        out.append(
            f'<section class="detail {vclass}" '
            f'id="detail-case-{r["case_id"]}" data-team="{team_attr}" '
            f'data-verdict="{r["verdict"]}">'
            f'<h3>{r["case_id"]} · {_esc(r["test_case"])}</h3>'
            f'{_detail_dl(items)}'
            f'</section>'
        )
    return "\n".join(out)


_FILTER_JS = """
(function () {
  var teamSel = document.getElementById('team-filter');
  var verdictSel = document.getElementById('verdict-filter');
  if (!teamSel || !verdictSel) return;
  var rows = document.querySelectorAll('table.per-test-table tbody tr[data-team]');
  var details = document.querySelectorAll('section.detail[data-team]');
  var counter = document.getElementById('filter-count');

  function populate(sel, attr, emptyLabel) {
    var counts = {};
    rows.forEach(function (r) {
      var v = r.getAttribute(attr) || '';
      counts[v] = (counts[v] || 0) + 1;
    });
    Object.keys(counts).sort(function (a, b) {
      if (a === '') return 1;
      if (b === '') return -1;
      return a.localeCompare(b);
    }).forEach(function (v) {
      var label = (v === '' ? emptyLabel : v) + ' (' + counts[v] + ')';
      var opt = document.createElement('option');
      opt.value = v; opt.textContent = label;
      sel.appendChild(opt);
    });
  }
  populate(teamSel,    'data-team',    '(no team)');
  populate(verdictSel, 'data-verdict', '(none)');

  function matches(el) {
    var teamAll = teamSel.selectedIndex === 0;
    var verdictAll = verdictSel.selectedIndex === 0;
    return (teamAll    || el.getAttribute('data-team')    === teamSel.value)
        && (verdictAll || el.getAttribute('data-verdict') === verdictSel.value);
  }
  function apply() {
    var shown = 0;
    rows.forEach(function (r) {
      var m = matches(r);
      r.style.display = m ? '' : 'none';
      if (m) shown += 1;
    });
    details.forEach(function (d) {
      d.style.display = matches(d) ? '' : 'none';
    });
    if (counter) counter.textContent = shown + ' of ' + rows.length + ' tests';
  }
  teamSel.addEventListener('change', apply);
  verdictSel.addEventListener('change', apply);
  apply();
})();
"""


_PER_TEST_NOTE_HTML = """
<section class="rationale">
  <strong>Note:</strong> Test fixes may show up as
  <span class="verdict fp">FALSE_POSITIVE</span> for now. This will be
  improved in a future iteration.
</section>
"""


def _render_per_test(meta: dict, payload: dict, rows: list[dict]) -> str:
    counts: dict[str, int] = defaultdict(int)
    for r in rows:
        counts[r["verdict"]] += 1

    title = (
        f"Triage report (per test) — Build A {meta.get('build_id_a', '?')} → "
        f"Build B {meta.get('build_id_b', '?')}"
    )
    summary_bits = [
        f"Run: <code>{_esc(meta.get('run_id'))}</code>",
        f"Classifier: <code>{_esc(payload.get('classifier'))}</code>",
        f"Routine: <code>{_esc(meta.get('routine_id')) or '—'}</code>",
        f"Hashes: <code>{_esc(str(meta.get('git_hash_a') or '')[:9]) or '?'}</code> → "
        f"<code>{_esc(str(meta.get('git_hash_b') or '')[:9]) or '?'}</code>",
        f"Mode: <code>{_esc(meta.get('mode'))} → per-test render</code>",
        f"Prepared: <code>{_esc(meta.get('prepared_at'))}</code>",
    ]

    pills: list[str] = []
    for v in ("BUG", "NEEDS_REVIEW", "FALSE_POSITIVE", "AUTO_CLASSIFIED"):
        n = counts.get(v, 0)
        cls = _VERDICT_CLASS[v]
        pills.append(
            f'<span class="pill"><span class="verdict {cls}">{v}</span>'
            f'<span class="n">{n}</span></span>'
        )
    pills.append(
        f'<span class="pill"><strong>Total tests:</strong> '
        f'<span class="n">{len(rows)}</span></span>'
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>{_esc(title)}</title>
<style>{_CSS}
  /* Per-test report has 10 columns and the two root-cause cells need
     room — widen the page beyond the default 1180px. */
  main {{ max-width: 1640px; }}
  table.per-test-table {{ table-layout: auto; font-size: 12.5px; }}
  table.per-test-table th, table.per-test-table td {{ padding: 8px; }}
  table.per-test-table th.col-idx {{ width: 40px; }}
  table.per-test-table th.col-link {{ width: 60px; }}
  table.per-test-table th.col-comp {{ width: 130px; }}
  table.per-test-table th.col-team {{ width: 110px; }}
  table.per-test-table th.col-ticket {{ width: 110px; }}
  table.per-test-table th.col-status {{ width: 130px; }}
  table.per-test-table th.col-verdict {{ width: 130px; }}
  table.per-test-table th.col-rc, table.per-test-table td.col-rc {{ min-width: 200px; }}
  table.per-test-table th.col-rcd, table.per-test-table td.col-rcd {{ min-width: 320px; }}
  table.per-test-table td.col-rc, table.per-test-table td.col-rcd {{
    white-space: normal; line-height: 1.45;
  }}
  table.per-test-table td.col-test {{
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
  }}
  .filters {{
    display: flex; align-items: center; gap: 10px;
    margin: 18px 0 14px;
    padding: 10px 14px;
    background: var(--c-row);
    border: 1px solid var(--c-border);
    border-radius: 4px;
    font-size: 13px;
  }}
  .filters select {{
    font: inherit; padding: 4px 6px;
    border: 1px solid var(--c-border);
    border-radius: 3px; background: white;
    min-width: 240px;
  }}
  .filters .visible-count {{ color: var(--c-muted); margin-left: auto; }}
</style>
</head>
<body>
<main>
  <h1>{_esc(title)}</h1>
  <p class="summary">{' · '.join(summary_bits)}</p>
  <div class="totals">{''.join(pills)}</div>
  {_RATIONALE_HTML if counts.get("BUG", 0) == 0 else ""}
  {_PER_TEST_NOTE_HTML}

  <div class="filters">
    <label for="team-filter">Team:</label>
    <select id="team-filter"><option value="">All teams</option></select>
    <label for="verdict-filter">Verdict:</label>
    <select id="verdict-filter"><option value="">All verdicts</option></select>
    <span class="visible-count" id="filter-count"></span>
  </div>

  <h2>All tests</h2>
  {_render_per_test_table(rows, meta.get('routine_id'), meta.get('build_id_b'))}

  <h2>Details</h2>
  {_render_per_test_details(rows, meta.get('routine_id'), meta.get('build_id_b'))}
</main>
<script>{_SORT_JS}</script>
<script>{_FILTER_JS}</script>
</body>
</html>
"""


def _render_subtask_table(rows: list[dict], testflow_id: str | int | None) -> str:
    cols = [('#', 'col-idx'), ('Subtask', 'col-sid')]
    if testflow_id:
        cols.append(('Testray', 'col-link'))
    cols += [('Tests', 'col-n'), ('Component', 'col-comp'),
             ('Team', 'col-team'), ('Status', 'col-status'),
             ('Verdict', 'col-verdict'),
             ('Root cause', 'col-rc'), ('Root cause from diff', 'col-rcd')]
    out = ['<table class="subtask-table">', '<thead><tr>']
    out += [f'<th class="{c}">{h}</th>' for h, c in cols]
    out += ['</tr></thead>', '<tbody>']
    for i, r in enumerate(rows, 1):
        vclass = _VERDICT_CLASS[r["verdict"]]
        team = ", ".join(r["teams"]) if r["teams"] else "—"
        comp = _esc(r["components"]) or "—"
        rc = _esc(r["root_cause"]) or "—"
        rcd = _esc(r["root_cause_from_diff"]) or "—"
        link_cell = ""
        if testflow_id:
            url = _TESTRAY_SUBTASK_URL.format(flow=testflow_id, sid=r["subtask_id"])
            link_cell = f'<td class="col-link"><a href="{url}" target="_blank" rel="noopener">open</a></td>'
        out.append(
            f'<tr id="subtask-{r["subtask_id"]}">'
            f'<td class="col-idx col-num">{i}</td>'
            f'<td class="col-sid"><code>{r["subtask_id"]}</code></td>'
            f'{link_cell}'
            f'<td class="col-n">{r["case_count"]}</td>'
            f'<td class="col-comp">{comp}</td>'
            f'<td class="col-team">{_esc(team)}</td>'
            f'<td class="col-status"><code class="status">{_esc(r["status_b_breakdown"])}</code></td>'
            f'<td class="col-verdict"><span class="verdict {vclass}">{_esc(r["verdict"])}</span></td>'
            f'<td class="col-rc">{rc}</td>'
            f'<td class="col-rcd">{rcd}</td>'
            f'</tr>'
        )
    out.append('</tbody></table>')
    return "\n".join(out)


def _render_subtask_details(rows: list[dict], testflow_id: str | int | None) -> str:
    sorted_rows = sorted(
        rows, key=lambda r: (_VERDICT_ORDER.get(r["verdict"], 9), -r["case_count"])
    )
    out: list[str] = []
    for r in sorted_rows:
        vclass = _VERDICT_CLASS[r["verdict"]]
        members = r["member_test_cases"]
        member_html = "<ul>" + "".join(
            f"<li><code>{_esc(m)}</code></li>" for m in members[:25]
        )
        if len(members) > 25:
            member_html += f"<li>… ({len(members) - 25} more)</li>"
        member_html += "</ul>"

        if testflow_id:
            url = _TESTRAY_SUBTASK_URL.format(flow=testflow_id, sid=r["subtask_id"])
            subtask_cell = (f'<code>{r["subtask_id"]}</code> '
                            f'<a href="{url}" target="_blank" rel="noopener">open in Testray</a>')
        else:
            subtask_cell = f'<code>{r["subtask_id"]}</code>'
        items = [
            ("Verdict",       f'<span class="verdict {vclass}">{_esc(r["verdict"])}</span> '
                              f'<span class="conf {r["confidence"] if r["confidence"] in ("high","medium","low") else ""}">{_esc(r["confidence"])}</span>'),
            ("Subtask",       subtask_cell),
            ("Cases",         f"{r['case_count']} test(s)"),
            ("Component",     _esc(r["components"]) or "—"),
            ("Team",          _esc(", ".join(r["teams"])) or "—"),
            ("Status",        f'<code>{_esc(r["status_b_breakdown"])}</code>'),
            ("Linked Jira",   _esc(r["linked_issues"])),
            ("Shared error",  _err_html(r["shared_error"])),
            ("Root cause",    _esc(r["root_cause"])),
            ("Root cause from diff", _esc(r["root_cause_from_diff"])),
            ("Reasoning",     _esc(r["reason"])),
            ("Member tests",  member_html),
        ]
        out.append(
            f'<section class="detail {vclass}">'
            f'<h3>Subtask {r["subtask_id"]} · {r["case_count"]} test(s)</h3>'
            f'{_detail_dl(items)}'
            f'</section>'
        )
    return "\n".join(out)


def _render_subtask(meta: dict, payload: dict, rows: list[dict]) -> str:
    counts: dict[str, int] = defaultdict(int)
    for r in rows:
        counts[r["verdict"]] += 1

    title = (
        f"Triage report (by subtask) — Build A {meta.get('build_id_a', '?')} → "
        f"Build B {meta.get('build_id_b', '?')}"
    )
    summary_bits = [
        f"Run: <code>{_esc(meta.get('run_id'))}</code>",
        f"Classifier: <code>{_esc(payload.get('classifier'))}</code>",
        f"Routine: <code>{_esc(meta.get('routine_id')) or '—'}</code>",
        f"Hashes: <code>{_esc(str(meta.get('git_hash_a') or '')[:9]) or '?'}</code> → "
        f"<code>{_esc(str(meta.get('git_hash_b') or '')[:9]) or '?'}</code>",
        f"Mode: <code>{_esc(meta.get('mode'))}</code>",
        f"Prepared: <code>{_esc(meta.get('prepared_at'))}</code>",
    ]

    pills: list[str] = []
    for v in ("BUG", "NEEDS_REVIEW", "FALSE_POSITIVE", "AUTO_CLASSIFIED"):
        n = counts.get(v, 0)
        cls = _VERDICT_CLASS[v]
        pills.append(
            f'<span class="pill"><span class="verdict {cls}">{v}</span>'
            f'<span class="n">{n}</span></span>'
        )
    pills.append(
        f'<span class="pill"><strong>Subtasks:</strong> '
        f'<span class="n">{len(rows)}</span></span>'
    )
    total_cases = sum(r["case_count"] for r in rows)
    pills.append(
        f'<span class="pill"><strong>Member cases:</strong> '
        f'<span class="n">{total_cases}</span></span>'
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>{_esc(title)}</title>
<style>{_CSS}
  /* Wider container — by-subtask report has 9–10 columns and the
     root-cause text needs room. */
  main {{ max-width: 1640px; }}
  table.subtask-table {{ table-layout: auto; font-size: 12.5px; }}
  table.subtask-table th, table.subtask-table td {{ padding: 8px; }}
  table.subtask-table th.col-idx {{ width: 40px; }}
  table.subtask-table th.col-sid {{ width: 110px; }}
  table.subtask-table th.col-link {{ width: 60px; }}
  table.subtask-table th.col-n {{ width: 60px; text-align: right; }}
  table.subtask-table td.col-n {{ text-align: right; }}
  table.subtask-table th.col-comp {{ width: 130px; }}
  table.subtask-table th.col-team {{ width: 110px; }}
  table.subtask-table th.col-status {{ width: 130px; }}
  table.subtask-table th.col-verdict {{ width: 130px; }}
  /* Root-cause columns get the remaining space, weighted toward the
     longer 'from diff' column. */
  table.subtask-table th.col-rc, table.subtask-table td.col-rc {{ min-width: 240px; }}
  table.subtask-table th.col-rcd, table.subtask-table td.col-rcd {{ min-width: 360px; }}
  table.subtask-table td.col-rc, table.subtask-table td.col-rcd {{
    white-space: normal; line-height: 1.45;
  }}
</style>
</head>
<body>
<main>
  <h1>{_esc(title)}</h1>
  <p class="summary">{' · '.join(summary_bits)}</p>
  <div class="totals">{''.join(pills)}</div>
  {_RATIONALE_HTML if counts.get("BUG", 0) == 0 else ""}

  <h2>All subtasks</h2>
  {_render_subtask_table(rows, meta.get('testflow_id'))}

  <h2>Details</h2>
  {_render_subtask_details(rows, meta.get('testflow_id'))}
</main>
<script>{_SORT_JS}</script>
</body>
</html>
"""


def render_run(run_dir: Path,
               testflow_id: str | int | None = None,
               per_test: bool = False) -> Path:
    meta = yaml.safe_load((run_dir / "run.yml").read_text())
    if testflow_id is not None:
        meta["testflow_id"] = testflow_id
    payload = json.loads((run_dir / "results.json").read_text())
    diff_list = pd.read_csv(run_dir / "diff_list.csv")
    out = run_dir / "report.html"

    if per_test:
        cfg = load_config()
        api_meta = _fetch_caseresult_meta(int(meta["build_id_b"]), cfg["testray"])
        cluster_map = _load_cluster_per_test(run_dir)
        rows = _build_per_test_rows(
            diff_list, payload["results"], api_meta, cluster_map,
        )
        out.write_text(_render_per_test(meta, payload, rows))
    elif meta.get("mode") == "by-subtask":
        diff_subtasks = pd.read_csv(run_dir / "diff_list_subtasks.csv")
        cluster_ann = _load_cluster_annotations(run_dir)
        rows = _build_subtask_rows(diff_subtasks, diff_list,
                                   payload["results"], cluster_ann)
        out.write_text(_render_subtask(meta, payload, rows))
    else:
        rows = _build_rows(diff_list, payload["results"])
        out.write_text(_render(meta, payload, rows))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Render a triage run as HTML.")
    ap.add_argument("run_dir", type=Path, help="Path to runs/r_<id>/")
    ap.add_argument("--testflow-id", default=None,
                    help="Testray testflow ID for subtask deep-links "
                         "(by-subtask mode only). Falls back to run.yml::testflow_id.")
    ap.add_argument("--per-test", action="store_true",
                    help="Force per-test rendering (one row per failing test) even "
                         "when run.yml::mode is by-subtask. Fans subtask verdicts out "
                         "to member tests and enriches each row with component, team, "
                         "ticket id, and a Testray case-result deep-link via the "
                         "Testray REST API.")
    args = ap.parse_args()
    out = render_run(args.run_dir.resolve(),
                     testflow_id=args.testflow_id,
                     per_test=args.per_test)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
