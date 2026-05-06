"""
apps/pr-triage/run.py

v0.1: uniqueness check against project history.
v0.2: fetch PR diff and attach matched hunks per unique failure.
v0.3: write a Claude Code bundle (runs/r_<id>/) so a developer can
      reason over unique failures + matched hunks in their session.

Flow:
  1. Fetch target build metadata (project_id, duedate) via Testray API.
  2. Fetch failing caseresults for the target build via Testray API.
  3. Resolve testrayCaseResultId → case_id via working_db (PK lookup).
  4. For each failing case, query prior FAILED history in the project
     and classify UNIQUE_NEW_TEST / UNIQUE_NEW_ERROR / NOT_UNIQUE.
  5. (v0.2) Fetch PR diff. For each unique row, extract test-name tokens
     and match against diff file paths.
  6. Print the human-readable report to stdout.
  7. (v0.3) Write a Claude Code bundle for human/LLM reasoning.

  python3 apps/pr-triage/run.py \\
    --target-branch  PR-38301 \\
    --target-source  api \\
    --target-build-id 471865557 \\
    --base-branch    release-2026.q1
"""

import argparse
import sys
from pathlib import Path

# Allow running as `python3 -m apps.pr-triage.run` AND
# `python3 apps/pr-triage/run.py` (the bash wrapper uses the latter).
sys.path.insert(0, str(Path(__file__).resolve().parent))

import yaml

from fetch_target import fetch_build_meta, fetch_failing_caseresults
from normalize    import normalize_error, error_signature_hash
from unique_scoring import get_working_db_conn, fetch_history, resolve_case_ids
from pr_diff      import fetch_diff, parse_diff, FileDiff
from hunk_match   import extract_test_tokens, match_files, format_inline
from bundle       import make_run_id, write_bundle


def _load_root_config() -> dict:
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "config" / "config.yml"
        if candidate.exists():
            with open(candidate) as f:
                return yaml.safe_load(f)
    raise FileNotFoundError("config.yml not found")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="pr-triage",
        description="Uniqueness-based PR-triage for Liferay Release Analytics. "
                    "Classifies failing tests against project history, then "
                    "matches unique failures against the PR's diff.",
    )
    p.add_argument("--target-branch",   required=True,
                   help="Branch in liferay-portal (e.g. PR-38301).")
    p.add_argument("--target-source",   required=True, choices=["api"],
                   help="Where to read the target build from. v0.1: api only.")
    p.add_argument("--target-build-id", required=True, type=int,
                   help="Testray build id (e.g. 471865557).")
    p.add_argument("--base-branch",     required=True,
                   help="Base branch the PR targets (e.g. release-2026.q1). "
                        "Required — wrong base produces a garbage diff.")
    return p.parse_args()


def classify(target_error: str, history: list[dict]) -> tuple[str, dict]:
    """Return (verdict, evidence) for a failing case given its prior history."""
    target_hash = error_signature_hash(target_error)

    if not history:
        return "UNIQUE_NEW_TEST", {
            "target_hash":            target_hash,
            "prior_failure_count":    0,
            "prior_distinct_hashes":  0,
        }

    prior_hashes = {error_signature_hash(h["errors"]) for h in history}
    if target_hash not in prior_hashes:
        return "UNIQUE_NEW_ERROR", {
            "target_hash":            target_hash,
            "prior_failure_count":    len(history),
            "prior_distinct_hashes":  len(prior_hashes),
        }

    return "NOT_UNIQUE", {
        "target_hash":            target_hash,
        "prior_failure_count":    len(history),
        "prior_distinct_hashes":  len(prior_hashes),
    }


# Display labels for verdicts. Machine codes (the dict keys) stay
# stable for internal use, results.json, and future bundle schemas;
# only the labels here are shown to humans.
_VERDICT_LABEL: dict[str, str] = {
    "UNIQUE_NEW_TEST":  "New test failure (no test history in current project)",
    "UNIQUE_NEW_ERROR": "Failure unique to this PR",
    "NOT_UNIQUE":       "Failure already in upstream",
}


def _truncate(text: str | None, limit: int = 500) -> str:
    if not text:
        return ""
    text = text.replace("\n", " ⏎ ").strip()
    return text if len(text) <= limit else text[:limit] + " …"


def render_report(
    args: argparse.Namespace,
    build: dict,
    rows: list[dict],
    diff_summary: dict,
) -> None:
    by_verdict: dict[str, list[dict]] = {
        "UNIQUE_NEW_TEST":  [],
        "UNIQUE_NEW_ERROR": [],
        "NOT_UNIQUE":       [],
    }
    for r in rows:
        by_verdict[r["verdict"]].append(r)

    print("=" * 64)
    print("PR-Triage — Uniqueness check + diff match")
    print("=" * 64)
    print(f"Build:         {build['build_id']}")
    print(f"Project:       {build['project_id']}")
    print(f"Build duedate: {build['duedate']}")
    print(f"Branch:        {args.target_branch}  →  {args.base_branch}")
    print(f"PR diff:       {diff_summary['files']} files, "
          f"{diff_summary['lines']} changed lines "
          f"(merge-base {diff_summary['merge_base'][:12]} … "
          f"{args.target_branch})")
    print()
    print(f"Failed caseresults: {len(rows)}")
    print()
    print(f"  {len(by_verdict['UNIQUE_NEW_TEST']):>3}  "
          f"{_VERDICT_LABEL['UNIQUE_NEW_TEST']}")
    print(f"  {len(by_verdict['UNIQUE_NEW_ERROR']):>3}  "
          f"{_VERDICT_LABEL['UNIQUE_NEW_ERROR']}")
    print(f"  {len(by_verdict['NOT_UNIQUE']):>3}  "
          f"{_VERDICT_LABEL['NOT_UNIQUE']}")
    print("=" * 64)
    print()

    for verdict in ("UNIQUE_NEW_TEST", "UNIQUE_NEW_ERROR"):
        for r in by_verdict[verdict]:
            ev = r["evidence"]
            print(f"[{_VERDICT_LABEL[verdict]}]")
            print(f"  case_id:           {r['case_id']}")
            print(f"  test:              {r['case_name']}")
            print(f"  component:         {r['component']}")
            print(f"  team:              {r['team']}")
            print(f"  flaky:             {r['flaky']}")
            print(f"  hash:              {ev['target_hash']}")
            if verdict == "UNIQUE_NEW_ERROR":
                print(f"  prior_failures:    {ev['prior_failure_count']}")
                print(f"  prior_distinct_hashes: {ev['prior_distinct_hashes']}")
            print(f"  error:             {_truncate(r['error'])}")
            print(format_inline(r["matched_files"]), end="")
            print()


def main() -> int:
    args = parse_args()
    cfg  = _load_root_config()

    print(f"→ fetching build {args.target_build_id} metadata …", file=sys.stderr)
    build = fetch_build_meta(args.target_build_id, cfg["testray"])
    print(
        f"  build {build['build_id']} · project {build['project_id']} · "
        f"duedate {build['duedate']}",
        file=sys.stderr,
    )

    print(f"→ fetching failing caseresults …", file=sys.stderr)
    failing = fetch_failing_caseresults(args.target_build_id, cfg["testray"])

    if not failing:
        print(f"\nNo FAILED caseresults on build {args.target_build_id}. "
              "Nothing to classify.")
        return 0

    print(f"→ checking uniqueness against project {build['project_id']} history …",
          file=sys.stderr)
    rows: list[dict] = []
    with get_working_db_conn() as conn:
        # The rich Testray endpoint returns testrayCaseResultId but not
        # case_id. Batch-resolve case_ids in one PK lookup.
        caseresult_ids = [
            int(it["testrayCaseResultId"]) for it in failing
            if it.get("testrayCaseResultId")
        ]
        cr_to_case = resolve_case_ids(conn, caseresult_ids)
        print(f"  resolved case_ids for {len(cr_to_case)}/{len(caseresult_ids)} "
              "caseresults", file=sys.stderr)

        for it in failing:
            cr_id   = int(it.get("testrayCaseResultId") or 0)
            case_id = cr_to_case.get(cr_id)
            if not case_id:
                # Surface the row instead of silently dropping. Likely a
                # caseresult that doesn't exist in the local working_db
                # snapshot (newer than the last restore).
                rows.append({
                    "case_id":    None,
                    "case_name":  it.get("testrayCaseName") or "",
                    "component":  it.get("testrayComponentName") or "",
                    "team":       it.get("testrayTeamName") or "",
                    "flaky":      bool(it.get("flaky")),
                    "error":      it.get("error") or "",
                    "verdict":    "UNIQUE_NEW_TEST",
                    "evidence":   {
                        "target_hash":           error_signature_hash(it.get("error")),
                        "prior_failure_count":   0,
                        "prior_distinct_hashes": 0,
                        "note": f"caseresult_id {cr_id} not in working_db — "
                                "treated as new test by default",
                    },
                })
                continue

            history = fetch_history(
                conn,
                project_id=build["project_id"],
                case_id=case_id,
                before_duedate=build["duedate"],
            )
            verdict, ev = classify(it.get("error"), history)
            rows.append({
                "case_id":    case_id,
                "case_name":  it.get("testrayCaseName") or "",
                "component":  it.get("testrayComponentName") or "",
                "team":       it.get("testrayTeamName") or "",
                "flaky":      bool(it.get("flaky")),
                "error":      it.get("error") or "",
                "verdict":    verdict,
                "evidence":   ev,
            })

    # ---- v0.2: PR diff + per-unique-row hunk match -----------------------
    print(f"→ fetching PR diff: {args.base_branch} … {args.target_branch}",
          file=sys.stderr)
    portal_repo = Path(cfg["git"]["repo_path"]).expanduser()
    diff_text   = fetch_diff(portal_repo, args.base_branch, args.target_branch)
    file_diffs  = parse_diff(diff_text)
    diff_summary = _diff_summary(portal_repo, args, file_diffs)
    print(f"  {diff_summary['files']} files, "
          f"{diff_summary['lines']} changed lines",
          file=sys.stderr)

    for r in rows:
        if r["verdict"] == "NOT_UNIQUE":
            r["matched_files"] = []
            continue
        tokens  = extract_test_tokens(r["case_name"], r["component"], r["team"])
        matched = match_files(file_diffs, tokens)
        r["matched_files"] = matched
        r["match_tokens"]  = tokens

    render_report(args, build, rows, diff_summary)

    # ---- v0.3: write Claude Code bundle ---------------------------------
    run_id    = make_run_id(args.target_branch, args.target_build_id)
    runs_root = Path(__file__).resolve().parent / "runs"
    run_dir   = write_bundle(
        run_id=run_id,
        args=args,
        build=build,
        diff_summary=diff_summary,
        diff_text=diff_text,
        rows=rows,
        runs_root=runs_root,
    )
    rel = run_dir.relative_to(Path(__file__).resolve().parents[2])
    unique_count = sum(1 for r in rows if r["verdict"] != "NOT_UNIQUE")
    print()
    print("─" * 64)
    print(f"Bundle written: {rel}")
    print(f"Open `{rel}/prompt.md` in Claude Code to classify "
          f"the {unique_count} unique row(s).")
    print(f"Write your verdicts to `{rel}/results.json` "
          "(schema in results.schema.json).")
    print("─" * 64)
    return 0


def _diff_summary(
    portal_repo: Path, args: argparse.Namespace, file_diffs: list[FileDiff]
) -> dict:
    import subprocess
    merge_base = subprocess.check_output(
        ["git", "-C", str(portal_repo), "merge-base",
         args.base_branch, args.target_branch],
        text=True,
    ).strip()
    return {
        "merge_base": merge_base,
        "files":      len(file_diffs),
        "lines":      sum(fd.changed_lines for fd in file_diffs),
    }


if __name__ == "__main__":
    sys.exit(main())
