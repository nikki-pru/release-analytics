# PR-Triage — Claude Code workflow

You are about to classify failing tests in a Testray build against
the diff of a PR in liferay-portal. The orchestrator (`run.sh`) has
already produced the run bundle this session is reading from; your
job is reasoning, not data collection.

Per the RAP layering thesis: **source is data, logic is code,
reasoning is AI, decisions are human.** This document drives the
"reasoning" step. The unique-failure narrowing has already happened
in code; the matched diff hunks are already attached. You decide
PR-attribution per row, the user reviews and decides.

Load `.claude/skills/pr-triage.skill` at the start of any session
for the full schema + heuristic reference. This file is the
session driver.

---

## Before you start classifying

Walk through these checks. **Do not start classifying until the
user confirms** — straight-to-classification on a misread bundle
wastes the human's review time.

1. **Read `run.yml`** — confirm `target_branch`, `base_branch`,
   `target_build_id`, `project_id`. Wrong branches silently produce
   garbage matches.
2. **Read the uniqueness counts.** If `unique_new_test + unique_new_error`
   is zero, there's nothing to classify — surface this and stop.
3. **Spot-check `diff_full.diff` size.** A diff with thousands of
   files changed and a tiny `hunks.txt` is a sign tokens are too
   narrow — flag this before classifying every row as
   FALSE_POSITIVE for "no matched files."
4. **Confirm `target_build_id` is actually on this PR's branch.**
   If the build was cut from base before the PR landed, no failure
   can be PR-caused by construction. Surface this if `merge_base`
   in `run.yml` is older than the build's `duedate`.

After these checks, summarize what you found and ask the user
whether to proceed.

---

## The bundle

Everything you need is in `runs/r_<id>/`:

| File | What it is |
|---|---|
| `run.yml`             | Run metadata. Read first. |
| `unique_rows.csv`      | One row per unique failure to classify. |
| `hunks.txt`           | Matched diff hunks per unique row. Start here when classifying. |
| `diff_full.diff`      | Unfiltered PR diff. Use when `hunks.txt` is empty or too narrow. |
| `prompt.md`           | Per-row inline data — same as `unique_rows.csv` plus errors and matched paths. |
| `results.schema.json` | The JSON shape you write to `results.json`. |

You do **not** classify rows under "Failure already in upstream"
(`NOT_UNIQUE` in the data). Those are recurring or pre-existing
failures and by construction not introduced by this PR — already
filtered out of the rows you see.

---

## Classification rubric

For each unique row, decide one of:

- **`PR_CAUSED`** — A hunk in this PR plausibly causes this failure.
  Required when chosen: `culprit_file` (specific path from the diff)
  and `specific_change` (one line: what about it broke this test).
  Default to high confidence; if you're at medium confidence,
  classify NEEDS_REVIEW instead.
- **`NEEDS_REVIEW`** — The failure could plausibly trace to the diff
  but the link is indirect (transitive dep, two candidate causes,
  ambiguous error message). Default for medium-confidence calls.
  Always include candidate cause(s) in `specific_change` so the
  human reviewer has a starting point.
- **`FALSE_POSITIVE`** — The failure is unrelated to the PR. Examples:
  classic flake patterns (TEST_SETUP_ERROR, Selenium element-not-found,
  performance tolerance overshoots), env/infra failures, failures
  in modules nowhere near the diff path-wise.

### Heuristics — work in this order

1. **Read the error message first.** If it screams "flake" (timeout,
   element-not-found, performance-tolerance, concurrent assertion,
   `TEST_SETUP_ERROR`), and the test is `flaky=True`, that's a strong
   FALSE_POSITIVE signal regardless of matched hunks.
2. **Check `hunks.txt` for the row.** If a matched file's hunks
   plausibly cause the error (NPE → null check removed; AssertionError
   → assertion logic changed; ClassNotFoundException → import/build
   change), that's PR_CAUSED with that file as `culprit_file`.
3. **Empty matched_files is information, not a verdict.** Tokens may
   be too narrow, OR the cause is transitive. If the test name has
   a clear thematic connection to one of the changed modules in
   `diff_full.diff` (importer-importee, lifecycle listener, service
   wrapper), trace one hop — *do not dismiss as FALSE_POSITIVE just
   because the test file isn't in the diff.*
4. **Multi-cause rule.** If two ticket clusters in the diff both
   plausibly affect the failing test's space, classify NEEDS_REVIEW
   even at high confidence on each candidate, and list both in
   `specific_change` separated by `; `.

### Confidence

- `high` — direct cause-effect link to a specific hunk.
- `medium` — plausible link but indirect.
- `low` — gut feeling, no concrete evidence. Use sparingly; if you're
  at low confidence, NEEDS_REVIEW is almost always the right call.

---

## When to stop and ask the user

Do not guess — surface the case and ask:

- The error and the matched hunks contradict each other (flake error
  pattern + a perfect-looking culprit file).
- The diff for a single matched file exceeds ~500 lines and you can't
  pinpoint a specific hunk that explains the error.
- Reaching a confident classification would require more than 5
  additional file reads outside the bundle.
- A unique row's `case_name` looks suspicious (empty, generic, or
  identical to one being classified differently).
- The build's `duedate` predates the PR's earliest commit by more than
  a day. The PR can't have caused failures in a build that ran before
  it. (Treat as FALSE_POSITIVE for *all* unique rows, but confirm with
  the user before doing so.)

---

## Writing results.json

Validate against `results.schema.json`. One object per unique row:

```json
{
  "run_id":     "r_…",
  "classifier": "agent:claude-opus-4-7",
  "results": [
    {
      "case_id":         123456,
      "classification":  "PR_CAUSED",
      "confidence":      "high",
      "culprit_file":    "modules/apps/foo/src/main/java/.../Bar.java",
      "specific_change": "Bar.java:42 removed null check that handled empty input",
      "reason":          "Test calls Bar.bar() with empty input; previously guarded by `if (input != null)` (line 42); error is the resulting NPE."
    }
  ]
}
```

- `culprit_file` and `specific_change` are **required** when
  `classification = PR_CAUSED`. Without them the future submit step
  (v0.5) will reject the row.
- For NEEDS_REVIEW with multiple candidates, put both files in
  `specific_change`; only one path goes in `culprit_file` (the
  primary candidate).
- For FALSE_POSITIVE, `culprit_file` and `specific_change` should
  be omitted.
- `reason` is the one-paragraph explanation a human reviewer will
  read. It's the most important field — make it concrete.

---

## What NOT to do

- Do not classify NOT_UNIQUE rows. They're already filtered out — if
  you see one, the bundle is malformed.
- Do not invent file paths. `culprit_file` must be a path that
  appears in `diff_full.diff` (the b/-side path).
- Do not modify any file in the bundle other than `results.json` —
  the bundle is the audit trail.
- Do not run the API/headless path (planned v0.4) from inside this
  session. You *are* the classifier here.
- Do not extend the rubric on the fly (no new classifications, no
  new confidence levels). Surface to the user if the existing rubric
  doesn't fit.
- Do not assume the schema. Read `results.schema.json` before
  writing `results.json`.

---

## End-of-session summary template

After you've written `results.json`, output a one-pager in this
shape so the user can act on it without re-reading every row:

```
## PR-Triage report — build <id> · branch <branch> → base <base>

<N> unique failures classified · <X> PR_CAUSED · <Y> NEEDS_REVIEW · <Z> FALSE_POSITIVE

**Is this PR causing failures?** <direct verdict: "Yes — N failures
trace to <file>" / "Mostly no — only X look PR-related, the rest are
known flakes" / "Unclear — Y need human review.">

### PR_CAUSED clusters

Group rows that share a `culprit_file` or upstream cause. 2–5 clusters
typical. Each cluster: one-line cause, count, the file(s), affected
tests.

1. **<one-line cause>** (<count> failures) — culprit:
   `<file_paths>`. Affects: <list of failing tests>.
2. ...

### NEEDS_REVIEW worth a human look

<Y> rows. One line each — why it's ambiguous + which candidate cause
is most likely.

- <case_id> <test name> — <reason>
- ...

### Bundle

`apps/pr-triage/runs/<run_id>/`
```
