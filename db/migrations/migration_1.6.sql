-- =============================================================================
-- migration_1.6.sql
-- Adds module_path_category to dim_module as the stable join key for
-- dim_module_component_map lookups.
--
-- Separates two distinct join concerns that were previously conflated:
--   module_path_full     → file-level resolution (artifact path)
--                          e.g. modules/apps/commerce/commerce-api
--   module_path_category → component map join (category path)
--                          e.g. modules/apps/commerce
--
-- Uses the same normalization pattern as ingest_churn_csv.R:
--   ^(modules/(?:apps|dxp/apps|core|util)/[^/]+|portal-impl|portal-kernel|util-taglib).*$
--
-- Run AFTER migration_1.5.sql.
-- Safe to re-run: UPDATE ... WHERE module_path_category IS NULL only.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Step 1: Add column
-- -----------------------------------------------------------------------------
ALTER TABLE dim_module
    ADD COLUMN IF NOT EXISTS module_path_category VARCHAR(200);

CREATE INDEX IF NOT EXISTS idx_dim_module_path_category
    ON dim_module (module_path_category)
    WHERE module_path_category IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Step 2: Populate from module_path_full using pipeline normalization pattern
--
-- Pattern breakdown:
--   modules/apps/{category}        → stops at category (3 segments)
--   modules/dxp/apps/{category}    → stops at category (4 segments)
--   modules/core/{artifact}        → stops at artifact  (3 segments)
--   modules/util/{artifact}        → stops at artifact  (3 segments)
--   portal-impl                    → as-is
--   portal-kernel                  → as-is
--   util-taglib                    → as-is
-- -----------------------------------------------------------------------------
UPDATE dim_module
SET module_path_category = REGEXP_REPLACE(
    module_path_full,
    '^(modules/(?:apps|dxp/apps|core|util)/[^/]+|portal-impl|portal-kernel|util-taglib).*$',
    '\1'
)
WHERE module_path_full IS NOT NULL
  AND module_path_category IS NULL;

-- -----------------------------------------------------------------------------
-- Post-migration validation
-- -----------------------------------------------------------------------------

-- 1. Summary — all non-null module_path_full rows should have a category
SELECT
    COUNT(*)                                              AS total_modules,
    COUNT(module_path_category)                           AS with_category,
    COUNT(*) FILTER (WHERE module_path_full IS NOT NULL
                       AND module_path_category IS NULL)  AS missing_category
FROM dim_module;

-- 2. Spot check known modules
SELECT module_name, module_path_full, module_path_category
FROM dim_module
WHERE module_name IN (
    'wiki-engine-creole',
    'portal-impl',
    'portal-kernel',
    'portal-search-elasticsearch8-impl',
    'commerce-service',
    'headless-admin-site-client',
    'layout-admin-web',
    'source-formatter'
)
ORDER BY module_name;

-- 3. Verify category paths match dim_module_component_map
SELECT COUNT(DISTINCT dm.module_id) AS modules_with_component_mapping
FROM dim_module dm
JOIN dim_module_component_map mcm ON mcm.module_path = dm.module_path_category
WHERE dm.module_path_category IS NOT NULL;