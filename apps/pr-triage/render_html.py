"""
apps/pr-triage/render_html.py

Render a PR-triage run bundle as a single self-contained HTML report,
using the per-test format from apps/triage/render_html.py:

  - Title + summary line (run id, classifier, build, branches, prepared)
  - Totals pills (PR_CAUSED / NEEDS_REVIEW / FALSE_POSITIVE) + culprit_file
    coverage
  - Brief PR_CAUSED clusters summary (top of report, since long-running
    PRs typically have a few large clusters worth highlighting)
  - Filter bar (Team / Verdict / Confidence / Search) with cross-facet
    counts that recompute as filters change
  - Per-test sortable sticky-header table with click-to-expand inline
    detail rows. Cols: #, Test, Component / Team, Uniqueness, Verdict,
    Confidence, Specific change.

Reads: run.yml, unique_rows.csv, results.json (all in the bundle).
Writes: report.html, alongside.

Usage:
    python3 -m apps.pr-triage.render_html runs/r_<id>
or:
    python3 apps/pr-triage/render_html.py runs/r_<id>
"""

import argparse
import csv
import html
import json
from collections import defaultdict
from pathlib import Path

import yaml


_TESTRAY_BASE = "https://testray.liferay.com"


def _case_result_url(build: dict, caseresult_id: str | int | None) -> str | None:
    """Build the Testray UI URL for one case-result row. Returns None if any
    piece is missing (the col-test cell falls back to plain text in that
    case)."""
    if not caseresult_id:
        return None
    project_id = build.get("project_id")
    routine_id = build.get("routine_id")
    build_id   = build.get("build_id")
    if not (project_id and routine_id and build_id):
        return None
    return (
        f"{_TESTRAY_BASE}/#/project/{project_id}"
        f"/routines/{routine_id}/build/{build_id}"
        f"/case-result/{caseresult_id}"
    )


_VERDICT_CLASS = {
    "PR_CAUSED":      "bug",
    "NEEDS_REVIEW":   "needs",
    "FALSE_POSITIVE": "fp",
}

_VERDICT_ORDER = {
    "PR_CAUSED": 0,
    "NEEDS_REVIEW": 1,
    "FALSE_POSITIVE": 2,
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
    cursor: pointer;
    user-select: none;
  }
  thead th .sort-ind { color: var(--c-muted); font-size: 11px; margin-left: 4px; }
  thead th.sorted .sort-ind { color: var(--c-fg); }
  table.per-test-table thead th:nth-child(1) { width: 40px; }
  table.per-test-table thead th:nth-child(2) { width: 26%; }
  table.per-test-table thead th:nth-child(3) { width: 14%; }
  table.per-test-table thead th:nth-child(4) { width: 11%; }
  table.per-test-table thead th:nth-child(5) { width: 10%; }
  table.per-test-table thead th:nth-child(6) { width: 8%; }
  table.per-test-table thead th:nth-child(7) { width: auto; }
  tbody td {
    padding: 10px;
    border-bottom: 1px solid var(--c-border);
    vertical-align: top;
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  table.per-test-table tbody tr.case-row:nth-child(4n+1) td { background: var(--c-row); }
  td.col-num { color: var(--c-muted); }
  td code, dd code, section.detail code {
    overflow-wrap: anywhere;
    word-break: break-word;
    white-space: normal;
  }
  table.per-test-table td.col-test {
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    font-size: 12px;
  }
  table.per-test-table td.col-test a.test-link {
    color: #0747a6;
    text-decoration: none;
  }
  table.per-test-table td.col-test a.test-link:hover {
    text-decoration: underline;
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
  .status .new-error { color: var(--c-bug); font-weight: 600; }
  .status .new-test  { color: #7d3c98; font-weight: 600; }
  .status .matched   { color: var(--c-muted); }
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
  section.detail h3 {
    margin: 0 0 10px;
    font-size: 15px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    word-break: break-all;
  }
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
  .filters {
    display: flex; flex-direction: column; gap: 8px;
    margin: 36px 0 14px;
    padding: 12px 14px;
    background: var(--c-row);
    border: 1px solid var(--c-border);
    border-top: 4px solid #2c3e50;
    border-radius: 4px;
    font-size: 13px;
    position: relative;
  }
  .filters::before {
    content: "";
    display: block;
    position: absolute;
    left: -28px; right: -28px;
    top: -22px;
    height: 1px;
    background: linear-gradient(to right, transparent 0%, var(--c-border) 12%, var(--c-border) 88%, transparent 100%);
  }
  .filters-row {
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
  }
  .filters label { font-weight: 600; }
  .filters select, .filters input[type="search"] {
    font: inherit; padding: 4px 6px;
    border: 1px solid var(--c-border);
    border-radius: 3px; background: white;
  }
  .filters select { min-width: 160px; }
  .filters #team-filter { min-width: 220px; }
  .filters #verdict-filter { min-width: 170px; }
  .filters #confidence-filter { min-width: 130px; }
  .filters #uniqueness-filter { min-width: 150px; }
  .filters input[type="search"] { min-width: 360px; flex: 1 1 auto; }
  .filters .visible-count { color: var(--c-muted); margin-left: auto; }
  p.hint { color: var(--c-muted); font-size: 12.5px; margin: 4px 0 8px; }
  p.hint kbd {
    background: #fff; border: 1px solid var(--c-border); border-bottom-width: 2px;
    border-radius: 3px; padding: 0 5px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 11px;
  }
  details.clusters-collapse {
    margin: 18px 0 0;
    border: 1px solid var(--c-border);
    border-radius: 4px;
    background: #fff;
    overflow: hidden;
  }
  details.clusters-collapse > summary {
    list-style: none;
    cursor: pointer;
    padding: 12px 16px;
    background: #fdf2ef;
    display: flex;
    align-items: center;
    gap: 12px;
    font-size: 14px;
    user-select: none;
  }
  details.clusters-collapse > summary::-webkit-details-marker { display: none; }
  details.clusters-collapse > summary:hover { background: #fbe6df; }
  details.clusters-collapse > summary .caret {
    display: inline-block;
    color: var(--c-bug);
    font-size: 16px;
    transition: transform 0.15s ease;
    width: 14px;
  }
  details.clusters-collapse[open] > summary .caret { transform: rotate(90deg); }
  details.clusters-collapse > summary .label {
    font-weight: 700;
    color: var(--c-bug);
    font-size: 15px;
  }
  details.clusters-collapse > summary .count {
    color: var(--c-muted);
    font-size: 13px;
  }
  details.clusters-collapse > summary .hint-inline {
    margin-left: auto;
    color: #fff;
    background: var(--c-bug);
    padding: 3px 10px;
    border-radius: 12px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  details.clusters-collapse > summary .hint-open { display: none; }
  details.clusters-collapse[open] > summary .hint-closed { display: none; }
  details.clusters-collapse[open] > summary .hint-open {
    display: inline;
    background: var(--c-muted);
  }
  details.clusters-collapse .clusters-body {
    padding: 6px 16px 16px;
    background: #fff;
  }
  details.clusters-collapse .clusters-body section.detail { margin-top: 14px; }
  /* Click-to-expand row affordance. Caret in the # column flips on expand. */
  table.per-test-table tr.case-row { cursor: pointer; }
  table.per-test-table tr.case-row:hover td { background: #eef1f4; }
  table.per-test-table tr.case-row td.col-num::before {
    content: "▸ "; color: var(--c-muted); font-size: 11px;
  }
  table.per-test-table tr.case-row.expanded td.col-num::before {
    content: "▾ "; color: var(--c-fg);
  }
  table.per-test-table tr.case-row.expanded td {
    background: #f0f3f6; border-bottom-color: transparent;
  }
  /* Inline detail row — sits directly under its parent. */
  table.per-test-table tr.case-detail > td {
    padding: 0;
    background: #fafbfc;
    border-bottom: 2px solid var(--c-border);
  }
  table.per-test-table tr.case-detail .case-detail-inner {
    padding: 14px 18px 16px;
    border-left: 3px solid var(--c-border);
    margin-left: 40px;
  }
  table.per-test-table tr.case-detail.bug   .case-detail-inner { border-left-color: var(--c-bug); }
  table.per-test-table tr.case-detail.needs .case-detail-inner { border-left-color: var(--c-needs); }
  table.per-test-table tr.case-detail.fp    .case-detail-inner { border-left-color: var(--c-fp); }
  table.per-test-table tr.case-detail dl {
    margin: 0;
    display: grid;
    grid-template-columns: 150px minmax(0, 1fr);
    gap: 6px 14px;
  }
  table.per-test-table tr.case-detail dt {
    font-weight: 600; color: var(--c-muted); font-size: 13px;
  }
  table.per-test-table tr.case-detail dd {
    margin: 0; font-size: 13px; min-width: 0;
    overflow-wrap: anywhere; word-break: break-word;
  }
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
  document.querySelectorAll('table.per-test-table').forEach(function (table) {
    var ths = table.querySelectorAll('thead th');
    ths.forEach(function (th, idx) {
      var ind = document.createElement('span');
      ind.className = 'sort-ind';
      ind.textContent = '↕';
      th.appendChild(ind);
      th.addEventListener('click', function () {
        var tbody = table.querySelector('tbody');
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
          var s = h.querySelector('.sort-ind'); if (s) s.textContent = '↕';
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


_FILTER_JS = """
(function () {
  var teamSel = document.getElementById('team-filter');
  var verdictSel = document.getElementById('verdict-filter');
  var confSel = document.getElementById('confidence-filter');
  var uniqSel = document.getElementById('uniqueness-filter');
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

  var facets = [
    { sel: teamSel,    attr: 'data-team',       empty: '(no team)' },
    { sel: verdictSel, attr: 'data-verdict',    empty: '(none)' },
    { sel: confSel,    attr: 'data-confidence', empty: '(none)' },
    { sel: uniqSel,    attr: 'data-uniqueness', empty: '(none)' },
  ].filter(function (f) { return !!f.sel; });

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
      var displayValue = v === '' ? f.empty : v;
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
      for (var k = 1; k < target.sel.options.length; k++) {
        var opt = target.sel.options[k];
        var v = opt.value;
        var n = counts[v] || 0;
        var displayValue = v === '' ? target.empty : v;
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
  facets.forEach(function (f) { f.sel.addEventListener('change', apply); });
  if (searchInput) {
    searchInput.addEventListener('input', apply);
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
      if (e.target.closest('a')) return;
      var detail = row.nextElementSibling;
      if (!detail || !detail.classList.contains('case-detail')) return;
      detail.hidden = !detail.hidden;
      row.classList.toggle('expanded', !detail.hidden);
    });
  });
})();
"""


def _esc(s) -> str:
    if s is None:
        return ""
    return html.escape(str(s))


def _uniq_cell(uniq_verdict: str, matched: str) -> str:
    label = ""
    cls = ""
    if uniq_verdict == "UNIQUE_NEW_ERROR":
        label = "new-error"
        cls = "new-error"
    elif uniq_verdict == "UNIQUE_NEW_TEST":
        label = "new-test"
        cls = "new-test"
    else:
        label = _esc(uniq_verdict) or "—"
    return (
        f'<span class="status">'
        f'<span class="{cls}">{label}</span> '
        f'<span class="matched">· {_esc(matched)} matched</span>'
        f'</span>'
    )


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


def _err_html(err) -> str:
    if not err:
        return ""
    err = str(err)
    if len(err) > 1200:
        err = err[:1200] + "…"
    return f'<pre class="error">{_esc(err)}</pre>'


def _build_rows(unique_rows: list[dict], results: list[dict]) -> list[dict]:
    by_id = {int(r["case_id"]): r for r in results
             if isinstance(r.get("case_id"), int)}
    rows: list[dict] = []
    for row in unique_rows:
        cid_str = (row["case_id"] or "").strip()
        if not cid_str:
            verdict, conf = "NEEDS_REVIEW", "low"
            culprit, specific = None, None
            reason = (
                "case_id could not be resolved against Liferay Portal 7.4 — "
                "likely a brand-new test introduced by this PR. Not classified."
            )
            cid = 0
        else:
            cid = int(cid_str)
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
            "caseresult_id":   (row.get("caseresult_id") or "").strip(),
            "test_case":       row.get("case_name") or "",
            "component_name":  row.get("component") or "",
            "team_name":       row.get("team") or "",
            "uniqueness":      row.get("verdict") or "",
            "matched_files":   row.get("matched_files_count") or "0",
            "flaky":           row.get("flaky") or "False",
            "error_hash":      row.get("error_hash") or "",
            "error_message":   row.get("error") or "",
            "verdict":         verdict,
            "confidence":      conf,
            "culprit_file":    culprit,
            "specific_change": specific,
            "reason":          reason,
        })
    return rows


def _detail_dl(items: list[tuple[str, str]]) -> str:
    return "<dl>" + "".join(
        f"<dt>{_esc(k)}</dt><dd>{v}</dd>" for k, v in items if v
    ) + "</dl>"


def _render_inline_detail(r: dict, vclass: str) -> str:
    """The inline-expand detail row for one case. Mirrors apps/triage's
    per-test inline detail shape so the filter JS + CSS work as-is."""
    items = [
        ("Verdict",         f'<span class="verdict {vclass}">{_esc(r["verdict"])}</span> '
                            f'<span class="conf {r["confidence"] if r["confidence"] in ("high","medium","low") else ""}">{_esc(r["confidence"])}</span>'),
        ("Component",       _esc(r["component_name"]) or "—"),
        ("Team",            _esc(r["team_name"])),
        ("Uniqueness",      _uniq_cell(r["uniqueness"], r["matched_files"])),
        ("Flaky",           _esc(r["flaky"])),
        ("Error hash",      f'<code>{_esc(r["error_hash"])}</code>'),
        ("Error",           _err_html(r["error_message"])),
        ("Culprit file",    f'<code>{_esc(r["culprit_file"])}</code>' if r["culprit_file"] else ""),
        ("Specific change", _esc(r["specific_change"])),
        ("Reasoning",       _esc(r["reason"])),
    ]
    return (
        f'<tr class="case-detail {vclass}" hidden>'
        f'<td colspan="7"><div class="case-detail-inner">{_detail_dl(items)}</div></td>'
        f'</tr>'
    )


def _render_table(rows: list[dict], build: dict | None = None) -> str:
    build = build or {}
    out = ['<table class="per-test-table">',
           '<thead><tr>',
           '<th>#</th><th>Test</th><th>Component / Team</th>'
           '<th>Uniqueness</th><th>Verdict</th><th>Confidence</th>'
           '<th>Specific change</th>',
           '</tr></thead>',
           '<tbody>']
    for i, r in enumerate(rows, 1):
        vclass = _VERDICT_CLASS.get(r["verdict"], "fp")
        comp = _esc(r["component_name"])
        url = _case_result_url(build, r.get("caseresult_id"))
        if url:
            test_cell = (
                f'<a class="test-link" href="{_esc(url)}" '
                f'target="_blank" rel="noopener" title="Open in Testray">'
                f'{_esc(r["test_case"])}</a>'
            )
        else:
            test_cell = _esc(r["test_case"])
        team = _esc(r["team_name"])
        ct = comp + (
            f" <span style='color:var(--c-muted);'>· {team}</span>" if team else ""
        )
        if not ct.strip():
            ct = "—"
        conf_class = r["confidence"] if r["confidence"] in ("high", "medium", "low") else ""
        out.append(
            f'<tr class="case-row" id="case-{r["case_id"]}" '
            f'data-team="{_esc(r["team_name"])}" '
            f'data-verdict="{_esc(r["verdict"])}" '
            f'data-confidence="{_esc(r["confidence"])}" '
            f'data-uniqueness="{_esc(r["uniqueness"])}">'
            f'<td class="col-num">{i}</td>'
            f'<td class="col-test">{test_cell}</td>'
            f'<td>{ct}</td>'
            f'<td>{_uniq_cell(r["uniqueness"], r["matched_files"])}</td>'
            f'<td><span class="verdict {vclass}">{_esc(r["verdict"])}</span></td>'
            f'<td><span class="conf {conf_class}">{_esc(r["confidence"])}</span></td>'
            f'<td>{_summary_text(r["specific_change"], r["culprit_file"])}</td>'
            f'</tr>'
        )
        out.append(_render_inline_detail(r, vclass))
    out.append('</tbody></table>')
    return "\n".join(out)


def _render_pr_caused_clusters(rows: list[dict]) -> str:
    """Compact summary of PR_CAUSED groupings by culprit_file. Collapsed
    by default because PR-triage is conservative — these are *possible*
    PR-attributions, not confirmed bugs, and the reviewer should look
    at full per-row evidence in the table below before treating them
    as ground truth."""
    by_culprit = defaultdict(list)
    for r in rows:
        if r["verdict"] != "PR_CAUSED":
            continue
        by_culprit[r["culprit_file"] or "(no culprit file)"].append(r)
    if not by_culprit:
        return ""
    n_clusters = len(by_culprit)
    n_failures = sum(len(v) for v in by_culprit.values())
    body = []
    for culprit, members in sorted(by_culprit.items(), key=lambda kv: -len(kv[1])):
        sample = members[0]
        tests_html = "".join(
            f"<li><code>{_esc(m['test_case'])}</code></li>"
            for m in members[:12]
        )
        more = ""
        if len(members) > 12:
            more = f'<li><em>… and {len(members) - 12} more</em></li>'
        body.append(f"""
<section class="detail bug">
  <h3>{_esc(culprit)}</h3>
  <div><strong>{len(members)}</strong> failure(s) · {_esc(sample.get("specific_change", ""))}</div>
  <ul>{tests_html}{more}</ul>
</section>""")
    return f"""
<details class="clusters-collapse">
  <summary>
    <span class="caret">▸</span>
    <span class="label">Possible PR_CAUSED clusters</span>
    <span class="count">{n_clusters} cluster(s) · {n_failures} failure(s)</span>
    <span class="hint-inline hint-closed">click to expand</span>
    <span class="hint-inline hint-open">click to collapse</span>
  </summary>
  <div class="clusters-body">
    {''.join(body)}
  </div>
</details>"""


def _render(run_yml: dict, payload: dict, rows: list[dict]) -> str:
    counts: dict[str, int] = defaultdict(int)
    for r in rows:
        counts[r["verdict"]] += 1

    pr_n = counts["PR_CAUSED"]
    pr_with_culprit = sum(
        1 for r in rows if r["verdict"] == "PR_CAUSED" and r["culprit_file"]
    )
    coverage_pct = (100 * pr_with_culprit / pr_n) if pr_n else 0.0

    build = run_yml.get("build", {})
    diff  = run_yml.get("diff", {})
    unique_counts = run_yml.get("unique_counts", {})

    title = (
        f"PR-Triage report — {run_yml.get('target_branch', '?')} → "
        f"{run_yml.get('base_branch', '?')} · build {build.get('build_id', '?')}"
    )
    summary_bits = [
        f"Run: <code>{_esc(run_yml.get('run_id'))}</code>",
        f"Classifier: <code>{_esc(payload.get('classifier'))}</code>",
        f"Project: <code>{_esc(build.get('project_id'))}</code> · "
        f"routine <code>{_esc(build.get('routine_id'))}</code>",
        f"Build duedate: <code>{_esc(build.get('duedate'))}</code>",
        f"Merge-base: <code>{_esc(str(diff.get('merge_base') or '')[:9])}</code>",
        f"Diff: <code>{_esc(diff.get('files_changed'))} files / "
        f"{_esc(diff.get('lines_changed'))} lines</code>",
        f"Uniqueness: <code>{_esc(unique_counts.get('unique_new_test'))} new-test · "
        f"{_esc(unique_counts.get('unique_new_error'))} new-error · "
        f"{_esc(unique_counts.get('not_unique'))} not-unique (filtered)</code>",
        f"Prepared: <code>{_esc(run_yml.get('prepared_at'))}</code>",
    ]

    pills: list[str] = []
    for v in ("PR_CAUSED", "NEEDS_REVIEW", "FALSE_POSITIVE"):
        n = counts.get(v, 0)
        cls = _VERDICT_CLASS[v]
        pills.append(
            f'<span class="pill"><span class="verdict {cls}">{v}</span>'
            f'<span class="n" data-pill-verdict="{v}">{n}</span></span>'
        )
    pills.append(
        f'<span class="pill"><strong>PR_CAUSED culprit_file:</strong> '
        f'<span class="n">{pr_with_culprit}/{pr_n}</span> ({coverage_pct:.0f}%)</span>'
    )
    pills.append(
        f'<span class="pill"><strong>Showing:</strong> '
        f'<span class="n" data-pill-total>{len(rows)}</span> of {len(rows)}</span>'
    )

    notes = payload.get("notes", "")
    notes_block = (
        f'<p class="summary" style="margin-top:-10px;">{_esc(notes)}</p>'
        if notes else ""
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
  {notes_block}
  <div class="totals">{''.join(pills)}</div>

  {_render_pr_caused_clusters(rows)}

  <div class="filters">
    <div class="filters-row">
      <label for="team-filter">Team:</label>
      <select id="team-filter"><option value="">All teams</option></select>
      <label for="verdict-filter">Verdict:</label>
      <select id="verdict-filter"><option value="">All verdicts</option></select>
      <label for="confidence-filter">Confidence:</label>
      <select id="confidence-filter"><option value="">All confidence</option></select>
      <label for="uniqueness-filter">Uniqueness:</label>
      <select id="uniqueness-filter"><option value="">All</option></select>
    </div>
    <div class="filters-row">
      <label for="search-filter">Search:</label>
      <input id="search-filter" type="search" placeholder="filter by test, component, ticket, error, culprit file… (Esc to clear)" autocomplete="off">
      <span class="visible-count" id="filter-count"></span>
    </div>
  </div>

  {_render_table(rows, build)}
</main>
<script>{_SORT_JS}</script>
<script>{_FILTER_JS}</script>
<script>{_TOGGLE_JS}</script>
</body>
</html>
"""


def render(run_dir: Path) -> Path:
    run_yml = yaml.safe_load((run_dir / "run.yml").read_text())
    payload = json.loads((run_dir / "results.json").read_text())

    unique_rows = []
    with (run_dir / "unique_rows.csv").open() as f:
        for r in csv.DictReader(f):
            unique_rows.append(r)

    rows = _build_rows(unique_rows, payload.get("results", []))
    html_out = _render(run_yml, payload, rows)

    out = run_dir / "report.html"
    out.write_text(html_out)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("run_dir", type=Path,
                   help="Path to runs/r_<id>/ bundle")
    args = p.parse_args()
    out = render(args.run_dir.resolve())
    print(f"Wrote {out} ({out.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
