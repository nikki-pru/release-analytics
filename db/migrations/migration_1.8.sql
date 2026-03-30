-- =============================================================================
-- Migration 1.8 — Add total_builds and release window fields to fact_test_quality
--
-- Changes:
--   - Adds total_builds column (count of distinct builds a test case ran in)
--   - Adds window_quarter, window_start, window_end (release dev window scope)
--   - Drops old unique constraint on (case_id, routine_id)
--   - Adds new unique constraint on (case_id, routine_id, window_quarter)
--   - Enables pass_rate = (total_builds - total_fail_builds) / total_builds * 100
--     computed at export time — no stored column needed
--
-- Run before: load_testray.R (re-run required to populate new columns)
-- =============================================================================

-- Add new columns
ALTER TABLE fact_test_quality
  ADD COLUMN IF NOT EXISTS total_builds    INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS window_quarter  VARCHAR(20),
  ADD COLUMN IF NOT EXISTS window_start    DATE,
  ADD COLUMN IF NOT EXISTS window_end      DATE;

-- Drop old unique constraint on (case_id, routine_id)
ALTER TABLE fact_test_quality
  DROP CONSTRAINT IF EXISTS fact_test_quality_case_id_routine_id_key;

-- New unique constraint on (case_id, routine_id, window_quarter)
-- Allows one row per test case per routine per release window
ALTER TABLE fact_test_quality
  ADD CONSTRAINT fact_test_quality_case_routine_window_key
  UNIQUE (case_id, routine_id, window_quarter);

-- Index for window_quarter filter in export_looker.R S07 queries
CREATE INDEX IF NOT EXISTS idx_test_quality_window_quarter
  ON fact_test_quality (window_quarter);

-- Clear existing data — load_testray.R re-run will repopulate with window scope
-- (existing rows have no window_quarter and will conflict with new constraint)
TRUNCATE TABLE fact_test_quality;

-- Schema version
INSERT INTO schema_version (version, notes) VALUES
  ('1.8', 'fact_test_quality — added total_builds, window_quarter, window_start, window_end; unique constraint now (case_id, routine_id, window_quarter)')
ON CONFLICT (version) DO NOTHING;
