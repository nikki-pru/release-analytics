# =============================================================================
# utils/apply_feature_flag_dampening.R
# Applies churn dampening to modules with feature-flagged code.
#
# Pipeline position: runs AFTER ingest_churn_csv.R, BEFORE transform_forecast_input.R
#
# Logic:
#   1. Load feature_flagged_modules_*.csv (most recent)
#   2. Exclude infrastructure/false-positive modules
#   3. Join flagged modules → dim_module_component_map → fact_forecast_input
#   4. Apply dampening_weight to churn columns for flagged components
#   5. Set is_feature_flagged = TRUE and churn_dampening_factor on affected rows
#
# Config (config.yml):
#   feature_flags:
#     dampening_weight:   0.5    # multiplier applied to churn (0-1)
#     flag_pct_threshold: 0.20   # modules below this threshold are not dampened
#
# Excluded modules (false positives):
#   - Any module_path containing 'feature-flag' (the flag framework itself)
#   - modules/apps/portal-language (i18n false positive)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(DBI)
  library(yaml)
  library(logger)
})

log_appender(appender_file("logs/pipeline.log", append = TRUE))
log_info("--- apply_feature_flag_dampening started ---")

select <- dplyr::select
filter <- dplyr::filter

source("config/release_analytics_db.R")
cfg <- read_yaml("config/config.yml")

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
# Null coalescing operator
`%||%` <- function(a, b) if (!is.null(a)) a else b

dampening_weight   <- cfg$feature_flags$dampening_weight   %||% 0.5
flag_pct_threshold <- cfg$feature_flags$flag_pct_threshold %||% 0.20

# Modules excluded from dampening (infrastructure / false positives)
EXCLUDED_PATTERNS <- c("feature-flag", "portal-language")

log_info("Dampening weight:   {dampening_weight}")
log_info("Flag pct threshold: {flag_pct_threshold}")

# -----------------------------------------------------------------------------
# Load feature flag CSV (most recent)
# -----------------------------------------------------------------------------
flag_files <- sort(Sys.glob("data/feature_flagged_modules_*.csv"), decreasing = TRUE)

if (length(flag_files) == 0) {
  log_warn("No data/feature_flagged_modules_*.csv found — skipping dampening")
  log_info("  Run extract/extract_feature_flags.sh to generate the file")
  log_info("--- apply_feature_flag_dampening complete (skipped) ---")
  quit(save = "no", status = 0)
}

flag_file <- flag_files[1]
log_info("Loading: {flag_file}")

flags_raw <- read_csv(flag_file, col_types = cols(.default = "c"), show_col_types = FALSE) |>
  mutate(
    flagged_file_count = as.integer(flagged_file_count),
    total_file_count   = as.integer(total_file_count),
    flag_pct           = as.numeric(flag_pct),
    is_flagged         = is_flagged == "TRUE"
  )

log_info("Total modules in CSV: {nrow(flags_raw)}")
log_info("Flagged modules (raw): {sum(flags_raw$is_flagged)}")

# -----------------------------------------------------------------------------
# Apply exclusions and threshold filter
# -----------------------------------------------------------------------------
`%||%` <- function(a, b) if (!is.null(a)) a else b

flags_clean <- flags_raw |>
  filter(is_flagged) |>
  filter(flag_pct >= flag_pct_threshold) |>
  filter(!grepl(paste(EXCLUDED_PATTERNS, collapse = "|"), module_path))

log_info("Flagged modules after exclusions: {nrow(flags_clean)}")
if (nrow(flags_clean) > 0) {
  for (i in seq_len(nrow(flags_clean))) {
    log_info("  {flags_clean$module_path[i]}: {flags_clean$flagged_file_count[i]}/{flags_clean$total_file_count[i]} files ({round(flags_clean$flag_pct[i]*100,1)}%)")
  }
}

if (nrow(flags_clean) == 0) {
  log_info("No modules eligible for dampening after exclusions — nothing to update")
  log_info("--- apply_feature_flag_dampening complete (no changes) ---")
  quit(save = "no", status = 0)
}

# -----------------------------------------------------------------------------
# Connect to DB
# -----------------------------------------------------------------------------
con <- get_db_connection()
on.exit(dbDisconnect(con), add = TRUE)

# -----------------------------------------------------------------------------
# Resolve module_path → component_id via dim_module_component_map
# -----------------------------------------------------------------------------
mcm <- dbGetQuery(con, "
  SELECT mcm.module_path, mcm.component_id, mcm.weight, dc.component_name
  FROM dim_module_component_map mcm
  JOIN dim_component dc ON dc.component_id = mcm.component_id
")

flagged_components <- flags_clean |>
  left_join(mcm, by = "module_path") |>
  filter(!is.na(component_id))

unmatched <- flags_clean |>
  filter(!module_path %in% flagged_components$module_path)

if (nrow(unmatched) > 0) {
  log_warn("Flagged modules with no component mapping (excluded from dampening):")
  for (m in unmatched$module_path) log_warn("  {m}")
}

component_ids <- unique(flagged_components$component_id)
log_info("Components to dampen: {length(component_ids)}")
for (cid in component_ids) {
  cname <- flagged_components$component_name[flagged_components$component_id == cid][1]
  log_info("  component_id={cid} ({cname})")
}

if (length(component_ids) == 0) {
  log_info("No component mappings found — nothing to update")
  log_info("--- apply_feature_flag_dampening complete (no changes) ---")
  quit(save = "no", status = 0)
}

# -----------------------------------------------------------------------------
# Ensure fact_forecast_input has dampening columns
# (idempotent — safe to run even if columns already exist)
# -----------------------------------------------------------------------------
dbExecute(con, "
  ALTER TABLE fact_forecast_input
    ADD COLUMN IF NOT EXISTS is_feature_flagged    BOOLEAN   DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS churn_dampening_factor NUMERIC(4,2) DEFAULT 1.0
")

# -----------------------------------------------------------------------------
# Reset all dampening to baseline first (in case modules were un-flagged)
# -----------------------------------------------------------------------------
reset_rows <- dbExecute(con, "
  UPDATE fact_forecast_input
  SET
    is_feature_flagged     = FALSE,
    churn_dampening_factor = 1.0
  WHERE is_feature_flagged = TRUE
    OR churn_dampening_factor != 1.0
")
log_info("Reset {reset_rows} previously dampened rows to baseline")

# -----------------------------------------------------------------------------
# Apply dampening to flagged components
# Churn columns dampened: total_churn, backend_changes, frontend_changes
# (The actual churn values are not modified — dampening_factor is read by
#  transform_forecast_input.R and export_looker.R when computing churn_score)
# -----------------------------------------------------------------------------
component_ids_sql <- paste(component_ids, collapse = ", ")

dampened_rows <- dbExecute(con, glue::glue("
  UPDATE fact_forecast_input
  SET
    is_feature_flagged     = TRUE,
    churn_dampening_factor = {dampening_weight}
  WHERE component_id IN ({component_ids_sql})
"))

log_info("Dampening applied: {dampened_rows} rows updated")
log_info("  component_ids: {component_ids_sql}")
log_info("  dampening_factor: {dampening_weight}")

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
summary <- dbGetQuery(con, "
  SELECT
    quarter,
    COUNT(*) FILTER (WHERE is_feature_flagged = TRUE)  AS n_flagged,
    COUNT(*) FILTER (WHERE is_feature_flagged = FALSE) AS n_normal,
    ROUND(AVG(churn_dampening_factor)::NUMERIC, 3)     AS avg_dampening_factor
  FROM fact_forecast_input
  WHERE quarter LIKE '%.Q%'
  GROUP BY quarter
  ORDER BY quarter
")

log_info("Dampening summary by quarter:")
for (i in seq_len(nrow(summary))) {
  log_info("  {summary$quarter[i]}: {summary$n_flagged[i]} flagged, {summary$n_normal[i]} normal, avg_factor={summary$avg_dampening_factor[i]}")
}

log_info("--- apply_feature_flag_dampening complete ---")