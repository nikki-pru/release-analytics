# apps/pr-triage

Uniqueness-based PR-triage for Liferay Release Analytics.

Answers the question: **"Which test failures in this build are
historically unique — and could be related to this PR?"**

Sister app to `apps/triage` (build-triage). Where build-triage compares
two builds and surfaces PASSED→FAILED transitions, PR-triage compares
*one* build against the project's full failure history. There is no
clean baseline build — the project's history *is* the baseline.

A failure is **unique** if no prior build in the project has produced
the same `(case_id, normalized_error)` signature. Unique failures are
the candidates worth investigating against the PR's diff. Non-unique
failures (recurring flakes, persistent regressions) are silently
filtered out.

---

## Status

Built up to **v0.3** — uniqueness + diff match + Claude Code bundle. The
RAP layering thesis (*source is data, logic is code, reasoning is AI,
decisions are human*) is fully expressed: data and code do the
narrowing, the human (with Claude Code) does the reasoning, no auto-
decisions yet.

| Phase | Scope | Status |
|---|---|---|
| v0.1 | Fetch failing rows → normalize errors → check uniqueness → print report | done |
| v0.2 | Fetch PR diff via `git diff merge-base(base, target) target` → match hunks per unique row → inline in report | done |
| v0.3 | Write Claude Code bundle (`runs/r_<id>/`) — prompt.md, hunks.txt, unique_rows.csv, results.schema.json | done |
| v0.4 | API mode (consumes the same bundle, no human-in-the-loop) | planned |
| v0.5 | Persist verdicts to `fact_pr_triage_results` (staging-grade — eventual destination is Testray itself) | planned |

---

## Usage

```bash
bash apps/pr-triage/run.sh \
  --target-branch  PR-38301 \
  --target-source  api \
  --target-build-id 471865557 \
  --base-branch    release-2026.q1
```

### Arguments

| Argument | Required | Description |
|---|---|---|
| `--target-branch`   | yes | Branch in liferay-portal. Must exist locally. |
| `--target-source`   | yes | Where the target build is read from. v0.3 supports `api` only; `tar`/`db` come later. |
| `--target-build-id` | yes | Testray build id (e.g. `471865557`). |
| `--base-branch`     | yes | Base branch the PR targets (e.g. `release-2026.q1`). Required — wrong base silently produces a garbage diff. |

Both branches must exist in the local liferay-portal checkout
(`config.yml: git.repo_path`). The script validates each up front and
errors out otherwise. The project ID is resolved automatically from
the build's metadata via the Testray API.

---

## Configuration

`config/config.yml` requires:

- `testray.base_url` + `testray.client_id` + `testray.client_secret`
  for the API
- `databases.testray_working_db` for uniqueness queries against the raw
  Testray backup (see `config.yml.example`)
- `git.repo_path` pointing at a local liferay-portal checkout

Per `db/testray_analytical_README.md`, `testray_working_db` is
intended-droppable after the analytical bootstrap. PR-triage needs it
restored — the truncated `errors` column on `testray_analytical` isn't
sufficient for signature normalization.

---

## How it works

```
  Testray API:  /o/c/builds/{id}                  → project_id, duedate
                /o/testray-rest/v1.0/             → failing rows + errors
                  testray-case-result/{build}
                          ↓
  working_db:   resolve testrayCaseResultId → case_id   (PK lookup)
                          ↓
  per failing case:
                fetch FAILED history (project, duedate < target)
                normalize + md5 hash
                          ↓
                UNIQUE_NEW_TEST  / UNIQUE_NEW_ERROR / NOT_UNIQUE
                          ↓
  liferay-portal git: git diff $(merge-base BASE TARGET) TARGET
                          ↓
                per-unique-row token-substring match against diff paths
                          ↓
                stdout report  +  runs/r_<id>/ bundle for Claude Code
```

### Files

| File | Role |
|---|---|
| `run.sh`             | Bash entry. Validates portal repo + both branches. |
| `run.py`             | Orchestrator. fetch → resolve → classify → diff → match → bundle. |
| `fetch_target.py`    | Testray API: build metadata + failing caseresults. |
| `normalize.py`       | Error signature normalization rules + md5. Single source of truth. |
| `unique_scoring.py`         | psycopg2 helpers + history SQL + caseresult→case_id batch resolver. |
| `pr_diff.py`         | `git diff merge-base(base, target)..target`; parses unified diff into per-file blocks. |
| `hunk_match.py`      | Token extraction from test name + token-substring match against diff paths. |
| `bundle.py`          | Writes `runs/r_<id>/` — run.yml, diff_full.diff, hunks.txt, unique_rows.csv, prompt.md, results.schema.json. |
| `requirements.txt`   | PyYAML + psycopg2-binary. No `requests` — uses stdlib `urllib`. |

### Reuse from `apps/triage`

PR-triage is a separate app, **not** a fork of triage. Patterns are
copied where they apply (Testray OAuth2, paginated fetch, config
loading, psycopg2 helpers, run-dir layout) but no shared code is
imported. Once both apps stabilize, candidates for extraction to
`apps/_common/`:

- Testray OAuth2 + paginated fetch
- `/o/c/builds/{id}` and `/o/c/cases/{id}` lookups
- psycopg2 connection helpers
- portal-repo diff helpers
- prompt.md / results.schema.json conventions

This is tracked in the project backlog.

---

## Sample output

```
================================================================
PR-Triage — Uniqueness check + diff match
================================================================
Build:         471865557
Project:       456316917
Build duedate: 2026-04-29T03:14:02
Branch:        PR-38301  →  release-2026.q1
PR diff:       12 files, 318 changed lines (merge-base abc123def456 … PR-38301)

Failed caseresults: 47

    3  New test failure (no test history in current project)
   12  Failure unique to this PR
   32  Failure already in upstream
================================================================

[Failure unique to this PR]
  case_id:               789012
  test:                  :dxp:apps:foo:bar:packageRunTest
  component:             SomeComponent
  team:                  SomeTeam
  flaky:                 False
  hash:                  8a3fe1...
  prior_failures:        8
  prior_distinct_hashes: 3
  error:                 NullPointerException at Bar.bar(Bar.java:42) ...
  matched_files: 2  matched_hunks: 3
  ── modules/apps/foo/src/main/java/.../Bar.java (2 hunks, 14 changed lines) ──
    @@ -42,7 +42,7 @@
    -    if (input != null) {
    +    // (null check removed)
    ...

────────────────────────────────────────────────────────────────
Bundle written: apps/pr-triage/runs/r_20260506T120000Z_PR-38301_471865557
Open `…/prompt.md` in Claude Code to classify the 15 unique row(s).
Write your verdicts to `…/results.json` (schema in results.schema.json).
────────────────────────────────────────────────────────────────
```

The stdout report is for quick eyeball validation; the bundle is what
you actually classify against. Open `prompt.md` in your Claude Code
session — it carries the rubric (`PR_CAUSED` / `NEEDS_REVIEW` /
`FALSE_POSITIVE`), the failing rows, and the matched hunks.

---

## The Claude Code bundle

`runs/r_<ts>_<branch>_<build>/` — same shape as `apps/triage/runs/`
so the muscle memory transfers.

| File | Role |
|---|---|
| `run.yml`             | Run metadata: branch, base, build, project, uniqueness counts. |
| `unique_rows.csv`      | One row per unique failure: `case_id`, error hash, match counts. |
| `hunks.txt`           | Matched diff hunks per unique row. Start here when classifying. |
| `diff_full.diff`      | Unfiltered PR diff. Use when `hunks.txt` looks too narrow (transitive deps). |
| `prompt.md`           | Classification instructions for the Claude Code session. |
| `results.schema.json` | Schema for the `results.json` you write back. |

Verdict labels: `PR_CAUSED` / `NEEDS_REVIEW` / `FALSE_POSITIVE`. The
schema requires `culprit_file` and `specific_change` whenever
`classification = PR_CAUSED` — a future submit step (v0.5) will
reject rows without them.

---

## Limitations and known caveats

- **Truncated working_db.** If the local `testray_working_db` snapshot
  is older than the target build's commit, uniqueness is judged against
  an incomplete history. The script doesn't currently check snapshot
  freshness — assume the most recent backup is restored.
- **Empty errors.** Caseresults with empty `error` fields hash to the
  same empty signature. They'll cluster as NOT_UNIQUE with each other.
  If a project has many empty-error failures this skews counts. Surface
  this only if it matters in practice.
- **case_id resolution gap.** Target rows whose caseresult_id isn't in
  working_db (newer than the snapshot) are flagged UNIQUE_NEW_TEST with
  a `note` in evidence. Better than dropping them silently; not the
  same as truly verifying they're new.
- **Normalization rule set.** Intentionally short
  (timestamps, hex addrs, thread/pid, frame line numbers, whitespace).
  Iterate as we see false-uniqueness hits during validation.
- **Project scope.** PoC is project `456316917`. Other projects work
  the same way — auto-resolved from build metadata.
- **Hunk match heuristic.** Token-substring matching on test name +
  component / team. Misses transitive-dep failures where the test's
  name doesn't match the changed file (a known weakness — see
  `apps/triage/CLAUDE.md` "transitive deps" notes for the same issue
  in build-triage). The bundle includes `diff_full.diff` so the
  classifier has a fallback.
- **Empty matched_files for unique rows.** Information, not error: the
  failure is unique but doesn't obviously line up with the diff. Could
  be transitive, could be a flake misclassified as unique. Worth
  flagging in classification.
