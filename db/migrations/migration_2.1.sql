-- =============================================================================
-- Migration 2.1 — Add POSSIBLE_BUG classification tier
--
-- Changes:
--   - Adds possible_bug INTEGER NULL on triage_run_log (per-run count column)
--   - No change to fact_triage_results: classification is VARCHAR(32) with no
--     CHECK constraint, so it already accepts the new 'POSSIBLE_BUG' value.
--     Existing rows are unaffected; no backfill.
--
-- Why:
--   The triage rubric previously overloaded NEEDS_REVIEW with two distinct
--   cases: (1) a single, concrete, medium-confidence diff-caused culprit the
--   classifier could name but not verify to high confidence, and (2) genuinely
--   ambiguous failures (2+ candidate clusters, transitive deps, low confidence).
--   POSSIBLE_BUG splits case (1) out:
--
--     BUG           high confidence, VERIFIED culprit, genuine defect
--     POSSIBLE_BUG  medium confidence, exactly one named candidate culprit
--     NEEDS_REVIEW  2+ candidates / transitive / low confidence
--
--   BUG was kept as-is (no rename) so existing rows and the pr_outcomes
--   defect-attribution training contract stay intact. Both BUG and POSSIBLE_BUG
--   culprit_files now feed that training set:
--     WHERE classification IN ('BUG','POSSIBLE_BUG').
--
--   triage_run_log needs a matching per-run count column. store.py also
--   retrofits this at runtime via ensure_run_log() (ADD COLUMN IF NOT EXISTS);
--   this migration makes the change explicit in the schema history.
--
-- Run before: the first prepare.py / submit.py run that emits POSSIBLE_BUG.
-- =============================================================================

-- triage_run_log ------------------------------------------------------------

ALTER TABLE triage_run_log
  ADD COLUMN IF NOT EXISTS possible_bug INTEGER;

-- Schema version -----------------------------------------------------------

INSERT INTO schema_version (version, notes) VALUES
  ('2.1', 'Added POSSIBLE_BUG classification tier (single medium-confidence diff-caused culprit). triage_run_log gains possible_bug count column; fact_triage_results.classification VARCHAR unchanged (no CHECK). Both BUG and POSSIBLE_BUG feed pr_outcomes training.')
ON CONFLICT (version) DO NOTHING;
