# Triage — Claude Code Workflow

Classifies Testray PASSED→FAILED regressions as BUG / NEEDS_REVIEW /
FALSE_POSITIVE and writes results to `fact_triage_results`. Runs
alongside the batch pipeline (`run_triage.sh`) — same database,
different classifier value.

Load `.claude/skills/triage.skill` at the start of any session for
the full rubric, schema, and tool contracts.

## Before starting a session

1. Confirm the routine ID and build pair you're triaging (ask if not given)
2. Check `fact_triage_results` for existing classifications on this
   build pair — do not re-classify without explicit `--reclassify` intent
3. Confirm `config/config.yml` has valid DB, Testray, and Jira credentials

## The classification loop

For each regression from `tools/get_regressions.py`:

**1. Cheap check first — test history**
Pull via `tools/get_test_history.py`. If the test shows >30% intermittent
failures across the last 20 runs in unrelated builds → FALSE_POSITIVE.
State which flakiness pattern applies. Move to next case.

**2. If not obviously flaky — pull diff hunks**
Via `tools/get_hunks.py` (wraps `extract_relevant_hunks.py`). Look for:
- Change in the test file itself → likely BUG if behavior changed
- Change in a directly referenced class → BUG, name the culprit file
- No relevant changes in diff → NEEDS_REVIEW, explain why evidence
  is insufficient

**3. If there's a linked Jira ticket**
Fetch it. If it describes the same symptom, classify per ticket status.

**4. Write the result**
Via `tools/upsert_result.py`:
- classification: BUG | NEEDS_REVIEW | FALSE_POSITIVE
- confidence: high | medium | low
- culprit_file: required for BUG, null for others
- rationale: plain language explanation
- tool_trace: JSON array of tool calls taken

## When to stop and ask the user

Do not guess — escalate when:
- Confidence is low AND component is outside the top 15 by LPD volume
- Two pieces of evidence contradict each other
- The diff for a single case exceeds ~500 lines (hunk extraction may
  be wrong)
- Reaching confident classification would require more than 5 additional
  tool calls

## What not to do

- Do not upsert without logging the full tool-call trace
- Do not classify BUG without naming at least a candidate culprit_file —
  even at low confidence. Downstream `pr_outcomes` training needs this.
- Do not re-classify a case already in `fact_triage_results` for this
  build pair without explicit user instruction
- Do not assume schema — see root CLAUDE.md for column names and join keys
- Do not reference SonarQube — retired, lizard is the complexity source

## End of session summary

Report:
- N classified: X BUG / Y NEEDS_REVIEW / Z FALSE_POSITIVE
- N escalated to user
- Disagreement rate vs batch pipeline on same build pair (if prior run exists)
- Total tool calls by tool

## Relationship to batch pipeline

The batch pipeline (`run_triage.sh`) processes entire build pairs
end-to-end. The Claude Code workflow is better for:
- Ambiguous cases the batch pipeline flags as NEEDS_REVIEW
- New routines without established patterns
- Cases where culprit attribution needs richer reasoning

Both write to `fact_triage_results`. Classifier values:
- Batch: `batch:v1`
- Claude Code: `agent:claude-sonnet-4-6` (update to match current model)

Disagreement between classifiers is signal, not error — flag systematic
divergence in the session summary.
