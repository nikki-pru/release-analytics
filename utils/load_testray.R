# =============================================================================
# load_testray.R
# Loads Testray case results from local testray_working_db into fact_test_quality.
#
# Replaces: extract_testray.R (API) + transform_test_risk.R
#
# Routines:
#   590307 — EE Development Acceptance (master)  [daily gate]
#   82964  — EE Package Tester                   [pre-ship release gate]
#
# Grain: case × routine × window_quarter
#   One row per test case per routine per release dev window.
#   Enables pass rate trends across releases:
#     pass_rate = (total_builds - total_fail_builds) / total_builds * 100
#
# Logic:
#   - Reads dev_windows from config.yml (same windows used for Jira quarter assignment)
#   - For each window, pulls builds where startdate_ falls within dev_start → dev_end
#   - Filters to clean builds only (build-level pass rate >= 50%)
#   - Aggregates to case × routine × window_quarter grain
#   - Upserts into fact_test_quality on (case_id, routine_id, window_quarter)
#
# Coverage note:
#   Testray backup covers builds from ~2024-09 (Acceptance) and ~2024-08 (Release).
#   Windows before 2025.Q1 will have sparse or zero data — expected.
#
# Run after:  load_module_component_map.R
# Run before: export_looker.R
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(DBI)
  library(RPostgres)
  library(logger)
  library(yaml)
  library(purrr)
})

log_appender(appender_file(
  Sys.getenv("RAP_LOG_FILE", unset = "logs/pipeline.log"),
  append = TRUE
))
log_info("=== load_testray.R started ===")

cfg <- read_yaml("config/config.yml")

# -----------------------------------------------------------------------------
# Two connections — one per DB
# -----------------------------------------------------------------------------
db_connect <- function(db_cfg) {
  DBI::dbConnect(
    RPostgres::Postgres(),
    host     = db_cfg$host,
    port     = db_cfg$port,
    dbname   = db_cfg$dbname,
    user     = db_cfg$user,
    password = db_cfg$password %||% ""
  )
}

con         <- db_connect(cfg$databases$release_analytics)
con_testray <- db_connect(cfg$databases$testray)
on.exit({
  DBI::dbDisconnect(con)
  DBI::dbDisconnect(con_testray)
}, add = TRUE)

log_info("Connected: {cfg$databases$release_analytics$dbname} + {cfg$databases$testray$dbname}")

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
TARGET_ROUTINES <- list(
  list(id = 590307L, name = "EE Development Acceptance (master)"),
  list(id = 82964L,  name = "EE Package Tester")
)
MIN_PASS_RATE       <- 0.50
FAILURE_STATUSES    <- c("FAILED", "BLOCKED", "UNTESTED", "TESTFIX")
EXCLUDED_COMPONENTS <- c("A/B Test", "License", "Smoke")

routine_ids_sql <- paste(sapply(TARGET_ROUTINES, `[[`, "id"), collapse = ", ")
routine_name_map <- tibble(
  routine_id   = as.integer(sapply(TARGET_ROUTINES, `[[`, "id")),
  routine_name = sapply(TARGET_ROUTINES, `[[`, "name")
)

# Load dev windows from config
dev_windows <- bind_rows(lapply(cfg$jira$dev_windows, as.data.frame)) %>%
  mutate(
    dev_start = as.Date(dev_start),
    dev_end   = as.Date(dev_end)
  )

# Add 2026.Q2 if IN_DEVELOPMENT but not yet in config dev_windows
q2_check <- dbGetQuery(con, "
  SELECT release_label FROM dim_release
  WHERE release_label = '2026.Q2' AND release_status = 'IN_DEVELOPMENT'
  LIMIT 1
")
if (nrow(q2_check) > 0 && !("2026.Q2" %in% dev_windows$quarter)) {
  dev_windows <- bind_rows(dev_windows, tibble(
    quarter   = "2026.Q2",
    dev_start = as.Date("2026-02-28"),
    dev_end   = Sys.Date()
  ))
  log_info("Added open window for 2026.Q2 (IN_DEVELOPMENT) — dev_end = {Sys.Date()}")
}

log_info("Dev windows: {nrow(dev_windows)} quarters ({min(dev_windows$quarter)} to {max(dev_windows$quarter)})")
log_info("Routines: {paste(sapply(TARGET_ROUTINES, function(r) paste0(r$id, ' (', r$name, ')')), collapse = ', ')}")
log_info("Min pass rate filter: {MIN_PASS_RATE * 100}%%")

# Table names
BUILD      <- "o_22235989312226_build"
CASERESULT <- "o_22235989312226_caseresult"
CASE_TBL   <- "o_22235989312226_case"
COMPONENT  <- "o_22235989312226_component"
TEAM       <- "o_22235989312226_team"
CASETYPE   <- "o_22235989312226_casetype"

# -----------------------------------------------------------------------------
# Step 1 — Pull ALL clean builds with their start date
#   startdate_ used to assign builds to dev windows in R
# -----------------------------------------------------------------------------
log_info("Step 1: pulling all clean builds with dates")

# Acceptance (590307): daily gate — filter by pass rate >= 50%
# Release (82964):     ship gate — filter to promoted_ = TRUE only
acceptance_builds <- dbGetQuery(con_testray, sprintf("
  SELECT
    c_buildid_                      AS build_id,
    r_routinetobuilds_c_routineid   AS routine_id,
    DATE(duedate_)                  AS build_date
  FROM %s
  WHERE r_routinetobuilds_c_routineid = 590307
    AND duedate_ IS NOT NULL
    AND (
      caseresultpassed_::numeric /
      NULLIF(caseresultpassed_ + caseresultfailed_, 0)
    ) >= %s
", BUILD, MIN_PASS_RATE))

release_builds <- dbGetQuery(con_testray, sprintf("
  SELECT
    c_buildid_                      AS build_id,
    r_routinetobuilds_c_routineid   AS routine_id,
    DATE(duedate_)                  AS build_date
  FROM %s
  WHERE r_routinetobuilds_c_routineid = 82964
    AND duedate_ IS NOT NULL
    AND promoted_ = TRUE
", BUILD))

all_builds <- bind_rows(acceptance_builds, release_builds)

log_info("Acceptance builds (pass rate >= {MIN_PASS_RATE * 100}%%): {nrow(acceptance_builds)}")
log_info("Release builds (promoted only): {nrow(release_builds)}")

log_info("Total clean builds: {nrow(all_builds)}")
for (r in TARGET_ROUTINES) {
  log_info("  Routine {r$id} ({r$name}): {sum(all_builds$routine_id == r$id)} builds")
}

# Assign each build to a dev window — vectorized cross join + filter
# Much faster than rowwise() on large build sets
all_builds <- all_builds %>%
  left_join(
    dev_windows %>% rename(window_quarter = quarter),
    by = character()  # cross join
  ) %>%
  filter(build_date >= dev_start & build_date <= dev_end) %>%
  group_by(build_id, routine_id, build_date) %>%
  slice(1) %>%  # take first matching window if dates overlap
  ungroup() %>%
  dplyr::select(build_id, routine_id, build_date, window_quarter)

log_info("Builds assigned to dev windows: {nrow(all_builds)}")
window_cov <- all_builds %>%
  count(window_quarter, routine_id) %>%
  left_join(routine_name_map, by = "routine_id") %>%
  arrange(window_quarter, routine_id)
for (i in seq_len(nrow(window_cov))) {
  log_info("  [{window_cov$window_quarter[i]}] {window_cov$routine_name[i]}: {window_cov$n[i]} builds")
}

if (nrow(all_builds) == 0) {
  log_error("No builds assigned to any dev window — check config dev_windows dates")
  stop("No builds to process")
}

build_map <- all_builds %>% dplyr::select(build_id, routine_id, window_quarter)

# -----------------------------------------------------------------------------
# Step 2 — Case results for all clean builds (chunked)
# -----------------------------------------------------------------------------
log_info("Step 2: pulling case results ({nrow(all_builds)} builds)")

chunk_size <- 500
chunks     <- split(all_builds$build_id, ceiling(seq_along(all_builds$build_id) / chunk_size))

caseresults_raw <- bind_rows(lapply(chunks, function(ids) {
  dbGetQuery(con_testray, sprintf("
    SELECT
      r_casetocaseresult_c_caseid           AS case_id,
      r_buildtocaseresult_c_buildid         AS build_id,
      r_componenttocaseresult_c_componentid AS component_id,
      r_teamtocaseresult_c_teamid           AS team_id,
      duestatus_                            AS status,
      issues_                               AS issues
    FROM %s
    WHERE r_buildtocaseresult_c_buildid IN (%s)
  ", CASERESULT, paste(ids, collapse = ", ")))
}))

log_info("Raw case results: {nrow(caseresults_raw)}")

caseresults <- caseresults_raw %>%
  left_join(build_map, by = "build_id")

# -----------------------------------------------------------------------------
# Step 3 — Case metadata scoped to seen case IDs
# -----------------------------------------------------------------------------
log_info("Step 3: pulling case metadata")

seen_ids_sql <- paste(unique(caseresults$case_id), collapse = ", ")

cases <- dbGetQuery(con_testray, sprintf("
  SELECT
    c.c_caseid_                        AS case_id,
    c.name_                            AS case_name,
    c.flaky_                           AS flaky,
    c.priority_                        AS priority,
    ct.name_                           AS case_type
  FROM %s c
  LEFT JOIN %s ct ON ct.c_casetypeid_ = c.r_casetypetocases_c_casetypeid
  WHERE c.c_caseid_ IN (%s)
", CASE_TBL, CASETYPE, seen_ids_sql)) %>%
  filter(!grepl("modules-compile", case_name, ignore.case = TRUE))

log_info("Cases loaded: {nrow(cases)}")

# -----------------------------------------------------------------------------
# Step 4 — Component and team lookups
# -----------------------------------------------------------------------------
log_info("Step 4: pulling component and team lookups")

components <- dbGetQuery(con_testray, sprintf(
  "SELECT c_componentid_ AS component_id, name_ AS component_name FROM %s", COMPONENT
))
teams <- dbGetQuery(con_testray, sprintf(
  "SELECT c_teamid_ AS team_id, name_ AS team_name FROM %s", TEAM
))

# -----------------------------------------------------------------------------
# Step 5 — Join and filter
# -----------------------------------------------------------------------------
log_info("Step 5: joining lookups")

cr <- caseresults %>%
  inner_join(cases,     by = "case_id") %>%
  left_join(components, by = "component_id") %>%
  left_join(teams,      by = "team_id") %>%
  filter(!component_name %in% EXCLUDED_COMPONENTS)

log_info("After joins and exclusions: {nrow(cr)} case results")

# -----------------------------------------------------------------------------
# Step 6 — Aggregate to case × routine × window_quarter grain
#
# total_builds      = distinct builds this test case ran in within the window
# total_fail_builds = builds where status is a failure status
# pass_rate         = NOT stored — computed at export time:
#                     (total_builds - total_fail_builds) / total_builds * 100
# -----------------------------------------------------------------------------
log_info("Step 6: aggregating to case x routine x window_quarter grain")

aggregated <- cr %>%
  group_by(case_id, routine_id, window_quarter) %>%
  summarise(
    case_name            = first(case_name),
    case_type            = first(case_type),
    component_name       = first(component_name),
    team_name            = first(team_name),
    total_builds         = n_distinct(build_id),
    total_fail_builds    = sum(status %in% FAILURE_STATUSES),
    bug_linked_builds    = sum(
                             status %in% FAILURE_STATUSES &
                             !is.na(issues) & nchar(trimws(issues)) > 0
                           ),
    distinct_bugs_linked = n_distinct(
                             issues[
                               status %in% FAILURE_STATUSES &
                               !is.na(issues) & nchar(trimws(issues)) > 0
                             ]
                           ),
    .groups = "drop"
  ) %>%
  mutate(
    investigation_rate = round(
      ifelse(total_fail_builds > 0, bug_linked_builds / total_fail_builds, 0),
      4
    ),
    signal_score = round(
      investigation_rate * (total_fail_builds / pmax(total_builds, 1)),
      4
    )
  ) %>%
  left_join(routine_name_map, by = "routine_id") %>%
  left_join(
    dev_windows %>% dplyr::select(
      window_quarter = quarter,
      window_start   = dev_start,
      window_end     = dev_end
    ),
    by = "window_quarter"
  )

log_info("Aggregated: {nrow(aggregated)} case x routine x window rows")
for (r in TARGET_ROUTINES) {
  n_rows    <- sum(aggregated$routine_id == r$id)
  n_windows <- n_distinct(aggregated$window_quarter[aggregated$routine_id == r$id])
  log_info("  Routine {r$id} ({r$name}): {n_rows} rows across {n_windows} windows")
}

# -----------------------------------------------------------------------------
# Step 7 — Filter low-quality windows, then upsert into fact_test_quality
# Windows where overall pass rate < 60% are excluded — these typically indicate
# CI/infrastructure failures rather than real code quality signal. Teams usually
# re-run in these cases so the data is not representative.
# -----------------------------------------------------------------------------
WINDOW_MIN_PASS_RATE <- 0.60

window_pass_rates <- aggregated %>%
  group_by(routine_id, window_quarter) %>%
  summarise(
    window_pass_rate = (sum(total_builds) - sum(total_fail_builds)) /
                       pmax(sum(total_builds), 1),
    .groups = "drop"
  )

low_quality_windows <- window_pass_rates %>%
  filter(window_pass_rate < WINDOW_MIN_PASS_RATE)

if (nrow(low_quality_windows) > 0) {
  log_info("Excluding {nrow(low_quality_windows)} low-quality routine x window combinations (pass_rate < {WINDOW_MIN_PASS_RATE * 100}%%):")
  for (i in seq_len(nrow(low_quality_windows))) {
    log_info("  [{low_quality_windows$window_quarter[i]}] routine {low_quality_windows$routine_id[i]}: pass_rate={round(low_quality_windows$window_pass_rate[i]*100,1)}%%")
  }
  aggregated <- aggregated %>%
    anti_join(low_quality_windows, by = c("routine_id", "window_quarter"))
  log_info("Rows after low-quality window exclusion: {nrow(aggregated)}")
} else {
  log_info("All windows passed quality threshold (pass_rate >= {WINDOW_MIN_PASS_RATE * 100}%%)")
}

log_info("Step 7: upserting into fact_test_quality")

dbWriteTable(con, "tmp_test_quality", aggregated,
             temporary = TRUE, overwrite = TRUE)

rows_upserted <- dbExecute(con, "
  INSERT INTO fact_test_quality (
    case_id, case_name, case_type,
    component_name, team_name,
    total_builds, total_fail_builds, bug_linked_builds, distinct_bugs_linked,
    investigation_rate, signal_score,
    routine_id, routine_name,
    window_quarter, window_start, window_end,
    calculated_at
  )
  SELECT
    case_id, case_name, case_type,
    component_name, team_name,
    total_builds, total_fail_builds, bug_linked_builds, distinct_bugs_linked,
    investigation_rate, signal_score,
    routine_id, routine_name,
    window_quarter, window_start, window_end,
    NOW()
  FROM tmp_test_quality
  ON CONFLICT (case_id, routine_id, window_quarter) DO UPDATE SET
    case_name            = EXCLUDED.case_name,
    case_type            = EXCLUDED.case_type,
    component_name       = EXCLUDED.component_name,
    team_name            = EXCLUDED.team_name,
    total_builds         = EXCLUDED.total_builds,
    total_fail_builds    = EXCLUDED.total_fail_builds,
    bug_linked_builds    = EXCLUDED.bug_linked_builds,
    distinct_bugs_linked = EXCLUDED.distinct_bugs_linked,
    investigation_rate   = EXCLUDED.investigation_rate,
    signal_score         = EXCLUDED.signal_score,
    routine_name         = EXCLUDED.routine_name,
    window_start         = EXCLUDED.window_start,
    window_end           = EXCLUDED.window_end,
    calculated_at        = NOW()
")

dbExecute(con, "DROP TABLE IF EXISTS tmp_test_quality")
log_info("Upserted: {rows_upserted} rows")

# -----------------------------------------------------------------------------
# Step 8 — Validation: pass rate by routine × window
# -----------------------------------------------------------------------------
log_info("Step 8: validation")

val <- dbGetQuery(con, "
  SELECT
    routine_id,
    routine_name,
    window_quarter,
    COUNT(*)                                              AS n_cases,
    COUNT(DISTINCT component_name)                        AS n_components,
    SUM(total_builds)                                     AS sum_builds,
    SUM(total_fail_builds)                                AS sum_failures,
    ROUND(
      (SUM(total_builds) - SUM(total_fail_builds))::NUMERIC /
      NULLIF(SUM(total_builds), 0) * 100, 1
    )                                                     AS pass_rate_pct,
    ROUND(AVG(investigation_rate)::NUMERIC, 4)            AS avg_investigation_rate,
    MAX(calculated_at)                                    AS last_updated
  FROM fact_test_quality
  WHERE routine_id IS NOT NULL
  GROUP BY routine_id, routine_name, window_quarter
  ORDER BY window_quarter, routine_id
")

log_info("Pass rates by routine x window:")
for (i in seq_len(nrow(val))) {
  log_info("  [{val$window_quarter[i]}] {val$routine_name[i]}: cases={val$n_cases[i]}, pass_rate={val$pass_rate_pct[i]}%")
}

log_info("=== load_testray.R complete ===")