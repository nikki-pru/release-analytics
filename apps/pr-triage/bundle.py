"""
apps/pr-triage/bundle.py

Write a Claude Code bundle to apps/pr-triage/runs/r_<id>/.

The bundle is the v0.3 deliverable — a self-contained directory a
developer can open in their Claude Code session. Same shape as
apps/triage/runs/ so the muscle memory transfers.

Files written:
  run.yml             metadata
  diff_full.diff      unfiltered PR diff (the source of truth — hunks.txt
                      is a derived view of this for orientation)
  hunks.txt           per-unique-row matched hunks
  unique_rows.csv      structured row data for unique rows
  prompt.md           classification instructions
  results.schema.json schema for results.json (which the developer writes)
"""

import csv
import datetime as dt
import json
import re
from pathlib import Path

import yaml


_VERDICTS = ["PR_CAUSED", "NEEDS_REVIEW", "FALSE_POSITIVE"]


_RESULTS_SCHEMA: dict = {
    "$schema":              "https://json-schema.org/draft/2020-12/schema",
    "title":                "PRTriageResults",
    "type":                 "object",
    "required":             ["run_id", "classifier", "results"],
    "additionalProperties": False,
    "properties": {
        "run_id":     {"type": "string"},
        "classifier": {"type": "string"},
        "notes":      {"type": "string"},
        "results": {
            "type": "array",
            "items": {
                "type":                 "object",
                "required":             ["case_id", "classification",
                                         "confidence", "reason"],
                "additionalProperties": False,
                "properties": {
                    "case_id":         {"type": "integer"},
                    "classification":  {"enum": _VERDICTS},
                    "confidence":      {"enum": ["high", "medium", "low"]},
                    "culprit_file":    {"type": "string"},
                    "specific_change": {"type": "string"},
                    "reason":          {"type": "string"},
                },
            },
        },
    },
}


def make_run_id(target_branch: str, target_build_id: int) -> str:
    """Filesystem-safe run id: r_<UTC ts>_<branch>_<build>."""
    ts = dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    branch_safe = re.sub(r"[^A-Za-z0-9._-]", "-", target_branch)
    return f"r_{ts}_{branch_safe}_{target_build_id}"


def write_bundle(
    run_id:        str,
    args,
    build:         dict,
    diff_summary:  dict,
    diff_text:     str,
    rows:          list[dict],
    runs_root:     Path,
) -> Path:
    """Write the bundle directory and return its path. Idempotent — if
    the directory already exists, files are overwritten."""
    run_dir = runs_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    unique_rows = [r for r in rows if r["verdict"] != "NOT_UNIQUE"]
    counts = {v: sum(1 for r in rows if r["verdict"] == v) for v in
              ("UNIQUE_NEW_TEST", "UNIQUE_NEW_ERROR", "NOT_UNIQUE")}

    _write_run_yml(run_dir / "run.yml", args, build, diff_summary, counts, run_id)
    (run_dir / "diff_full.diff").write_text(diff_text)
    _write_hunks_txt(run_dir / "hunks.txt", unique_rows)
    _write_unique_rows_csv(run_dir / "unique_rows.csv", unique_rows)
    (run_dir / "results.schema.json").write_text(
        json.dumps(_RESULTS_SCHEMA, indent=2)
    )
    _write_prompt_md(run_dir / "prompt.md", run_id, args, build,
                     diff_summary, counts, unique_rows)
    return run_dir


def _write_run_yml(path, args, build, diff_summary, counts, run_id) -> None:
    meta = {
        "run_id":          run_id,
        "app":             "pr-triage",
        "version":         "0.3",
        "classifier":      "agent:claude-opus-4-7",
        "target_branch":   args.target_branch,
        "target_source":   args.target_source,
        "target_build_id": args.target_build_id,
        "base_branch":     args.base_branch,
        "build": {
            "build_id":   build["build_id"],
            "project_id": build["project_id"],
            "routine_id": build["routine_id"],
            "duedate":    build["duedate"],
            "name":       build["name"],
        },
        "diff": {
            "merge_base":    diff_summary["merge_base"],
            "files_changed": diff_summary["files"],
            "lines_changed": diff_summary["lines"],
        },
        "unique_counts": {
            "unique_new_test":  counts["UNIQUE_NEW_TEST"],
            "unique_new_error": counts["UNIQUE_NEW_ERROR"],
            "not_unique":       counts["NOT_UNIQUE"],
        },
        "prepared_at": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    path.write_text(yaml.safe_dump(meta, sort_keys=False))


def _write_unique_rows_csv(path, unique_rows) -> None:
    fields = ["case_id", "verdict", "case_name", "component", "team",
              "flaky", "error_hash", "prior_failure_count",
              "prior_distinct_hashes", "matched_files_count", "error"]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in unique_rows:
            ev = r["evidence"]
            w.writerow({
                "case_id":               r["case_id"],
                "verdict":               r["verdict"],
                "case_name":             r["case_name"],
                "component":             r["component"],
                "team":                  r["team"],
                "flaky":                 r["flaky"],
                "error_hash":            ev["target_hash"],
                "prior_failure_count":   ev["prior_failure_count"],
                "prior_distinct_hashes": ev["prior_distinct_hashes"],
                "matched_files_count":   len(r.get("matched_files", [])),
                "error":                 (r["error"] or "").replace("\n", " ⏎ "),
            })


def _write_hunks_txt(path, unique_rows) -> None:
    """Per-unique-row matched hunks, separated by row markers. Easier to
    scan than diff_full.diff when triaging row-by-row."""
    parts: list[str] = []
    for r in unique_rows:
        matched = r.get("matched_files", [])
        parts.append(
            f"{'=' * 72}\n"
            f"case_id:    {r['case_id']}\n"
            f"test:       {r['case_name']}\n"
            f"verdict:    {r['verdict']}\n"
            f"hash:       {r['evidence']['target_hash']}\n"
            f"matched:    {len(matched)} file(s)\n"
            f"{'=' * 72}\n"
        )
        if not matched:
            parts.append("  (no matched files — failure may be transitive "
                         "or unrelated to diff)\n\n")
            continue
        for fd in matched:
            parts.append(fd.hunks_text)
            if not fd.hunks_text.endswith("\n"):
                parts.append("\n")
        parts.append("\n")
    path.write_text("".join(parts))


def _write_prompt_md(
    path, run_id, args, build, diff_summary, counts, unique_rows
) -> None:
    body = f"""# PR-Triage — Claude Code session

You are the classifier for this run. Read this file end-to-end, then
write `results.json` next to it (schema in `results.schema.json`).

## Run

- run_id:          `{run_id}`
- target_branch:   `{args.target_branch}`
- base_branch:     `{args.base_branch}`
- target_build_id: `{args.target_build_id}`
- project_id:      `{build['project_id']}`
- routine_id:      `{build['routine_id']}`
- merge_base:      `{diff_summary['merge_base']}`
- diff:            {diff_summary['files']} files, {diff_summary['lines']} changed lines

## Uniqueness summary

- New test failure (no test history in current project): **{counts['UNIQUE_NEW_TEST']}**
- Failure unique to this PR: **{counts['UNIQUE_NEW_ERROR']}**
- Failure already in upstream (not classified — already known): {counts['NOT_UNIQUE']}

You only classify the **{counts['UNIQUE_NEW_TEST'] + counts['UNIQUE_NEW_ERROR']}**
unique rows below. Recurring/upstream failures are out of scope — by
construction they're not introduced by this PR.

## Files in this bundle

| File | Role |
|---|---|
| `run.yml`             | Run metadata. |
| `unique_rows.csv`      | Structured row data — `case_id`, error hash, match counts. |
| `hunks.txt`           | Matched diff hunks per unique row. Start here. |
| `diff_full.diff`      | Unfiltered PR diff. Use when `hunks.txt` looks too narrow. |
| `results.schema.json` | Schema for the `results.json` you will write. |

## Classification rubric

For each unique row, decide one of:

- **`PR_CAUSED`** — High-confidence: a hunk in this PR plausibly causes
  this failure. Name the specific file in `culprit_file` and describe
  the change in `specific_change`. *Required* fields when
  classification = PR_CAUSED.
- **`NEEDS_REVIEW`** — The failure could plausibly trace to the diff
  but the link is indirect (transitive dep, two candidate causes,
  ambiguous error message). Default for medium-confidence.
- **`FALSE_POSITIVE`** — The failure is unrelated to the PR. Examples:
  classic flake patterns (TEST_SETUP_ERROR, Selenium element-not-found
  timeouts, performance tolerance overshoots), env/infra failures,
  failures in components nowhere near the diff.

### Evidence to consider, in order

1. The failing test's error message (in `unique_rows.csv` or below).
2. `hunks.txt` for files matched to the test by name/component tokens.
3. `diff_full.diff` if `hunks.txt` is empty or too narrow — a test can
   fail because of a transitive dep change, even if its file isn't in
   the diff.
4. Whether the test is `flaky` — flaky + classic flake error pattern
   strongly suggests FALSE_POSITIVE.

### Confidence

- `high` — direct, traceable cause-effect link to a specific hunk.
- `medium` — plausible link but indirect (transitive, multi-cause).
- `low` — gut feeling, no concrete evidence. Use sparingly.

## How to write results.json

Validate against `results.schema.json`. One object per unique row:

```json
{{
  "run_id":     "{run_id}",
  "classifier": "agent:claude-opus-4-7",
  "results": [
    {{
      "case_id":         12345,
      "classification":  "PR_CAUSED",
      "confidence":      "high",
      "culprit_file":    "modules/apps/foo/src/main/java/.../Bar.java",
      "specific_change": "Bar.java:42 removed null check that handled empty input",
      "reason":          "Test calls getCMSItemSelectorFilters which Bar.bar() now NPEs on empty list."
    }}
  ]
}}
```

Required fields: `case_id`, `classification`, `confidence`, `reason`.
`culprit_file` and `specific_change` are required when
`classification = PR_CAUSED` — without them the future submit step
will reject the row.

---

## Unique rows ({len(unique_rows)} to classify)

Rows are dumped below for in-line reading. Same data is in
`unique_rows.csv` for programmatic use.

"""
    parts: list[str] = [body]
    for r in unique_rows:
        ev = r["evidence"]
        parts.append(
            f"### case_id `{r['case_id']}` — `{r['case_name']}`\n\n"
            f"- verdict (uniqueness):       `{r['verdict']}`\n"
            f"- component / team:        {r['component']} / {r['team']}\n"
            f"- flaky flag:              {r['flaky']}\n"
            f"- error_hash:              `{ev['target_hash']}`\n"
        )
        if r["verdict"] == "UNIQUE_NEW_ERROR":
            parts.append(
                f"- prior failures (project): {ev['prior_failure_count']} "
                f"(distinct hashes: {ev['prior_distinct_hashes']})\n"
            )
        matched = r.get("matched_files", [])
        parts.append(f"- matched files in diff:    {len(matched)}\n")
        for fd in matched:
            parts.append(f"    - `{fd.path}` ({fd.changed_lines} lines)\n")
        parts.append("\n**error**\n\n```\n")
        parts.append((r["error"] or "")[:2000])
        parts.append("\n```\n\n")
    path.write_text("".join(parts))
