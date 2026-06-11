#!/usr/bin/env python3
"""Changed-failure gap report (FAILED -> FAILED, different reason), clustered
by Testray subtask.

The standard triage diff (compute_test_diff) only surfaces PASSED->FAILED
transitions, so a test already failing in the baseline build is excluded
entirely. That hides a real case: a test that fails in BOTH builds but for a
DIFFERENT reason in the target — a new regression masked by a pre-existing
failure.

This standalone tool fills that gap for one build pair: it reads the full
caseresult set from both sides, keeps cases FAILED in baseline AND FAILED in
target where the error *signature* changed, then CLUSTERS them by the target
build's Testray subtask (the same error-fingerprint grouping the by-subtask
triage uses) and, when given the triage run dir, cross-references each cluster
against the known PASSED->FAILED regression subtasks.

Standalone by design (the long-term home is compute_test_diff itself).
Baseline is read from the testray DB; target from the Testray REST API.

Usage:
    python3 -m apps.triage.changed_failures \
        --baseline-build-id 469572134 --target-build-id 482461141 \
        --testflow-id 482554602 \
        --run-dir apps/triage/runs/r_20260610T011914Z_469572134_482461141 \
        [--use-cache] [--out <path>]
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

import pandas as pd

from .prepare import (
    fetch_build_caseresults,
    fetch_build_caseresults_api,
    fetch_build_metadata,
    load_config,
)
from . import prompt_helpers
from .render_html import (
    _CSS, _esc, _err_html, _TESTRAY_SUBTASK_URL, _VERDICT_CLASS,
    _jira_prefill_url, _jira_myself_account_id,
    _JIRA_TASK_TYPE_ID, _JIRA_PARENT_KEY, _JIRA_LABEL,
    _build_ticket_commit_map, _commits_for_text,
)

_RANK = {"PASSED": 0, "UNTESTED": 1, "BLOCKED": 2, "FAILED": 3}
_ENV_CLASSES = {"BUILD_FAILURE", "ENV_CHROME", "ENV_DEPENDENCY", "ENV_DATE", "ENV_SETUP"}


def _agg_side(df: pd.DataFrame, baseline: bool) -> pd.DataFrame:
    """Collapse raw caseresult rows (one per run x case) to one row per
    case_id. Baseline is pass-optimistic (a passing retry clears it);
    target is fail-surfacing. Carries target subtask_id when present."""
    df = df[df["case_id"].notna()].copy()
    df["case_id"] = df["case_id"].astype("int64")
    has_sub = "subtask_id" in df.columns
    out_rows = []
    for cid, g in df.groupby("case_id"):
        statuses = list(g["status"].fillna("UNTESTED"))
        status = "PASSED" if (baseline and "PASSED" in statuses) \
            else max(statuses, key=lambda s: _RANK.get(s, 1))
        match = g[g["status"] == status]
        err = next((e for e in match["errors"] if isinstance(e, str) and e.strip()), "")

        def first(col):
            vals = [v for v in g.get(col, pd.Series(dtype=object))
                    if isinstance(v, str) and v.strip()]
            return vals[0] if vals else ""
        row = {
            "case_id": int(cid),
            "status": status,
            "errors": err,
            "case_name": first("case_name"),
            "component_name": first("component_name"),
            "team_name": first("team_name"),
            "case_flaky": bool(g.get("case_flaky", pd.Series([False])).fillna(False).any()),
        }
        if has_sub:
            nz = [int(s) for s in g["subtask_id"].fillna(0) if int(s) != 0]
            row["subtask_id"] = nz[0] if nz else 0
        out_rows.append(row)
    return pd.DataFrame(out_rows)


_ERR_HINT = re.compile(
    r"(error|exception|not present|not found|does not match|timeout|timed out|"
    r"cannot|expected|assert|failed)", re.I)


def _signature(err: str) -> str:
    """A comparable 'reason' signature: the first error-bearing line (skipping
    Playwright '>' descriptor lines), lowercased, with volatile tokens (urls,
    hex/uuids, numbers) masked. Same signature == same reason."""
    if not isinstance(err, str) or not err.strip():
        return ""
    lines = [l.strip() for l in err.strip().splitlines() if l.strip()]
    cand = [l for l in lines if not l.startswith(("›", ">"))]
    head = next((l for l in cand if _ERR_HINT.search(l)), None) or (cand[0] if cand else lines[0])
    head = head.lower()
    head = re.sub(r"https?://\S+", "<url>", head)
    head = re.sub(r"\b[0-9a-f]{8,}\b", "#", head)
    head = re.sub(r"\d+", "#", head)
    return re.sub(r"\s+", " ", head).strip()


def _fail_both(baseline_id: int, target_id: int, cfg: dict,
               cache_path: Path, use_cache: bool) -> pd.DataFrame:
    """Cases FAILED in both builds (before the changed-reason filter), cached
    so the slow API fetch isn't repeated while iterating the report."""
    if use_cache and cache_path.exists():
        print(f"[cache] loading fail-both set from {cache_path.name}")
        return pd.read_pickle(cache_path)
    db_cfg, tr_cfg = cfg["databases"]["testray"], cfg["testray"]
    print(f"[baseline {baseline_id}] reading caseresult_analytical (db) …")
    base_raw = fetch_build_caseresults(baseline_id, db_cfg)
    print(f"   {len(base_raw)} raw rows")
    print(f"[target {target_id}] fetching caseresults (Testray API) …")
    targ_raw = fetch_build_caseresults_api(target_id, tr_cfg)
    print(f"   {len(targ_raw)} raw rows")
    base = _agg_side(base_raw, baseline=True)
    targ = _agg_side(targ_raw, baseline=False)
    print(f"   aggregated: baseline {len(base)} cases, target {len(targ)} cases")
    merged = base.merge(targ, on="case_id", suffixes=("_a", "_b"))
    fail_both = merged[(merged["status_a"] == "FAILED")
                       & (merged["status_b"] == "FAILED")].copy()
    print(f"   FAILED in both builds: {len(fail_both)}")
    fail_both.to_pickle(cache_path)
    return fail_both


def find_changed_failures(baseline_id: int, target_id: int, cfg: dict,
                          cache_path: Path, use_cache: bool) -> pd.DataFrame:
    fb = _fail_both(baseline_id, target_id, cfg, cache_path, use_cache)
    fb["sig_a"] = fb["errors_a"].apply(_signature)
    fb["sig_b"] = fb["errors_b"].apply(_signature)
    extra = prompt_helpers.load_triage_config().get("auto_classify_patterns") or {}
    fb["cat_a"] = fb["errors_a"].apply(lambda e: prompt_helpers.pre_classify(e, extra))
    fb["cat_b"] = fb["errors_b"].apply(lambda e: prompt_helpers.pre_classify(e, extra))

    def is_changed(r):
        if r["case_flaky_a"] or r["case_flaky_b"]:
            return False
        if r["sig_a"] == r["sig_b"]:
            return False
        if r["cat_a"] and r["cat_a"] == r["cat_b"] and r["cat_a"] in _ENV_CLASSES:
            return False
        return True

    gap = fb[fb.apply(is_changed, axis=1)].copy()
    gap["test_case"] = gap["case_name_a"].where(gap["case_name_a"].astype(bool), gap["case_name_b"])
    gap["component_name"] = gap["component_name_a"].where(
        gap["component_name_a"].astype(bool), gap["component_name_b"])
    gap["team_name"] = gap["team_name_a"]
    if "subtask_id" not in gap.columns:
        gap["subtask_id"] = 0
    gap["subtask_id"] = gap["subtask_id"].fillna(0).astype("int64")
    print(f"   CHANGED-reason failures (the gap): {len(gap)}")
    return gap


def _load_regression_subtasks(run_dir: Path | None) -> dict[int, dict]:
    """Map subtask_id -> {verdict, confidence} from the by-subtask run, so each
    changed-failure cluster can be related to a known regression subtask."""
    if not run_dir:
        return {}
    out: dict[int, dict] = {}
    results = run_dir / "results.json"
    if results.exists():
        for r in json.loads(results.read_text()).get("results", []):
            sid = r.get("subtask_id")
            if isinstance(sid, int):
                out[sid] = {"verdict": r.get("classification", "?"),
                            "confidence": r.get("confidence", "")}
    return out


_EXTRA_CSS = """
  .filters { display:flex; flex-direction:column; gap:8px; margin:18px 0 14px;
    padding:10px 14px; background:var(--c-row); border:1px solid var(--c-border);
    border-radius:4px; font-size:13px; }
  .filters-row { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .filters label { font-weight:600; }
  .filters select, .filters input[type="search"] { font:inherit; padding:4px 6px;
    border:1px solid var(--c-border); border-radius:3px; background:white; min-width:240px; }
  .filters input[type="search"] { min-width:360px; flex:1 1 auto; }
  .filters .visible-count { color:var(--c-muted); margin-left:auto; }
  p.hint { color:var(--c-muted); font-size:12.5px; margin:4px 0 8px; }
  table.st { width:100%; border-collapse:collapse; font-size:12.5px; table-layout:auto; }
  table.st th, table.st td { padding:8px; border-bottom:1px solid var(--c-border);
    vertical-align:top; text-align:left; }
  table.st th { background:var(--c-row); position:sticky; top:0; z-index:1; }
  table.st th.col-idx { width:34px; } table.st th.col-sid { width:96px; }
  table.st th.col-link { width:54px; } table.st th.col-n { width:48px; text-align:right; }
  table.st td.col-n { text-align:right; }
  table.st th.col-comp { width:130px; } table.st th.col-team { width:110px; }
  table.st th.col-status { width:120px; } table.st th.col-verdict { width:120px; }
  table.st th.col-confidence, table.st td.col-confidence { width:80px; text-align:center; }
  table.st th.col-suspicious, table.st td.col-suspicious { min-width:220px; }
  table.st th.col-reasoning, table.st td.col-reasoning { min-width:320px; }
  table.st td.col-suspicious, table.st td.col-reasoning { white-space:normal; line-height:1.45; }
  table.st th.col-jira, table.st td.col-jira { width:96px; text-align:center; }
  tr.crow { cursor:pointer; } tr.crow:hover { background:var(--c-row); }
  tr.crow .twist { color:var(--c-muted); font-size:11px; }
  tr.cdetail > td { background:#fafbfc; padding:0 8px 10px 34px; }
  table.cf { width:100%; border-collapse:collapse; font-size:12px; margin-top:6px; }
  table.cf th, table.cf td { padding:6px 8px; border-bottom:1px solid var(--c-border);
    vertical-align:top; text-align:left; }
  table.cf th { background:var(--c-row); }
  table.cf td.err { max-width:440px; }
  pre.error { white-space:pre-wrap; word-break:break-word; margin:0; background:var(--c-code-bg);
    padding:6px 8px; border-radius:3px; font-size:11px; max-height:150px; overflow:auto; }
  .catchip { display:inline-block; padding:1px 6px; border-radius:3px; font-size:10.5px;
    background:var(--c-row); border:1px solid var(--c-border); color:var(--c-muted); white-space:nowrap; }
  .sublink { font-size:11.5px; }
  a.jira-create { display:inline-block; padding:3px 9px; background:#0052cc; color:#fff;
    border-radius:3px; font-size:11.5px; text-decoration:none; white-space:nowrap; }
  a.jira-create:hover { background:#0747a6; }
  .commits { font-family:ui-monospace,Menlo,monospace; font-size:11px; }
  .commits-chip { display:inline-block; padding:1px 7px; border-radius:3px; font-size:10px;
    font-weight:600; background:#e3fcef; color:#006644; border:1px solid #abf5d1; white-space:nowrap; }
  .verdict { color:#fff; padding:1px 6px; border-radius:3px; font-size:10.5px; font-weight:600; }
  .verdict.bug{background:#c0392b;} .verdict.pbug{background:#e67e22;}
  .verdict.needs{background:#d68910;} .verdict.testfix{background:#2471a3;}
  .verdict.fp{background:#15803d;} .verdict.auto{background:#7f8c8d;}
  .verdict.none{background:transparent;color:var(--c-muted);font-weight:400;}
  .conf.high{color:#1e8449;font-weight:600;} .conf.medium{color:#b9770e;font-weight:600;}
  .conf.low{color:#7d3c98;}
"""

_FILTER_JS = """
(function () {
  var rows = Array.prototype.slice.call(document.querySelectorAll('tr.crow'));
  var comp = document.getElementById('comp-filter');
  var team = document.getElementById('team-filter');
  var verd = document.getElementById('verdict-filter');
  var ov = document.getElementById('overlap-filter');
  var search = document.getElementById('search-filter');
  var countEl = document.getElementById('filter-count');
  var comps = {}, teams = {}, verds = {};
  rows.forEach(function (r) {
    (r.getAttribute('data-comp')||'').split('|').forEach(function(x){ if(x) comps[x]=1; });
    (r.getAttribute('data-team')||'').split('|').forEach(function(x){ if(x) teams[x]=1; });
    var v=r.getAttribute('data-verdict'); if(v) verds[v]=1;
  });
  Object.keys(comps).sort().forEach(function(c){var o=document.createElement('option');o.value=c;o.textContent=c;comp.appendChild(o);});
  Object.keys(teams).sort().forEach(function(t){var o=document.createElement('option');o.value=t;o.textContent=t;team.appendChild(o);});
  Object.keys(verds).sort().forEach(function(v){var o=document.createElement('option');o.value=v;o.textContent=(v==='NONE'?'— changed-failure only':v);verd.appendChild(o);});
  function apply() {
    var c=comp.value, t=team.value, vv=verd.value, o=ov.value, s=search.value.toLowerCase().trim(), n=0;
    rows.forEach(function (r) {
      var ok = (!c || (r.getAttribute('data-comp')||'').split('|').indexOf(c)!==-1)
            && (!t || (r.getAttribute('data-team')||'').split('|').indexOf(t)!==-1)
            && (!vv || r.getAttribute('data-verdict')===vv)
            && (!o || r.getAttribute('data-overlap')===o)
            && (!s || (r.getAttribute('data-text')||'').indexOf(s)!==-1);
      r.style.display = ok ? '' : 'none';
      var d = r.nextElementSibling;
      if (d && d.classList.contains('cdetail')) d.style.display = ok ? '' : 'none';
      if (ok) n++;
    });
    if (countEl) countEl.textContent = n + ' / ' + rows.length + ' subtasks';
  }
  [comp,team,verd,ov].forEach(function(el){el.addEventListener('change',apply);});
  search.addEventListener('input', apply);
  search.addEventListener('keydown', function(e){ if(e.key==='Escape'){ search.value=''; apply(); } });
  // click a row to expand its before/after detail (ignore clicks on links)
  rows.forEach(function (r) {
    r.addEventListener('click', function (e) {
      if (e.target.closest('a')) return;
      var d = r.nextElementSibling;
      if (d && d.classList.contains('cdetail')) d.hidden = !d.hidden;
    });
  });
  apply();
})();
"""


_SORT_JS = """
(function () {
  var table = document.querySelector('table.st'); if (!table || !table.tHead) return;
  var tbody = table.tBodies[0];
  var ths = table.tHead.rows[0].cells;
  var skip = {0:1, 2:1, 9:1, 10:1, 11:1};   // idx, Testray, Suspicious, Reasoning, Create
  var confRank = {high:'0', medium:'1', low:'2'};
  var cur = -1, dir = 1;
  function val(row, idx) {
    var c = row.cells[idx]; if (!c) return '';
    var t = c.textContent.trim();
    if (idx === 8) return (t in confRank ? confRank[t] : '9');  // confidence order
    return t;
  }
  function isNum(s) { return /^\\d+$/.test(s); }
  for (var i = 0; i < ths.length; i++) {
    if (skip[i]) continue;
    ths[i].style.cursor = 'pointer';
    ths[i].dataset.base = ths[i].textContent;
    (function (idx) {
      ths[idx].addEventListener('click', function () {
        dir = (cur === idx) ? -dir : 1; cur = idx;
        var pairs = Array.prototype.slice.call(tbody.querySelectorAll('tr.crow'))
          .map(function (r) { return [r, r.nextElementSibling]; });
        pairs.sort(function (a, b) {
          var va = val(a[0], idx), vb = val(b[0], idx);
          var cmp = (isNum(va) && isNum(vb)) ? (parseInt(va, 10) - parseInt(vb, 10))
                                             : va.localeCompare(vb);
          return cmp * dir;
        });
        pairs.forEach(function (p) {
          tbody.appendChild(p[0]);
          if (p[1] && p[1].classList.contains('cdetail')) tbody.appendChild(p[1]);
        });
        for (var j = 0; j < ths.length; j++)
          if (ths[j].dataset.base !== undefined) ths[j].textContent = ths[j].dataset.base;
        ths[idx].textContent = ths[idx].dataset.base + (dir > 0 ? ' ▲' : ' ▼');
      });
    })(i);
  }
})();
"""


def _cluster_jira_url(members, sub_url, rep_b, rep_a, reporter, parent) -> str:
    """Prefilled LPD Task draft for a changed-failure cluster (one per
    subtask) — mirrors the by-subtask report's template."""
    first = members[0]["test_case"] or members[0]["component_name"] or "test"
    label = first[:120] + (f" (+{len(members) - 1} more)" if len(members) > 1 else "")
    summary = f"Investigate test failure in {label}"
    link = f"[Testray Subtask|{sub_url}]" if sub_url else "Testray Subtask (no link)"
    member_lines = "\n".join(f"- {m['test_case']}" for m in members[:20])
    if len(members) > 20:
        member_lines += f"\n- … (+{len(members) - 20} more)"
    desc = (
        f"{link}\n\n"
        f"Changed-failure cluster: {len(members)} test(s) FAILED in both builds "
        f"but with a different reason in the target — surfaced by "
        f"changed_failures.py, outside the standard PASSED->FAILED triage.\n\n"
        f"Target error (new reason):\n{{code}}{(rep_b or '').strip()[:800]}{{code}}\n\n"
        f"Baseline error (was already failing):\n{{code}}{(rep_a or '').strip()[:500]}{{code}}\n\n"
        f"Affected tests:\n{member_lines}"
    )
    extra = {"labels": _JIRA_LABEL}
    if parent:
        extra["parent"] = parent
    if reporter:
        extra["reporter"] = reporter
    return _jira_prefill_url(summary, desc, _JIRA_TASK_TYPE_ID, extra=extra)


def render_report(gap: pd.DataFrame, meta: dict, regression: dict[int, dict],
                  testflow_id, reporter: str, parent: str,
                  ticket_map: dict, out: Path) -> Path:
    # Cluster by target subtask_id; subtask_id 0 (no Testray group) falls back
    # to clustering by error signature so those still group by reason.
    clusters: dict = {}
    for _, r in gap.iterrows():
        key = ("sub", int(r["subtask_id"])) if r["subtask_id"] else ("sig", r["sig_b"])
        clusters.setdefault(key, []).append(r)
    ordered = sorted(clusters.items(), key=lambda kv: (-len(kv[1]), str(kv[0])))

    def cat(v): return (f'<span class="catchip">{_esc(v)}</span>'
                        if (isinstance(v, str) and v.strip()) else '<span class="catchip">—</span>')
    def _desc(c): return c if (isinstance(c, str) and c.strip()) else "real failure"

    rows_html = []
    for (kind, key), members in ordered:
        comps = sorted({m["component_name"] for m in members if m["component_name"]})
        teams = sorted({m["team_name"] for m in members if m["team_name"]})
        sig = Counter(m["sig_b"] for m in members).most_common(1)[0][0]
        rep = next((m for m in members if m["sig_b"] == sig), members[0])
        reg = regression.get(key) if kind == "sub" else None
        in_reg = reg is not None

        sub_url = ""
        if kind == "sub":
            sid_cell = f'<code>{key}</code>'
            if testflow_id:
                sub_url = _TESTRAY_SUBTASK_URL.format(flow=testflow_id, sid=key)
                link_cell = (f'<a class="sublink" href="{sub_url}" target="_blank" '
                             f'rel="noopener" onclick="event.stopPropagation()">open</a>')
            else:
                link_cell = "—"
        else:
            sid_cell = '<span class="catchip">by error</span>'
            link_cell = "—"

        if in_reg:
            v = reg["verdict"]
            verdict_cell = f'<span class="verdict {_VERDICT_CLASS.get(v, "auto")}">{_esc(v)}</span>'
            cf = reg["confidence"]
            conf_cell = (f'<span class="conf {cf if cf in ("high","medium","low") else ""}">{_esc(cf)}</span>'
                         if cf else "—")
        else:
            verdict_cell = '<span class="verdict none">— changed-failure only</span>'
            conf_cell = "—"

        reasoning = (
            f"Failed in both builds, reason changed — baseline: {_desc(rep['cat_a'])} "
            f"(“{rep['sig_a'][:90]}”); target: {_desc(rep['cat_b'])} (“{rep['sig_b'][:90]}”)."
            + (f" Also a regression subtask (verdict {reg['verdict']})." if in_reg else "")
        )
        # Suspicious commits: ticket-based attribution over target error + test
        # names (which carry @LPD tags). No culprit_file here (unclassified), so
        # the file-path fallback doesn't apply.
        ticket_text = rep["errors_b"] + " " + " ".join(m["test_case"] for m in members)
        suspicious = _commits_for_text(ticket_text, ticket_map or {})
        tickets = ", ".join(sorted(set(re.findall(r"(?:LPD|LPP|LPS)-\d+", suspicious))))
        commit_chip = f'<span class="commits-chip">⎇ {tickets}</span> ' if tickets else ''
        susp_cell = (commit_chip + f'<span class="commits">{_esc(suspicious)}</span>') if suspicious else "—"

        jira_url = _cluster_jira_url(members, sub_url, rep["errors_b"], rep["errors_a"],
                                     reporter, parent)
        create_cell = (f'<a class="jira-create" href="{_esc(jira_url)}" target="_blank" '
                       f'rel="noopener" onclick="event.stopPropagation()" '
                       f'title="Prefilled LPD Task draft (parent {_esc(parent) or "—"}, '
                       f'label {_esc(_JIRA_LABEL)})">Create</a>')

        data_text = (" ".join(f'{m["test_case"]} {m["sig_a"]} {m["sig_b"]}' for m in members)
                     + " " + suspicious + " " + reasoning + " "
                     + " ".join(comps) + " " + " ".join(teams)).lower()

        verdict_val = reg["verdict"] if in_reg else "NONE"
        rows_html.append(
            f'<tr class="crow" data-comp="{_esc("|".join(comps))}" data-team="{_esc("|".join(teams))}" '
            f'data-overlap="{"yes" if in_reg else "no"}" data-verdict="{_esc(verdict_val)}" '
            f'data-text="{_esc(data_text)}">'
            f'<td class="col-idx"><span class="twist">▸</span></td>'
            f'<td class="col-sid">{sid_cell}</td>'
            f'<td class="col-link">{link_cell}</td>'
            f'<td class="col-n">{len(members)}</td>'
            f'<td class="col-comp">{_esc(", ".join(comps)) or "—"}</td>'
            f'<td class="col-team">{_esc(", ".join(teams)) or "—"}</td>'
            f'<td class="col-status"><code>FAILED→FAILED</code></td>'
            f'<td class="col-verdict">{verdict_cell}</td>'
            f'<td class="col-confidence">{conf_cell}</td>'
            f'<td class="col-suspicious">{susp_cell}</td>'
            f'<td class="col-reasoning">{_esc(reasoning)}</td>'
            f'<td class="col-jira">{create_cell}</td>'
            f'</tr>'
        )
        member_rows = "".join(
            f'<tr><td><code>{m["case_id"]}</code></td><td>{_esc(m["test_case"]) or "—"}</td>'
            f'<td>{_esc(m["component_name"]) or "—"}</td>'
            f'<td class="err">{cat(m["cat_a"])}{_err_html(m["errors_a"])}</td>'
            f'<td class="err">{cat(m["cat_b"])}{_err_html(m["errors_b"])}</td></tr>'
            for m in members
        )
        rows_html.append(
            f'<tr class="cdetail" hidden><td colspan="12">'
            f'<table class="cf"><thead><tr><th>case_id</th><th>Test</th><th>Component</th>'
            f'<th>Baseline error (A — was already failing)</th>'
            f'<th>Target error (B — new reason)</th></tr></thead>'
            f'<tbody>{member_rows}</tbody></table></td></tr>'
        )

    n_overlap = sum(1 for (k, key), m in ordered if k == "sub" and key in regression)
    title = (f"Changed-failure clusters — Build A {meta.get('build_id_a')} "
             f"→ Build B {meta.get('build_id_b')}")
    doc = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>{_esc(title)}</title>
<style>{_CSS}{_EXTRA_CSS}
  main {{ max-width: 1760px; }}
</style></head><body><main>
  <h1>{_esc(title)}</h1>
  <p class="summary">
    Routine: <code>{_esc(meta.get('routine_id')) or '—'}</code> ·
    Hashes: <code>{_esc(str(meta.get('git_hash_a') or '')[:9]) or '?'}</code> →
    <code>{_esc(str(meta.get('git_hash_b') or '')[:9]) or '?'}</code> ·
    Testflow: <code>{_esc(testflow_id) or '—'}</code> ·
    Generated by <code>changed_failures.py</code>
  </p>
  <div class="note" style="padding:10px 14px;background:#fffbeb;border:1px solid #fde68a;border-radius:6px;font-size:12.5px;color:#92400e;">
    <b>The gap this fills:</b> the standard triage diff only surfaces
    PASSED→FAILED, so a test failing in <i>both</i> builds is excluded. These
    were <b>FAILED in both builds with a different reason in the target</b> —
    masked regressions, clustered by the target's Testray subtask. <b>Verdict /
    Confidence</b> are carried from the by-subtask triage run when the subtask
    is <i>also</i> a known PASSED→FAILED regression cluster — they describe that
    regression, not the changed-failures (these aren't classified). "—
    changed-failure only" means the subtask has no regression members at all.
  </div>
  <div class="totals">
    <span class="pill"><strong>Changed failures:</strong> <span class="n">{len(gap)}</span></span>
    <span class="pill"><strong>Subtasks:</strong> <span class="n">{len(ordered)}</span></span>
    <span class="pill"><strong>Overlap regression subtasks:</strong> <span class="n">{n_overlap}</span></span>
  </div>
  <div class="filters">
    <div class="filters-row">
      <label for="comp-filter">Component:</label>
      <select id="comp-filter"><option value="">All components</option></select>
      <label for="team-filter">Team:</label>
      <select id="team-filter"><option value="">All teams</option></select>
      <label for="verdict-filter">Verdict:</label>
      <select id="verdict-filter"><option value="">All verdicts</option></select>
      <label for="overlap-filter">Overlap:</label>
      <select id="overlap-filter"><option value="">All</option>
        <option value="yes">Also a regression subtask</option>
        <option value="no">Changed-failure only</option></select>
    </div>
    <div class="filters-row">
      <label for="search-filter">Search:</label>
      <input id="search-filter" type="search" placeholder="filter by test, component, team, ticket, reason… (Esc to clear)" autocomplete="off">
      <span class="visible-count" id="filter-count"></span>
    </div>
  </div>
  <p class="hint">One row per subtask. Click a row to expand its baseline-vs-target errors; click a column header to sort.</p>
  <table class="st"><thead><tr>
    <th class="col-idx"></th><th class="col-sid">Subtask</th>
    <th class="col-link">Testray</th>
    <th class="col-n" title="Changed failures in this subtask">Tests</th>
    <th class="col-comp">Component</th><th class="col-team">Team</th>
    <th class="col-status">Status</th>
    <th class="col-verdict" title="Verdict from the regression run when this subtask also has PASSED→FAILED members">Verdict</th>
    <th class="col-confidence">Confidence</th>
    <th class="col-suspicious">Suspicious commits</th>
    <th class="col-reasoning">Reasoning</th>
    <th class="col-jira">Create Jira ticket</th>
  </tr></thead><tbody>
  {''.join(rows_html)}
  </tbody></table>
</main>
<script>{_FILTER_JS}</script>
<script>{_SORT_JS}</script>
</body></html>"""
    out.write_text(doc)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Changed-failure gap report, clustered by subtask.")
    ap.add_argument("--baseline-build-id", type=int, default=469572134)
    ap.add_argument("--target-build-id", type=int, default=482461141)
    ap.add_argument("--baseline-hash", default=None)
    ap.add_argument("--target-hash", default=None)
    ap.add_argument("--testflow-id", default=None,
                    help="Target testflow id for subtask deep-links (e.g. 482554602).")
    ap.add_argument("--run-dir", type=Path, default=None,
                    help="By-subtask triage run dir to cross-reference (relates "
                         "clusters to known regression subtasks + their verdicts).")
    ap.add_argument("--use-cache", action="store_true",
                    help="Reuse the cached fail-both set if present (skips the API fetch).")
    ap.add_argument("--jira-parent", default=_JIRA_PARENT_KEY,
                    help=f"Parent ticket for the prefilled Jira drafts "
                         f"(default {_JIRA_PARENT_KEY}).")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()

    cfg = load_config()
    reporter = _jira_myself_account_id(cfg)
    runs_dir = Path(__file__).resolve().parent / "runs"
    runs_dir.mkdir(exist_ok=True)
    cache_path = runs_dir / f".cf_cache_{args.baseline_build_id}_{args.target_build_id}.pkl"

    gap = find_changed_failures(args.baseline_build_id, args.target_build_id,
                                cfg, cache_path, args.use_cache)
    regression = _load_regression_subtasks(args.run_dir)
    if regression:
        print(f"   cross-referencing {len(regression)} regression subtasks from {args.run_dir.name}")

    db_cfg = cfg["databases"]["testray"]
    bm_a = fetch_build_metadata(args.baseline_build_id, db_cfg) or {}
    bm_b = fetch_build_metadata(args.target_build_id, db_cfg) or {}
    meta = {
        "build_id_a": args.baseline_build_id, "build_id_b": args.target_build_id,
        "git_hash_a": args.baseline_hash or bm_a.get("git_hash"),
        "git_hash_b": args.target_hash or bm_b.get("git_hash"),
        "routine_id": bm_a.get("routine_id") or bm_b.get("routine_id"),
    }

    ticket_map = _build_ticket_commit_map(
        cfg.get("git", {}).get("repo_path"), meta["git_hash_a"], meta["git_hash_b"])
    if ticket_map:
        print(f"   ticket→commit map: {len(ticket_map)} tickets in range")

    out = args.out or (runs_dir / f"changed_failures_{args.baseline_build_id}_{args.target_build_id}.html")
    csv_out = out.with_suffix(".csv")
    cols = ["case_id", "subtask_id", "test_case", "component_name", "team_name",
            "cat_a", "cat_b", "errors_a", "errors_b"]
    gap[cols].to_csv(csv_out, index=False)
    render_report(gap, meta, regression, args.testflow_id, reporter, args.jira_parent,
                  ticket_map, out)
    print(f"\nChanged failures: {len(gap)}  ·  Report: {out}  ·  CSV: {csv_out}")


if __name__ == "__main__":
    main()
