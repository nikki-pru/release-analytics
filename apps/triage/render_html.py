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
import re
from collections import OrderedDict, defaultdict
from pathlib import Path

import pandas as pd
import yaml

from .prepare import (
    _testray_fetch_paginated,
    _testray_oauth_token,
    fetch_commits_for_file,
    fetch_commits_in_range,
    load_config,
)


_TICKET_RE = re.compile(r'\b((?:LPD|LPP|LPS)-\d+)\b')


def _commits_for_file(culprit_file: str | None,
                      repo_path: str | None,
                      hash_a: str | None,
                      hash_b: str | None,
                      cache: dict[str, str]) -> str:
    """Fallback commit attribution: when a verdict names a culprit_file but
    cited no ticket, list the commits in A..B that actually touched that file.
    e.g. 'Foo.java ← 70fdac5 LPD-123 Add wrapper; abc1234 …'. Cached per path;
    empty string when nothing applies (attribution is purely additive)."""
    if not (culprit_file and repo_path and hash_a and hash_b):
        return ""
    if culprit_file in cache:
        return cache[culprit_file]
    try:
        commits = fetch_commits_for_file(
            Path(repo_path).expanduser(), hash_a, hash_b, culprit_file)
    except Exception:
        commits = []
    if not commits:
        cache[culprit_file] = ""
        return ""
    base = culprit_file.rsplit("/", 1)[-1]
    parts = [f"{sha} {(subj or '')[:60]}".rstrip() for sha, subj in commits[:3]]
    tail = f" +{len(commits) - 3} more" if len(commits) > 3 else ""
    out = f"{base} ← " + "; ".join(parts) + tail
    cache[culprit_file] = out
    return out


def _build_ticket_commit_map(
    repo_path: str | None, hash_a: str | None, hash_b: str | None,
) -> dict[str, list[tuple[str, str]]]:
    """Parse `git log hash_a..hash_b` and return {ticket: [(short_sha, subject), ...]}.

    Empty dict if any input is missing or the lookup fails — annotation is
    purely additive, the rest of the report still renders without it."""
    if not (repo_path and hash_a and hash_b):
        return {}
    try:
        commits = fetch_commits_in_range(
            Path(repo_path).expanduser(), hash_a, hash_b,
        )
    except Exception:
        return {}
    out: dict[str, list[tuple[str, str]]] = {}
    for sha, subject in commits:
        for ticket in _TICKET_RE.findall(subject or ""):
            out.setdefault(ticket, []).append((sha, subject))
    return out


def _commits_for_text(text: str,
                      ticket_map: dict[str, list[tuple[str, str]]]) -> str:
    """Find LPD/LPP/LPS tickets in `text` and return a one-line summary of
    matching commits, e.g. 'LPD-86166 → 70fdac5208b61 Disable button…'.
    Empty string if no tickets cited or no commits matched."""
    if not text or not ticket_map:
        return ""
    seen: set[str] = set()
    parts: list[str] = []
    for ticket in _TICKET_RE.findall(text):
        if ticket in seen:
            continue
        seen.add(ticket)
        commits = ticket_map.get(ticket, [])
        if not commits:
            continue
        if len(commits) == 1:
            sha, subj = commits[0]
            short_subj = (subj or "")[:80]
            parts.append(f"{ticket} → {sha} {short_subj}".rstrip())
        else:
            shas = ", ".join(sha for sha, _ in commits[:3])
            tail = f" +{len(commits) - 3}" if len(commits) > 3 else ""
            parts.append(f"{ticket} → {len(commits)} commits ({shas}{tail})")
    return "; ".join(parts)


_VERDICT_CLASS = {
    "BUG":             "bug",
    "POSSIBLE_BUG":    "pbug",
    "NEEDS_REVIEW":    "needs",
    "TEST_FIX":        "testfix",
    "FALSE_POSITIVE":  "fp",
    "AUTO_CLASSIFIED": "auto",
}

_CSS = """
  :root {
    --c-bug: #c0392b;
    --c-pbug: #e67e22;
    --c-needs: #d68910;
    --c-testfix: #2471a3;
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
  .verdict.pbug { background: var(--c-pbug); }
  .verdict.needs { background: var(--c-needs); }
  .verdict.testfix { background: var(--c-testfix); }
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
  section.detail.pbug { border-left-color: var(--c-pbug); }
  section.detail.needs { border-left-color: var(--c-needs); }
  section.detail.testfix { border-left-color: var(--c-testfix); }
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
        // Sort by parent rows (case-row, or every row if no inline details)
        // and keep each row's adjacent case-detail row glued to it during
        // re-append, so click-to-expand stays anchored to the right parent.
        var allRows = Array.prototype.slice.call(tbody.querySelectorAll('tr'));
        var groups = [];
        for (var i = 0; i < allRows.length; i++) {
          var row = allRows[i];
          if (row.classList.contains('case-detail')) continue;
          var group = [row];
          var nxt = allRows[i + 1];
          if (nxt && nxt.classList.contains('case-detail')) {
            group.push(nxt);
          }
          groups.push(group);
        }
        var asc = !th.classList.contains('asc');
        ths.forEach(function (h) {
          h.classList.remove('sorted', 'asc', 'desc');
          h.querySelector('.sort-ind').textContent = '↕';
        });
        th.classList.add('sorted', asc ? 'asc' : 'desc');
        ind.textContent = asc ? '▲' : '▼';
        groups.sort(function (g1, g2) {
          var k1 = cellKey(g1[0].children[idx]);
          var k2 = cellKey(g2[0].children[idx]);
          return asc ? cmp(k1, k2) : cmp(k2, k1);
        });
        groups.forEach(function (g) {
          g.forEach(function (r) { tbody.appendChild(r); });
        });
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
    # Real whitespace between the spans so the browser wraps at the space
    # instead of breaking mid-word ('FAILED' → 'F\nailed').
    return (
        f'<span class="status">'
        f'<span class="{_status_class(a_s)}">{a_s}</span> '
        f'<span class="arrow">→</span> '
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


_VERDICT_ORDER = {"BUG": 0, "POSSIBLE_BUG": 1, "NEEDS_REVIEW": 2, "TEST_FIX": 3, "FALSE_POSITIVE": 4, "AUTO_CLASSIFIED": 5}


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
    for v in ("BUG", "POSSIBLE_BUG", "NEEDS_REVIEW", "TEST_FIX", "FALSE_POSITIVE", "AUTO_CLASSIFIED"):
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
                        cluster_annotations: dict[int, dict[str, str]],
                        ticket_map: dict[str, list[tuple[str, str]]] | None = None,
                        repo_path: str | None = None,
                        hash_a: str | None = None,
                        hash_b: str | None = None) -> list[dict]:
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
    file_cache: dict[str, str] = {}
    for _, row in diff_subtasks.iterrows():
        if row.get("bucket") == "flaky-only":
            continue
        sid = int(row["subtask_id"])
        members = [m for m in str(row.get("member_test_cases") or "").split("|") if m]
        member_ids = [m for m in str(row.get("member_case_ids") or "").split("|") if m]
        teams = teams_by_sid.get(sid, [])

        specific_change = ""
        culprit_file = ""
        if row.get("bucket") == "auto-only":
            verdict, conf = "AUTO_CLASSIFIED", "auto"
            reason = f"pre_classification={row.get('pre_classifications') or '—'}"
        else:
            r = by_sid.get(sid)
            if r:
                verdict = r["classification"]
                conf = r.get("confidence") or ""
                reason = r.get("reason") or ""
                specific_change = r.get("specific_change") or ""
                culprit_file = r.get("culprit_file") or ""
            else:
                verdict, conf = "NEEDS_REVIEW", "low"
                reason = "No entry in results.json — defaulted to NEEDS_REVIEW"

        ann = cluster_annotations.get(sid, {})
        # Suspicious commits: attribute the cited tickets to commits in the
        # diff range (mirrors the per-test renderer). Falls back to the
        # cluster_report 'root cause from diff' annotation when present, then
        # to commits that touched the named culprit_file (BUG/POSSIBLE_BUG
        # verdicts that name a file but cite no ticket).
        commit_anno = _commits_for_text(
            f"{reason} {specific_change}", ticket_map or {})
        suspicious_commits = ann.get("root_cause_from_diff", "") or commit_anno
        if not suspicious_commits and culprit_file:
            suspicious_commits = _commits_for_file(
                culprit_file, repo_path, hash_a, hash_b, file_cache)
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
            "specific_change":     specific_change,
            "culprit_file":        culprit_file,
            "suspicious_commits":  suspicious_commits,
        })
    return rows


_TESTRAY_SUBTASK_URL = (
    "https://testray.liferay.com/web/testray#/testflow/{flow}/subtasks/{sid}"
)

# Testray case-result deep-link. project + routine are hardcoded to the
# liferay-portal release-2026.q1 routine — api×api runs don't carry
# routine_id from dim_build, so deriving it dynamically isn't reliable.
# Update if a different routine becomes the default. The path segment is
# `case-result/{result_id}` (the case-result id from
# /o/testray-rest/v1.0/testray-case-result, not the test case id).
_TESTRAY_CASE_RESULT_URL = (
    "https://testray.liferay.com/#/project/456316917"
    "/routines/456327753/build/{build}/case-result/{result_id}"
)
_TESTRAY_BUILD_URL = (
    "https://testray.liferay.com/web/testray#/project/456316917"
    "/routines/456327753/build/{build}"
)

# Stub Jira create link. Today this just opens the blank Create Issue dialog;
# future iteration should prefill summary/description from each row's
# verdict + suspicious commits + reasoning via Jira's `?summary=…&description=…`
# query params (or via the REST API for a full templated body).
_JIRA_CREATE_URL = "https://liferay.atlassian.net/secure/CreateIssue!default.jspa"
_JIRA_BASE = "https://liferay.atlassian.net"
# Jira Cloud honors the legacy CreateIssueDetails!init.jspa endpoint for
# URL-templated tickets (static-HTML friendly — it's just query params).
# Resolved via the Jira API (2026-06-10): LPD project id + issue-type ids.
_JIRA_PID = "11106"
_JIRA_TASK_TYPE_ID = "10002"
_JIRA_BUG_TYPE_ID = "10004"
# Default parent ticket for prefilled drafts. Overridable per run via
# --jira-parent (CLI), run.yml `jira_parent`, or triage.jira_parent in
# config.yml — see render_run().
_JIRA_PARENT_KEY = "LPD-94172"
_JIRA_LABEL = "release-test-failure"     # label stamped on every triage draft


def _jira_myself_account_id(cfg: dict | None) -> str:
    """Resolve the triage operator's Jira accountId via /rest/api/3/myself
    (the account whose creds are in config.yml). Used to set Reporter on the
    prefilled draft — the legacy CreateIssueDetails endpoint requires Reporter
    and won't auto-fill it. Empty string on any failure (the field is then
    left for the user to set)."""
    j = (cfg or {}).get("jira") or {}
    base = (j.get("base_url") or "").rstrip("/")
    email, token = j.get("email"), j.get("api_token")
    if not (base and email and token):
        return ""
    import base64 as _b64, urllib.request
    try:
        auth = _b64.b64encode(f"{email}:{token}".encode()).decode()
        req = urllib.request.Request(
            f"{base}/rest/api/3/myself",
            headers={"Authorization": f"Basic {auth}", "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read()).get("accountId", "") or ""
    except Exception:
        return ""


def _jira_prefill_url(summary: str, description: str, issuetype: str,
                      extra: dict[str, str] | None = None) -> str:
    """Build a Jira Cloud Create-Issue URL pre-filled with summary +
    description (and any extra field params). The draft opens in Jira for the
    user to review and submit — nothing is created automatically."""
    from urllib.parse import quote
    parts = [f"pid={_JIRA_PID}", f"issuetype={issuetype}",
             f"summary={quote(summary[:240])}",
             f"description={quote(description[:4000])}"]
    for k, v in (extra or {}).items():
        parts.append(f"{k}={quote(str(v))}")
    return f"{_JIRA_BASE}/secure/CreateIssueDetails!init.jspa?" + "&".join(parts)


def _subtask_jira_url(r: dict, meta: dict) -> str:
    """Pre-filled LPD Task draft for one subtask, per the triage ticket
    template: Task type, 'Investigate test failure in …' summary, parent
    LPD-94172, and a wiki-markup body with the Testray link, the shared error
    in a {code} block, and Claude's reasoning."""
    sid = r["subtask_id"]
    members = r.get("member_test_cases") or []
    if members:
        test_label = members[0][:120]
        if len(members) > 1:
            test_label += f" (+{len(members) - 1} more)"
    else:
        test_label = r.get("components") or f"subtask {sid}"
    summary = f"Investigate test failure in {test_label}"

    flow = meta.get("testflow_id")
    testray = _TESTRAY_SUBTASK_URL.format(flow=flow, sid=sid) if flow else ""
    link = f"[Testray Subtask|{testray}]" if testray else "Testray Subtask (no testflow id)"
    err = (r.get("shared_error") or "").strip()[:800] or "—"
    desc = (
        f"{link}\n\n"
        f"Error message:\n"
        f"{{code}}{err}{{code}}\n\n"
        f"Claude reasoning:\n"
        f"{r.get('reason') or '—'}"
    )
    extra = {"labels": _JIRA_LABEL}
    parent = meta.get("jira_parent")
    if parent:
        extra["parent"] = parent
    reporter = meta.get("jira_reporter_account_id")
    if reporter:
        extra["reporter"] = reporter
    return _jira_prefill_url(summary, desc, _JIRA_TASK_TYPE_ID, extra=extra)


def _fetch_build_name(build_id: int, cfg: dict) -> str | None:
    """Look up a build's `name` via /o/c/builds/{id}. Returns None on any
    failure so the caller can fall back to displaying the raw id."""
    import urllib.request
    base = cfg["base_url"].rstrip("/")
    url = f"{base}/o/c/builds/{build_id}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {_testray_oauth_token(cfg)}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except Exception:
        return None
    name = data.get("name") if isinstance(data, dict) else None
    return name or None


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
                         cluster_map: dict[str, dict[str, str]],
                         ticket_map: dict[str, list[tuple[str, str]]] | None = None,
                         repo_path: str | None = None,
                         hash_a: str | None = None,
                         hash_b: str | None = None) -> list[dict]:
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
    file_cache: dict[str, str] = {}
    for _, row in diff_list.iterrows():
        if bool(row.get("known_flaky")):
            continue

        cid = int(row["testray_case_id"])
        sid = row.get("subtask_id")
        sid_int = int(sid) if pd.notna(sid) and sid else None

        pre = row.get("pre_classification")
        specific_change = ""
        culprit_file = ""
        if pd.notna(pre) and pre:
            verdict, conf = "AUTO_CLASSIFIED", "auto"
            reason = f"pre_classification={pre}"
        else:
            r = by_cid.get(cid) or (by_sid.get(sid_int) if sid_int else None)
            if r:
                verdict = r["classification"]
                conf = r.get("confidence") or ""
                reason = r.get("reason") or ""
                specific_change = r.get("specific_change") or ""
                culprit_file = r.get("culprit_file") or ""
            else:
                verdict, conf = "NEEDS_REVIEW", "low"
                reason = "No entry in results.json — defaulted to NEEDS_REVIEW"

        test_case = row.get("test_case") or ""
        meta = api_meta.get(test_case, {})
        ann = cluster_map.get(test_case, {})
        commit_anno = _commits_for_text(
            f"{reason} {specific_change}", ticket_map or {},
        )
        # Suspicious commits column = commit annotation only; reasoning lives
        # in its own column. If a manual cluster_report.csv supplied an
        # 'rootCause from diff' value, treat it as the canonical commit
        # annotation (manual labels win over auto-derived ones). Final
        # fallback: commits that touched the named culprit_file when the
        # verdict cited a file but no ticket.
        suspicious_commits = ann.get("root_cause_from_diff", "") or commit_anno
        if not suspicious_commits and culprit_file:
            suspicious_commits = _commits_for_file(
                culprit_file, repo_path, hash_a, hash_b, file_cache)
        reasoning = reason

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
            "suspicious_commits":   suspicious_commits,
            "reasoning":            reasoning,
        })
    return rows


def _per_test_detail_inner(r: dict,
                           routine_id: str | int | None,
                           build_id: str | int | None,
                           compare_meta: dict[str, dict] | None = None,
                           compare_label: str = "master") -> str:
    """Inline detail content shown when the user expands a row. Verdict,
    confidence, Testray link, component, team are already on the parent row
    so they're omitted here to keep the panel focused on per-failure detail
    (status, ticket, error, root-cause analysis)."""
    items = [
        ("Ticket already linked", _esc(r["linked_issues"]) or "—"),
        ("Status",                _status_pair(r["status_a"], r["status_b"])),
        ("Subtask",               f'<code>{r["subtask_id"]}</code>' if r["subtask_id"] else ""),
        ("Error",                 _err_html(r["error_message"])),
        ("Suspicious commits",    _esc(r["suspicious_commits"])),
        ("Reasoning",             _esc(r["reasoning"])),
    ]
    if compare_meta is not None:
        cell_html, _ = _compare_cell(r, compare_meta, compare_label)
        items.append((f"Also failing in {compare_label}", cell_html or "—"))
    return _detail_dl(items)


_BAD_STATUSES = {"FAILED", "BLOCKED", "UNTESTED", "TESTFIX"}


def _compare_cell(r: dict, compare_meta: dict[str, dict] | None,
                  compare_label: str) -> tuple[str, str]:
    """Returns (cell_html, data_attr_value) for the compare column.
    data_attr_value is one of yes / no / missing — used so the column can be
    filtered/styled later. Cell shows status text and a tick or dash."""
    if compare_meta is None:
        return "", ""
    name = r.get("test_case") or ""
    m = compare_meta.get(name)
    if m is None:
        return f'<span class="cmp cmp-missing" title="Not found in {_esc(compare_label)} build">—</span>', "missing"
    status = (m.get("status") or "").upper()
    if status in _BAD_STATUSES:
        return (
            f'<span class="cmp cmp-yes" title="status in {_esc(compare_label)} build: {_esc(status)}">'
            f'Yes ({_esc(status)})</span>',
            "yes",
        )
    return (
        f'<span class="cmp cmp-no" title="status in {_esc(compare_label)} build: {_esc(status)}">'
        f'No ({_esc(status)})</span>',
        "no",
    )


def _render_per_test_table(rows: list[dict],
                           routine_id: str | int | None,
                           build_id: str | int | None,
                           compare_meta: dict[str, dict] | None = None,
                           compare_build_id: str | int | None = None,
                           compare_label: str = "master") -> str:
    cols = [
        ("#",                  "col-idx",        ""),
        ("Test",               "col-test",
         "Click the test name to open its Testray case-result page."),
        ("Component",          "col-comp",       ""),
        ("Team",               "col-team",       ""),
        ("Status",             "col-status",     ""),
        ("Verdict",            "col-verdict",    ""),
        ("Confidence",         "col-confidence",
         "Classifier confidence: high / medium / low / auto."),
    ]
    if compare_meta is not None:
        compare_hint = (
            f"Cross-reference against build {compare_build_id} "
            f"({compare_label}). Yes = the same test case is also FAILED / "
            f"BLOCKED / UNTESTED / TESTFIX in that build, suggesting the "
            f"failure is not specific to this build pair."
        )
        build_url = _TESTRAY_BUILD_URL.format(build=compare_build_id)
        compare_header_html = (
            f'<span class="cmp-header-label">Also failing in '
            f'{_esc(compare_label)}</span>'
            f'<a class="cmp-header-link" href="{build_url}" target="_blank" '
            f'rel="noopener" title="Open build {compare_build_id} in Testray">'
            f'({_esc(str(compare_build_id))})</a>'
        )
        cols.append((compare_header_html, "col-compare", compare_hint))
    cols += [
        ("Suspicious commits", "col-suspicious", ""),
        ("Reasoning",          "col-reasoning",  ""),
        ("Create Jira ticket", "col-jira",
         "Stub link — will be mapped in the future to the Jira API "
         "with a templated ticket body per row."),
    ]
    n_cols = len(cols)
    out = ['<table class="per-test-table">', '<thead><tr>']
    for h, c, hint in cols:
        title_attr = f' title="{_esc(hint)}"' if hint else ''
        # col-compare header carries pre-built HTML (the build deep-link);
        # everything else is plain text and gets escaped.
        h_html = h if c == "col-compare" else _esc(h)
        out.append(f'<th class="{c}"{title_attr}>{h_html}</th>')
    out += ['</tr></thead>', '<tbody>']
    for i, r in enumerate(rows, 1):
        vclass = _VERDICT_CLASS[r["verdict"]]
        comp = _esc(r["component_name"]) or "—"
        team = _esc(r["team_name"]) or "—"
        suspicious = _esc(r["suspicious_commits"]) or "—"
        reasoning = _esc(r["reasoning"]) or "—"
        test_label = _esc(r["test_case"]) or "—"
        if r["case_result_id"] and build_id:
            url = _TESTRAY_CASE_RESULT_URL.format(
                build=build_id,
                result_id=r["case_result_id"],
            )
            test_cell = (
                f'<a class="test-link" href="{url}" target="_blank" '
                f'rel="noopener" title="Open in Testray">{test_label}</a>'
            )
        else:
            test_cell = test_label
        conf_class = (
            r["confidence"] if r["confidence"] in ("high", "medium", "low") else ""
        )
        conf_cell = (
            f'<span class="conf {conf_class}">{_esc(r["confidence"])}</span>'
            if r["confidence"] else "—"
        )
        team_attr = _esc(r["team_name"]) if r["team_name"] else ""
        conf_attr = _esc(r["confidence"]) if r["confidence"] else ""
        compare_cell_html, compare_attr = _compare_cell(
            r, compare_meta, compare_label,
        )
        compare_td = (
            f'<td class="col-compare">{compare_cell_html}</td>'
            if compare_meta is not None else ""
        )
        compare_attr_html = (
            f' data-compare="{compare_attr}"' if compare_meta is not None else ""
        )
        out.append(
            f'<tr id="case-{r["case_id"]}" class="case-row" '
            f'data-team="{team_attr}" data-verdict="{r["verdict"]}" '
            f'data-confidence="{conf_attr}"'
            f'{compare_attr_html}>'
            f'<td class="col-idx col-num">{i}</td>'
            f'<td class="col-test">{test_cell}</td>'
            f'<td class="col-comp">{comp}</td>'
            f'<td class="col-team">{team}</td>'
            f'<td class="col-status">{_status_pair(r["status_a"], r["status_b"])}</td>'
            f'<td class="col-verdict"><span class="verdict {vclass}">{_esc(r["verdict"])}</span></td>'
            f'<td class="col-confidence">{conf_cell}</td>'
            f'{compare_td}'
            f'<td class="col-suspicious">{suspicious}</td>'
            f'<td class="col-reasoning">{reasoning}</td>'
            f'<td class="col-jira">'
            f'<a class="jira-create" href="{_JIRA_CREATE_URL}" '
            f'target="_blank" rel="noopener" '
            f'title="Opens Jira with a blank Create Issue dialog. '
            f'Future: prefill summary/description from this row.">'
            f'Create</a>'
            f'</td>'
            f'</tr>'
        )
        # Inline detail row, hidden until the parent row is clicked.
        out.append(
            f'<tr class="case-detail {vclass}" id="detail-case-{r["case_id"]}" '
            f'data-team="{team_attr}" data-verdict="{r["verdict"]}" '
            f'data-confidence="{conf_attr}" hidden>'
            f'<td colspan="{n_cols}">'
            f'<div class="case-detail-inner">'
            f'{_per_test_detail_inner(r, routine_id, build_id, compare_meta, compare_label)}'
            f'</div>'
            f'</td></tr>'
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
            ("Suspicious commits", _esc(r["suspicious_commits"])),
            ("Reasoning",          _esc(r["reasoning"])),
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
  var confSel = document.getElementById('confidence-filter');
  var cmpSel = document.getElementById('compare-filter');
  var searchInput = document.getElementById('search-filter');
  if (!teamSel || !verdictSel) return;
  var rows = document.querySelectorAll('table.per-test-table tbody tr.case-row');
  var counter = document.getElementById('filter-count');

  // Cache lowercased text per row INCLUDING its (collapsed) detail row, so
  // search hits content even when the detail panel isn't expanded.
  rows.forEach(function (r) {
    var text = (r.textContent || '');
    var d = r.nextElementSibling;
    if (d && d.classList.contains('case-detail')) {
      text += ' ' + (d.textContent || '');
    }
    r.dataset.searchText = text.toLowerCase();
  });

  // Each facet dropdown declares which row attribute it filters on, plus
  // an optional label-map for friendlier option labels. The 'self' key tells
  // recountFacets which dropdown to skip when computing that facet's
  // available counts (so picking team=Commerce doesn't zero out the team
  // dropdown's own options — the user has to be able to switch back).
  var facets = [
    { sel: teamSel,    attr: 'data-team',       empty: '(no team)' },
    { sel: verdictSel, attr: 'data-verdict',    empty: '(none)' },
    { sel: confSel,    attr: 'data-confidence', empty: '(none)' },
    { sel: cmpSel,     attr: 'data-compare',    empty: '(none)',
      labelMap: { yes: 'Yes', no: 'No', missing: 'Missing' } },
  ].filter(function (f) { return !!f.sel; });

  // Initial population — full row set, every option visible. apply() will
  // immediately rewrite these counts on first call.
  facets.forEach(function (f) {
    var counts = {};
    rows.forEach(function (r) {
      var v = r.getAttribute(f.attr) || '';
      counts[v] = (counts[v] || 0) + 1;
    });
    Object.keys(counts).sort(function (a, b) {
      if (a === '') return 1;
      if (b === '') return -1;
      return a.localeCompare(b);
    }).forEach(function (v) {
      var displayValue = v === ''
        ? f.empty
        : (f.labelMap && f.labelMap[v]) || v;
      var opt = document.createElement('option');
      opt.value = v;
      opt.textContent = displayValue + ' (' + counts[v] + ')';
      f.sel.appendChild(opt);
    });
  });

  function searchMatch(el) {
    var q = searchInput ? searchInput.value.trim().toLowerCase() : '';
    if (!q) return true;
    return (el.dataset.searchText || '').indexOf(q) !== -1;
  }
  function facetActive(f) { return f.sel.selectedIndex > 0; }
  function facetMatch(f, el) {
    return f.sel.selectedIndex === 0
      || el.getAttribute(f.attr) === f.sel.value;
  }
  function matches(el) {
    if (!searchMatch(el)) return false;
    for (var i = 0; i < facets.length; i++) {
      if (!facetMatch(facets[i], el)) return false;
    }
    return true;
  }
  // For each facet's options, count rows that match every OTHER active
  // filter (search + every facet besides this one). This way a dropdown's
  // own selection doesn't zero out its sibling options, but selecting
  // anywhere else updates the counts shown on the remaining facets.
  function recountFacets() {
    facets.forEach(function (target) {
      var subset = [];
      for (var i = 0; i < rows.length; i++) {
        var el = rows[i];
        if (!searchMatch(el)) continue;
        var ok = true;
        for (var j = 0; j < facets.length; j++) {
          if (facets[j] === target) continue;
          if (!facetMatch(facets[j], el)) { ok = false; break; }
        }
        if (ok) subset.push(el);
      }
      var counts = {};
      subset.forEach(function (el) {
        var v = el.getAttribute(target.attr) || '';
        counts[v] = (counts[v] || 0) + 1;
      });
      // Walk existing <option>s and rewrite their count suffix; skip the
      // first option (the placeholder "All …" entry).
      for (var k = 1; k < target.sel.options.length; k++) {
        var opt = target.sel.options[k];
        var v = opt.value;
        var n = counts[v] || 0;
        var displayValue = v === ''
          ? target.empty
          : (target.labelMap && target.labelMap[v]) || v;
        opt.textContent = displayValue + ' (' + n + ')';
      }
    });
  }
  var pillVerdictEls = document.querySelectorAll('[data-pill-verdict]');
  var pillTotalEl    = document.querySelector('[data-pill-total]');
  function apply() {
    var shown = 0;
    var verdictCounts = {};
    rows.forEach(function (r) {
      var m = matches(r);
      r.style.display = m ? '' : 'none';
      // The inline detail row pairs with its parent — hide together when the
      // filter rejects the parent. When the parent matches, leave the detail
      // row alone so its `hidden` attribute (collapsed/expanded state)
      // controls visibility.
      var d = r.nextElementSibling;
      if (d && d.classList.contains('case-detail')) {
        d.style.display = m ? '' : 'none';
      }
      if (m) {
        shown += 1;
        var v = r.getAttribute('data-verdict') || '';
        verdictCounts[v] = (verdictCounts[v] || 0) + 1;
      }
    });
    if (counter) counter.textContent = shown + ' of ' + rows.length + ' tests';
    pillVerdictEls.forEach(function (el) {
      var v = el.getAttribute('data-pill-verdict');
      el.textContent = verdictCounts[v] || 0;
    });
    if (pillTotalEl) pillTotalEl.textContent = shown;
    recountFacets();
  }
  teamSel.addEventListener('change', apply);
  verdictSel.addEventListener('change', apply);
  if (confSel) confSel.addEventListener('change', apply);
  if (cmpSel) cmpSel.addEventListener('change', apply);
  if (searchInput) {
    searchInput.addEventListener('input', apply);
    // Esc clears the search
    searchInput.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') { searchInput.value = ''; apply(); }
    });
  }
  apply();
})();
"""


_TOGGLE_JS = """
(function () {
  var rows = document.querySelectorAll('table.per-test-table tbody tr.case-row');
  rows.forEach(function (row) {
    row.addEventListener('click', function (e) {
      // Don't fire when the user clicks an actual link (Testray case-result).
      if (e.target.closest('a')) return;
      var detail = row.nextElementSibling;
      if (!detail || !detail.classList.contains('case-detail')) return;
      detail.hidden = !detail.hidden;
      row.classList.toggle('expanded', !detail.hidden);
    });
  });
})();
"""


def _render_per_test(meta: dict, payload: dict, rows: list[dict],
                     compare_meta: dict[str, dict] | None = None,
                     compare_build_id: str | int | None = None,
                     compare_label: str = "master",
                     build_a_name: str | None = None,
                     build_b_name: str | None = None) -> str:
    counts: dict[str, int] = defaultdict(int)
    for r in rows:
        counts[r["verdict"]] += 1

    build_a_id = meta.get("build_id_a")
    build_b_id = meta.get("build_id_b")
    a_label = build_a_name or f"Build {build_a_id or '?'}"
    b_label = build_b_name or f"Build {build_b_id or '?'}"
    a_url = _TESTRAY_BUILD_URL.format(build=build_a_id) if build_a_id else None
    b_url = _TESTRAY_BUILD_URL.format(build=build_b_id) if build_b_id else None
    a_html = (
        f'<a class="build-link" href="{a_url}" target="_blank" rel="noopener">'
        f'{_esc(a_label)}</a>' if a_url else _esc(a_label)
    )
    b_html = (
        f'<a class="build-link" href="{b_url}" target="_blank" rel="noopener">'
        f'{_esc(b_label)}</a>' if b_url else _esc(b_label)
    )
    title_html = f"Triage report (per test) — {a_html} → {b_html}"
    title_text = f"Triage report (per test) — {a_label} → {b_label}"

    compare_filter_html = ""
    if compare_meta is not None:
        compare_filter_html = (
            f'<label for="compare-filter">Also failing in '
            f'{_esc(compare_label)}:</label>'
            f'<select id="compare-filter">'
            f'<option value="">All</option>'
            f'</select>'
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
    for v in ("BUG", "POSSIBLE_BUG", "NEEDS_REVIEW", "TEST_FIX", "FALSE_POSITIVE", "AUTO_CLASSIFIED"):
        n = counts.get(v, 0)
        cls = _VERDICT_CLASS[v]
        pills.append(
            f'<span class="pill"><span class="verdict {cls}">{v}</span>'
            f'<span class="n" data-pill-verdict="{v}">{n}</span></span>'
        )
    pills.append(
        f'<span class="pill"><strong>Total tests:</strong> '
        f'<span class="n" data-pill-total="1">{len(rows)}</span></span>'
    )

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>{_esc(title_text)}</title>
<style>{_CSS}
  /* Per-test report has 10 columns and the two root-cause cells need
     room — widen the page beyond the default 1180px. */
  main {{ max-width: 1640px; }}
  h1 a.build-link {{ color: #0747a6; text-decoration: none; }}
  h1 a.build-link:hover {{ text-decoration: underline; }}
  table.per-test-table {{ table-layout: auto; font-size: 12.5px; }}
  table.per-test-table th, table.per-test-table td {{ padding: 8px; }}
  table.per-test-table th.col-idx {{ width: 40px; }}
  table.per-test-table th.col-comp {{ width: 130px; }}
  table.per-test-table th.col-team {{ width: 110px; }}
  table.per-test-table th.col-status {{ width: 130px; }}
  table.per-test-table th.col-confidence,
  table.per-test-table td.col-confidence {{ width: 90px; text-align: center; }}
  table.per-test-table th.col-test,
  table.per-test-table td.col-test {{ min-width: 220px; max-width: 320px; }}
  table.per-test-table td.col-test a.test-link {{
    color: #0747a6;
    text-decoration: none;
  }}
  table.per-test-table td.col-test a.test-link:hover {{
    text-decoration: underline;
  }}
  table.per-test-table th.col-compare .cmp-header-label,
  table.per-test-table th.col-compare .cmp-header-link {{
    display: block;
  }}
  table.per-test-table th.col-compare .cmp-header-link {{
    font-weight: 400;
    font-size: 11px;
    color: #0747a6;
    text-decoration: none;
    margin-top: 2px;
  }}
  table.per-test-table th.col-compare .cmp-header-link:hover {{
    text-decoration: underline;
  }}
  /* Status cell wraps at whitespace only (between the two state spans),
     never mid-word. Overrides the global tbody td overflow-wrap:anywhere. */
  table.per-test-table td.col-status {{
    word-break: normal;
    overflow-wrap: normal;
  }}
  table.per-test-table td.col-status .status > span {{ white-space: nowrap; }}
  table.per-test-table th.col-verdict {{ width: 130px; }}
  table.per-test-table th.col-suspicious, table.per-test-table td.col-suspicious {{ min-width: 240px; }}
  table.per-test-table th.col-reasoning, table.per-test-table td.col-reasoning {{ min-width: 320px; }}
  table.per-test-table td.col-suspicious, table.per-test-table td.col-reasoning {{
    white-space: normal; line-height: 1.45;
  }}
  table.per-test-table th.col-jira, table.per-test-table td.col-jira {{
    width: 110px; text-align: center;
  }}
  table.per-test-table th.col-jira {{ cursor: help; }}
  table.per-test-table th.col-compare,
  table.per-test-table td.col-compare {{ width: 150px; text-align: center; }}
  table.per-test-table th.col-compare {{ cursor: help; }}
  .cmp {{
    display: inline-block;
    padding: 2px 8px;
    border-radius: 3px;
    font-size: 11.5px;
    font-weight: 600;
    white-space: nowrap;
  }}
  .cmp-yes     {{ background: #ffebe6; color: #ae2a19; border: 1px solid #ffbdad; }}
  .cmp-no      {{ background: #e3fcef; color: #006644; border: 1px solid #abf5d1; }}
  .cmp-missing {{ background: var(--c-row); color: var(--c-muted); border: 1px solid var(--c-border); }}
  a.jira-create {{
    display: inline-block;
    padding: 4px 10px;
    background: #0052cc;
    color: #fff;
    border-radius: 3px;
    font-size: 12px;
    text-decoration: none;
    white-space: nowrap;
  }}
  a.jira-create:hover {{ background: #0747a6; }}
  table.per-test-table td.col-test {{
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
  }}
  .filters {{
    display: flex; flex-direction: column; gap: 8px;
    margin: 18px 0 14px;
    padding: 10px 14px;
    background: var(--c-row);
    border: 1px solid var(--c-border);
    border-radius: 4px;
    font-size: 13px;
  }}
  .filters-row {{
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
  }}
  .filters label {{ font-weight: 600; }}
  .filters select, .filters input[type="search"] {{
    font: inherit; padding: 4px 6px;
    border: 1px solid var(--c-border);
    border-radius: 3px; background: white;
    min-width: 240px;
  }}
  .filters input[type="search"] {{ min-width: 360px; flex: 1 1 auto; }}
  .filters .visible-count {{ color: var(--c-muted); margin-left: auto; }}
  p.hint {{ color: var(--c-muted); font-size: 12.5px; margin: 4px 0 8px; }}
  p.hint kbd {{
    background: #fff; border: 1px solid var(--c-border); border-bottom-width: 2px;
    border-radius: 3px; padding: 0 5px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px;
  }}
  /* Click-to-expand row affordance. Caret in the # column flips on expand. */
  table.per-test-table tr.case-row {{ cursor: pointer; }}
  table.per-test-table tr.case-row:hover td {{ background: #eef1f4; }}
  table.per-test-table tr.case-row td.col-idx::before {{
    content: "▸ "; color: var(--c-muted); font-size: 11px;
  }}
  table.per-test-table tr.case-row.expanded td.col-idx::before {{
    content: "▾ "; color: var(--c-fg);
  }}
  table.per-test-table tr.case-row.expanded td {{
    background: #f0f3f6; border-bottom-color: transparent;
  }}
  /* Inline detail row — sits directly under its parent. */
  table.per-test-table tr.case-detail > td {{
    padding: 0 0 0 0;
    background: #fafbfc;
    border-bottom: 2px solid var(--c-border);
  }}
  table.per-test-table tr.case-detail .case-detail-inner {{
    padding: 14px 18px 16px;
    border-left: 3px solid var(--c-border);
    margin-left: 40px;  /* align under the col-idx caret */
  }}
  table.per-test-table tr.case-detail.bug   .case-detail-inner {{ border-left-color: var(--c-bug); }}
  table.per-test-table tr.case-detail.pbug  .case-detail-inner {{ border-left-color: var(--c-pbug); }}
  table.per-test-table tr.case-detail.needs .case-detail-inner {{ border-left-color: var(--c-needs); }}
  table.per-test-table tr.case-detail.fp    .case-detail-inner {{ border-left-color: var(--c-fp); }}
  table.per-test-table tr.case-detail.auto  .case-detail-inner {{ border-left-color: var(--c-auto); }}
  table.per-test-table tr.case-detail dl {{
    margin: 0;
    display: grid;
    grid-template-columns: 150px minmax(0, 1fr);
    gap: 6px 14px;
  }}
  table.per-test-table tr.case-detail dt {{ font-weight: 600; color: var(--c-muted); font-size: 13px; }}
  table.per-test-table tr.case-detail dd {{
    margin: 0; font-size: 13px; min-width: 0;
    overflow-wrap: anywhere; word-break: break-word;
  }}
</style>
</head>
<body>
<main>
  <h1>{title_html}</h1>
  <p class="summary">{' · '.join(summary_bits)}</p>
  <div class="totals">{''.join(pills)}</div>
  {_RATIONALE_HTML if counts.get("BUG", 0) == 0 else ""}

  <div class="filters">
    <div class="filters-row">
      <label for="team-filter">Team:</label>
      <select id="team-filter"><option value="">All teams</option></select>
      <label for="verdict-filter">Verdict:</label>
      <select id="verdict-filter"><option value="">All verdicts</option></select>
      <label for="confidence-filter">Confidence:</label>
      <select id="confidence-filter"><option value="">All confidence</option></select>
      {compare_filter_html}
    </div>
    <div class="filters-row">
      <label for="search-filter">Search:</label>
      <input id="search-filter" type="search" placeholder="filter by test, component, ticket, root cause… (Esc to clear)" autocomplete="off">
      <span class="visible-count" id="filter-count"></span>
    </div>
  </div>

  <h2>All tests</h2>
  <p class="hint">Click a row to expand its details inline. Press <kbd>Esc</kbd> in the search box to clear.</p>
  {_render_per_test_table(rows, meta.get('routine_id'), meta.get('build_id_b'), compare_meta, compare_build_id, compare_label)}
</main>
<script>{_SORT_JS}</script>
<script>{_FILTER_JS}</script>
<script>{_TOGGLE_JS}</script>
</body>
</html>
"""


def _render_subtask_table(rows: list[dict], testflow_id: str | int | None,
                          meta: dict | None = None) -> str:
    meta = meta or {}
    cols = [('#', 'col-idx'), ('Subtask', 'col-sid')]
    if testflow_id:
        cols.append(('Testray', 'col-link'))
    cols += [('Tests', 'col-n'), ('Component', 'col-comp'),
             ('Team', 'col-team'), ('Status', 'col-status'),
             ('Verdict', 'col-verdict'), ('Confidence', 'col-confidence'),
             ('Suspicious commits', 'col-suspicious'), ('Reasoning', 'col-reasoning'),
             ('Create Jira ticket', 'col-jira')]
    out = ['<table class="subtask-table">', '<thead><tr>']
    out += [f'<th class="{c}">{h}</th>' for h, c in cols]
    out += ['</tr></thead>', '<tbody>']
    for i, r in enumerate(rows, 1):
        vclass = _VERDICT_CLASS[r["verdict"]]
        team = ", ".join(r["teams"]) if r["teams"] else "—"
        comp = _esc(r["components"]) or "—"
        suspicious = _esc(r["suspicious_commits"]) or "—"
        reasoning = _esc(r["reason"]) or "—"
        conf_class = r["confidence"] if r["confidence"] in ("high", "medium", "low") else ""
        conf_cell = (f'<span class="conf {conf_class}">{_esc(r["confidence"])}</span>'
                     if r["confidence"] else "—")
        link_cell = ""
        if testflow_id:
            url = _TESTRAY_SUBTASK_URL.format(flow=testflow_id, sid=r["subtask_id"])
            link_cell = f'<td class="col-link"><a href="{url}" target="_blank" rel="noopener">open</a></td>'
        search_blob = _esc(" ".join(str(x) for x in (
            r["subtask_id"], r["components"], team, r["status_b_breakdown"],
            r["suspicious_commits"], r["reason"], r["verdict"])).lower())
        out.append(
            f'<tr id="subtask-{r["subtask_id"]}" data-verdict="{_esc(r["verdict"])}" '
            f'data-team="{_esc(team)}" data-text="{search_blob}">'
            f'<td class="col-idx col-num">{i}</td>'
            f'<td class="col-sid"><code>{r["subtask_id"]}</code></td>'
            f'{link_cell}'
            f'<td class="col-n">{r["case_count"]}</td>'
            f'<td class="col-comp">{comp}</td>'
            f'<td class="col-team">{_esc(team)}</td>'
            f'<td class="col-status"><code class="status">{_esc(r["status_b_breakdown"])}</code></td>'
            f'<td class="col-verdict"><span class="verdict {vclass}">{_esc(r["verdict"])}</span></td>'
            f'<td class="col-confidence">{conf_cell}</td>'
            f'<td class="col-suspicious">{suspicious}</td>'
            f'<td class="col-reasoning">{reasoning}</td>'
            f'<td class="col-jira">'
            f'<a class="jira-create" href="{_esc(_subtask_jira_url(r, meta))}" '
            f'target="_blank" rel="noopener" '
            f'title="Opens Jira Create with a prefilled LPD Task draft for this '
            f'subtask (parent LPD-94172, Testray link, error, Claude '
            f'reasoning). Review before submitting — nothing is created automatically.">'
            f'Create</a></td>'
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
            ("Specific change", _esc(r["specific_change"])),
            ("Suspicious commits", _esc(r["suspicious_commits"])),
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


_SUBTASK_FILTER_JS = """
(function () {
  var table = document.querySelector('table.subtask-table');
  if (!table) return;
  var rows = Array.prototype.slice.call(table.querySelectorAll('tbody tr'));
  var vSel = document.getElementById('verdict-filter');
  var tSel = document.getElementById('team-filter');
  var search = document.getElementById('search-filter');
  var countEl = document.getElementById('filter-count');
  var verdicts = {}, teams = {};
  rows.forEach(function (r) {
    var v = r.getAttribute('data-verdict'); if (v) verdicts[v] = 1;
    var t = r.getAttribute('data-team');
    if (t) t.split(',').forEach(function (x) { x = x.trim(); if (x && x !== '\\u2014') teams[x] = 1; });
  });
  Object.keys(verdicts).sort().forEach(function (v) {
    var o = document.createElement('option'); o.value = v; o.textContent = v; vSel.appendChild(o);
  });
  Object.keys(teams).sort().forEach(function (t) {
    var o = document.createElement('option'); o.value = t; o.textContent = t; tSel.appendChild(o);
  });
  function apply() {
    var v = vSel.value, t = tSel.value.toLowerCase(), s = search.value.toLowerCase().trim(), shown = 0;
    rows.forEach(function (r) {
      var okV = !v || r.getAttribute('data-verdict') === v;
      var okT = !t || (r.getAttribute('data-team') || '').toLowerCase().indexOf(t) !== -1;
      var okS = !s || (r.getAttribute('data-text') || '').indexOf(s) !== -1;
      var show = okV && okT && okS;
      r.style.display = show ? '' : 'none';
      if (show) shown++;
    });
    if (countEl) countEl.textContent = shown + ' / ' + rows.length + ' subtasks';
  }
  vSel.addEventListener('change', apply);
  tSel.addEventListener('change', apply);
  search.addEventListener('input', apply);
  search.addEventListener('keydown', function (e) { if (e.key === 'Escape') { search.value = ''; apply(); } });
  apply();
})();
"""


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
    for v in ("BUG", "POSSIBLE_BUG", "NEEDS_REVIEW", "TEST_FIX", "FALSE_POSITIVE", "AUTO_CLASSIFIED"):
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
  table.subtask-table th.col-confidence,
  table.subtask-table td.col-confidence {{ width: 90px; text-align: center; }}
  /* Suspicious-commits + reasoning get the remaining space, weighted
     toward the longer reasoning column. */
  table.subtask-table th.col-suspicious, table.subtask-table td.col-suspicious {{ min-width: 240px; }}
  table.subtask-table th.col-reasoning, table.subtask-table td.col-reasoning {{ min-width: 360px; }}
  table.subtask-table td.col-suspicious, table.subtask-table td.col-reasoning {{
    white-space: normal; line-height: 1.45;
  }}
  /* Filter bar — mirror the per-test report's styling. */
  .filters {{
    display: flex; flex-direction: column; gap: 8px;
    margin: 18px 0 14px;
    padding: 10px 14px;
    background: var(--c-row);
    border: 1px solid var(--c-border);
    border-radius: 4px;
    font-size: 13px;
  }}
  .filters-row {{
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
  }}
  .filters label {{ font-weight: 600; }}
  .filters select, .filters input[type="search"] {{
    font: inherit; padding: 4px 6px;
    border: 1px solid var(--c-border);
    border-radius: 3px; background: white;
    min-width: 240px;
  }}
  .filters input[type="search"] {{ min-width: 360px; flex: 1 1 auto; }}
  .filters .visible-count {{ color: var(--c-muted); margin-left: auto; }}
  /* Create-Jira column + button — mirror the per-test report. */
  table.subtask-table th.col-jira, table.subtask-table td.col-jira {{
    width: 90px; text-align: center;
  }}
  a.jira-create {{
    display: inline-block;
    padding: 4px 10px;
    background: #0052cc;
    color: #fff;
    border-radius: 3px;
    font-size: 12px;
    text-decoration: none;
    white-space: nowrap;
  }}
  a.jira-create:hover {{ background: #0747a6; }}
</style>
</head>
<body>
<main>
  <h1>{_esc(title)}</h1>
  <p class="summary">{' · '.join(summary_bits)}</p>
  <div class="totals">{''.join(pills)}</div>
  {_RATIONALE_HTML if counts.get("BUG", 0) == 0 else ""}

  <div class="filters">
    <div class="filters-row">
      <label for="verdict-filter">Verdict:</label>
      <select id="verdict-filter"><option value="">All verdicts</option></select>
      <label for="team-filter">Team:</label>
      <select id="team-filter"><option value="">All teams</option></select>
    </div>
    <div class="filters-row">
      <label for="search-filter">Search:</label>
      <input id="search-filter" type="search" placeholder="filter by subtask, component, team, status, root cause… (Esc to clear)" autocomplete="off">
      <span class="visible-count" id="filter-count"></span>
    </div>
  </div>

  <h2>All subtasks</h2>
  {_render_subtask_table(rows, meta.get('testflow_id'), meta)}

  <h2>Details</h2>
  {_render_subtask_details(rows, meta.get('testflow_id'))}
</main>
<script>{_SORT_JS}</script>
<script>{_SUBTASK_FILTER_JS}</script>
</body>
</html>
"""


def render_run(run_dir: Path,
               testflow_id: str | int | None = None,
               per_test: bool = False,
               compare_build_id: int | None = None,
               compare_label: str = "master",
               jira_parent: str | None = None) -> Path:
    meta = yaml.safe_load((run_dir / "run.yml").read_text())
    if testflow_id is not None:
        meta["testflow_id"] = testflow_id
    # Parent ticket for the prefilled Jira drafts varies per run. Resolution
    # order: explicit arg > run.yml jira_parent > triage.jira_parent in
    # config.yml > the _JIRA_PARENT_KEY default. Empty disables the parent
    # field entirely.
    meta["jira_parent"] = (
        jira_parent
        or meta.get("jira_parent")
        or (load_config().get("triage", {}) or {}).get("jira_parent")
        or _JIRA_PARENT_KEY
    )
    payload = json.loads((run_dir / "results.json").read_text())
    diff_list = pd.read_csv(run_dir / "diff_list.csv")
    out = run_dir / "report.html"

    if per_test or meta.get("mode") == "per-test":
        cfg = load_config()
        api_meta = _fetch_caseresult_meta(int(meta["build_id_b"]), cfg["testray"])
        cluster_map = _load_cluster_per_test(run_dir)
        ticket_map = _build_ticket_commit_map(
            cfg.get("git", {}).get("repo_path"),
            meta.get("git_hash_a"),
            meta.get("git_hash_b"),
        )
        rows = _build_per_test_rows(
            diff_list, payload["results"], api_meta, cluster_map, ticket_map,
            repo_path=cfg.get("git", {}).get("repo_path"),
            hash_a=meta.get("git_hash_a"),
            hash_b=meta.get("git_hash_b"),
        )
        compare_meta = None
        if compare_build_id is not None:
            compare_meta = _fetch_caseresult_meta(int(compare_build_id), cfg["testray"])
        # Build names for the title — prefer fresh API lookup over the
        # potentially-stale `api:<id>` placeholder stored in run.yml.
        build_a_name = _fetch_build_name(int(meta["build_id_a"]), cfg["testray"])
        build_b_name = _fetch_build_name(int(meta["build_id_b"]), cfg["testray"])
        out.write_text(_render_per_test(
            meta, payload, rows,
            compare_meta=compare_meta,
            compare_build_id=compare_build_id,
            compare_label=compare_label,
            build_a_name=build_a_name,
            build_b_name=build_b_name,
        ))
    elif meta.get("mode") == "by-subtask":
        diff_subtasks = pd.read_csv(run_dir / "diff_list_subtasks.csv")
        cluster_ann = _load_cluster_annotations(run_dir)
        cfg = load_config()
        meta["jira_reporter_account_id"] = _jira_myself_account_id(cfg)
        ticket_map = _build_ticket_commit_map(
            cfg.get("git", {}).get("repo_path"),
            meta.get("git_hash_a"),
            meta.get("git_hash_b"),
        )
        rows = _build_subtask_rows(diff_subtasks, diff_list,
                                   payload["results"], cluster_ann, ticket_map,
                                   repo_path=cfg.get("git", {}).get("repo_path"),
                                   hash_a=meta.get("git_hash_a"),
                                   hash_b=meta.get("git_hash_b"))
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
                         "Testray REST API. Runs whose run.yml::mode is already "
                         "per-test render this way automatically.")
    ap.add_argument("--compare-build", type=int, default=None,
                    help="Cross-reference each failing test against a second "
                         "Testray build (typically the latest master / release "
                         "build). Adds an 'Also failing in <label>' column per "
                         "row showing whether the same test case is also in a "
                         "non-passing state in that build.")
    ap.add_argument("--compare-label", default="master",
                    help="Display label for the --compare-build column "
                         "(default: 'master').")
    ap.add_argument("--jira-parent", default=None,
                    help="Parent ticket key for the prefilled Jira drafts "
                         "(e.g. LPD-94172). Varies per run. Overrides "
                         "run.yml::jira_parent and triage.jira_parent in "
                         "config.yml; falls back to the built-in default.")
    args = ap.parse_args()
    out = render_run(args.run_dir.resolve(),
                     testflow_id=args.testflow_id,
                     per_test=args.per_test,
                     compare_build_id=args.compare_build,
                     compare_label=args.compare_label,
                     jira_parent=args.jira_parent)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
