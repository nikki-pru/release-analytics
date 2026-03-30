-- =============================================================================
-- Migration 1.7 — Add routine_id to fact_test_quality
--
-- Changes:
--   - Adds routine_id and routine_name columns to fact_test_quality
--   - Drops old unique constraint on (case_id) alone
--   - Adds new unique constraint on (case_id, routine_id)
--   - Adds index on routine_id for export_looker.R filter queries
--
-- Run before: load_testray.R
-- =============================================================================

-- Add columns
ALTER TABLE fact_test_quality
    ADD COLUMN IF NOT EXISTS routine_id   BIGINT,
    ADD COLUMN IF NOT EXISTS routine_name VARCHAR(100);

-- Drop old unique constraint
ALTER TABLE fact_test_quality
    DROP CONSTRAINT IF EXISTS fact_test_quality_case_id_key;

-- Add new unique constraint on (case_id, routine_id)
ALTER TABLE fact_test_quality
    ADD CONSTRAINT fact_test_quality_case_id_routine_id_key
    UNIQUE (case_id, routine_id);

-- Index for routine filter in export_looker.R
CREATE INDEX IF NOT EXISTS idx_test_quality_routine_id
    ON fact_test_quality (routine_id);

-- Schema version
INSERT INTO schema_version (version, notes) VALUES
  ('1.7', 'fact_test_quality — added routine_id, routine_name; unique constraint now (case_id, routine_id)')
ON CONFLICT (version) DO NOTHING;