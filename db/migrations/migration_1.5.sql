-- =============================================================================
-- migration_1.5.sql
-- Adds module_path_full to dim_module as a stable, unambiguous join key.
--
-- Resolves mixed module_name formats (artifact_only / full_path / short_name)
-- that existed across pipeline consumers. All future joins should use
-- module_path_full instead of module_name for complexity, churn, and scoring.
--
-- Standard format: modules/group/artifact
-- Exceptions:      portal-impl, portal-kernel, portal-web (root-level, no
--                  modules/ prefix in their file paths)
-- No-file orphans: module_path_full left NULL — not pipeline participants,
--                  no component mappings, do not affect scoring.
--
-- Run BEFORE load_lizard.R and the full pipeline re-run.
-- Safe to re-run: UPDATE ... WHERE module_path_full IS NULL only.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Step 1: Add module_path_full column
-- -----------------------------------------------------------------------------

ALTER TABLE dim_module
    ADD COLUMN IF NOT EXISTS module_path_full VARCHAR(500);

CREATE INDEX IF NOT EXISTS idx_dim_module_path_full
    ON dim_module (module_path_full)
    WHERE module_path_full IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Step 2: Populate from dim_file for modules that have files under modules/
--
-- Depth rules confirmed by schema analysis:
--
--   5-segment paths (modules/{g1}/{g2}/{category}/{artifact}):
--     modules/dxp/apps/{category}/{artifact}          — dxp (non-osb)
--     modules/apps/commerce/{sub}/{artifact}
--     modules/apps/fragment/{sub}/{artifact}
--     modules/apps/headless/{sub}/{artifact}
--     modules/apps/layout/{sub}/{artifact}
--     modules/apps/portlet-configuration/{sub}/{artifact}
--     modules/apps/push-notifications/{sub}/{artifact}
--     modules/apps/site-initializer/{sub}/{artifact}
--     modules/apps/static/{sub}/{artifact}
--
--   3-segment paths (modules/{group}/{artifact}):
--     all other groups: apps (non-deep), util, core, test,
--     sdk, frontend-sdk, integrations, etl
--
-- Excluded: modules/dxp/apps/osb/ — 6-segment nesting, zero component
--   mappings, no scoring impact. Excluded here and in load_lizard.R.
--
-- Takes MIN(file_path) per module_id for determinism; all files under
-- the same module_id produce the same root segment.
-- -----------------------------------------------------------------------------

UPDATE dim_module dm
SET module_path_full = sub.derived_path
FROM (
    SELECT
        df.module_id,
        CASE
            WHEN MIN(df.file_path) LIKE 'modules/dxp/%'
              OR MIN(df.file_path) LIKE 'modules/apps/commerce/%'
              OR MIN(df.file_path) LIKE 'modules/apps/fragment/%'
              OR MIN(df.file_path) LIKE 'modules/apps/headless/%'
              OR MIN(df.file_path) LIKE 'modules/apps/layout/%'
              OR MIN(df.file_path) LIKE 'modules/apps/portlet-configuration/%'
              OR MIN(df.file_path) LIKE 'modules/apps/push-notifications/%'
              OR MIN(df.file_path) LIKE 'modules/apps/site-initializer/%'
              OR MIN(df.file_path) LIKE 'modules/apps/static/%'
                THEN REGEXP_REPLACE(
                    MIN(df.file_path),
                    '^(modules/[^/]+/[^/]+/[^/]+/[^/]+).*',
                    '\1'
                )
            ELSE REGEXP_REPLACE(
                    MIN(df.file_path),
                    '^(modules/[^/]+/[^/]+).*',
                    '\1'
                )
        END AS derived_path
    FROM dim_file df
    WHERE df.file_path LIKE 'modules/%'
      AND df.file_path NOT LIKE 'modules/dxp/apps/osb/%'  -- excluded: extra nesting, no component mappings
    GROUP BY df.module_id
) sub
WHERE dm.module_id        = sub.module_id
  AND dm.module_path_full IS NULL
  AND sub.derived_path    LIKE 'modules/%';  -- safety: only accept clean extractions

-- -----------------------------------------------------------------------------
-- Step 3: Special cases — root-level modules outside modules/
--
-- portal-impl, portal-kernel, portal-web live at the repo root, not under
-- modules/. Their file paths look like:
--   portal-impl/src/com/liferay/...
--   portal-kernel/src/com/liferay/...
-- module_path_full = first path segment (e.g. portal-impl).
-- -----------------------------------------------------------------------------

UPDATE dim_module dm
SET module_path_full = sub.derived_path
FROM (
    SELECT
        df.module_id,
        SPLIT_PART(MIN(df.file_path), '/', 1) AS derived_path
    FROM dim_file df
    WHERE df.file_path NOT LIKE 'modules/%'
      AND df.file_path NOT LIKE '/%'          -- exclude any absolute paths
    GROUP BY df.module_id
) sub
WHERE dm.module_id        = sub.module_id
  AND dm.module_path_full IS NULL;

-- -----------------------------------------------------------------------------
-- Post-migration validation (run interactively after applying migration,
-- do not include in automated migration runner)
-- -----------------------------------------------------------------------------

-- 1. Summary by format — expecting: full_path ~2100+, root_level ~3-5, nulls = orphans
SELECT
    CASE
        WHEN module_path_full IS NULL          THEN 'null (orphan — expected)'
        WHEN module_path_full LIKE 'modules/%' THEN 'full_path'
        ELSE                                        'root_level'
    END                AS path_format,
    COUNT(*)           AS module_count
FROM dim_module
GROUP BY 1
ORDER BY 2 DESC;

-- 2. Spot check: confirm known modules resolved correctly
SELECT module_name, module_path_full
FROM dim_module
WHERE module_name IN (
    'wiki-engine-creole',
    'portal-impl',
    'portal-kernel',
    'portal-search-elasticsearch8-impl',
    'osb-faro-web',
    'source-formatter'
)
ORDER BY module_name;

-- 3. Flag any unexpected nulls (modules WITH files but no module_path_full)
-- Expected result: zero rows. Any rows here need manual review.
SELECT
    dm.module_id,
    dm.module_name,
    COUNT(df.file_id) AS file_count
FROM dim_module dm
JOIN dim_file df ON df.module_id = dm.module_id
WHERE dm.module_path_full IS NULL
GROUP BY dm.module_id, dm.module_name
ORDER BY file_count DESC
LIMIT 10;
