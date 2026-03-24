#!/usr/bin/env bash
# =============================================================================
# extract_feature_flags.sh
# Scans liferay-portal for feature-flagged code and outputs a CSV of modules
# where a meaningful proportion of files reference feature flags.
#
# Detection patterns:
#   - FeatureFlagManagerUtil.isEnabled  (Java runtime flag check)
#   - @FeatureFlag                       (Java annotation)
#   - featureFlagsTest()                 (test utility)
#   - feature.flag.*=                    (portal.properties entries)
#
# Output: data/feature_flagged_modules_YYYYMMDD.csv
# Columns: module_path, flagged_file_count, total_file_count, flag_pct, is_flagged
#
# Usage:
#   bash extract/extract_feature_flags.sh
#   bash extract/extract_feature_flags.sh --portal-path /path/to/liferay-portal
#   bash extract/extract_feature_flags.sh --dry-run
#
# Threshold and dampening weight configured in config.yml:
#   feature_flags:
#     dampening_weight:   0.5   # churn multiplier for flagged modules
#     flag_pct_threshold: 0.20  # min % of files with flags to trigger dampening
# =============================================================================

# No set -e — grep returns 1 on no matches which would kill the script
set -uo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PROJECT_ROOT/data"
OUTPUT_FILE="$DATA_DIR/feature_flagged_modules_$(date +%Y%m%d).csv"

PORTAL_PATH="${LIFERAY_PORTAL_PATH:-$HOME/dev/projects/liferay-portal}"
DRY_RUN=false

# Default threshold — overridden by config.yml at apply time, not here
FLAG_PCT_THRESHOLD=0.20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --portal-path) PORTAL_PATH="$2"; shift 2 ;;
    --threshold)   FLAG_PCT_THRESHOLD="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# -----------------------------------------------------------------------------
# Validate
# -----------------------------------------------------------------------------
if [[ ! -d "$PORTAL_PATH/.git" ]]; then
  echo "ERROR: Not a git repository: $PORTAL_PATH"
  echo "  Set LIFERAY_PORTAL_PATH or use --portal-path"
  exit 1
fi

mkdir -p "$DATA_DIR"

echo "============================================================"
echo "  extract_feature_flags.sh"
echo "  Portal path:      $PORTAL_PATH"
echo "  Output:           $OUTPUT_FILE"
echo "  Flag threshold:   ${FLAG_PCT_THRESHOLD} (${FLAG_PCT_THRESHOLD}+ flagged files → is_flagged=TRUE)"
[[ "$DRY_RUN" == true ]] && echo "  Mode:             DRY RUN"
echo "============================================================"

# -----------------------------------------------------------------------------
# Detection patterns
# Any file matching at least one pattern counts as a flagged file
# -----------------------------------------------------------------------------
is_flagged_file() {
  local file="$1"
  grep -lq \
    -e "FeatureFlagManagerUtil\.isEnabled" \
    -e "@FeatureFlag" \
    -e "featureFlagsTest()" \
    -e "feature\.flag\." \
    "$file" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Module scope — same as churn script
# modules/apps/* and modules/dxp/apps/* (direct subdirs)
# portal-impl, portal-kernel
# Excludes: test files, third-party, antlr, osb
# -----------------------------------------------------------------------------

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "  Counting modules to scan..."
  N_APPS=$(find "$PORTAL_PATH/modules/apps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  N_DXP=$(find "$PORTAL_PATH/modules/dxp/apps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  echo "  modules/apps:     $N_APPS subdirs"
  echo "  modules/dxp/apps: $N_DXP subdirs"
  echo "  root modules:     portal-impl, portal-kernel"
  echo ""
  echo "  DRY RUN complete — no file written"
  echo "============================================================"
  exit 0
fi

# -----------------------------------------------------------------------------
# Write header
# -----------------------------------------------------------------------------
echo "module_path,flagged_file_count,total_file_count,flag_pct,is_flagged" > "$OUTPUT_FILE"

# -----------------------------------------------------------------------------
# Scan function
# Args: module_path (relative to portal root), display label
# -----------------------------------------------------------------------------
scan_module() {
  local module_path="$1"
  local module_dir="$PORTAL_PATH/$module_path"

  [[ ! -d "$module_dir" ]] && return

  # Count total source files (Java + JS/TS, exclude test files)
  local total_files
  total_files=$(find "$module_dir" -type f \
      \( -name "*.java" -o -name "*.js" -o -name "*.ts" -o -name "*.tsx" \
         -o -name "*.jsx" -o -name "*.properties" \) \
      ! -path "*/test/*" ! -path "*/tests/*" \
      ! -path "*-test/*" ! -path "*-tests/*" \
      ! -name "*Test.java" ! -name "*.test.js" ! -name "*.test.ts" \
      ! -name "*.spec.js" ! -name "*.spec.ts" \
      2>/dev/null | wc -l | tr -d ' ')

  if [[ "$total_files" -eq 0 ]]; then
    return
  fi

  # Count flagged files
  local flagged_files=0
  while IFS= read -r file; do
    if grep -q \
        -e "FeatureFlagManagerUtil\.isEnabled" \
        -e "@FeatureFlag" \
        -e "featureFlagsTest()" \
        -e "feature\.flag\." \
        "$file" 2>/dev/null; then
      flagged_files=$((flagged_files + 1))
    fi
  done < <(find "$module_dir" -type f \
      \( -name "*.java" -o -name "*.js" -o -name "*.ts" -o -name "*.tsx" \
         -o -name "*.jsx" -o -name "*.properties" \) \
      ! -path "*/test/*" ! -path "*/tests/*" \
      ! -path "*-test/*" ! -path "*-tests/*" \
      ! -name "*Test.java" ! -name "*.test.js" ! -name "*.test.ts" \
      ! -name "*.spec.js" ! -name "*.spec.ts" \
      2>/dev/null)

  # Calculate percentage
  local flag_pct
  flag_pct=$(awk "BEGIN {printf \"%.4f\", $flagged_files / $total_files}")

  # Determine is_flagged based on threshold
  local is_flagged
  is_flagged=$(awk "BEGIN {print ($flag_pct >= $FLAG_PCT_THRESHOLD) ? \"TRUE\" : \"FALSE\"}")

  echo "\"${module_path}\",${flagged_files},${total_files},${flag_pct},${is_flagged}" >> "$OUTPUT_FILE"

  # Progress for flagged modules
  if [[ "$is_flagged" == "TRUE" ]]; then
    echo "  FLAGGED: $module_path (${flagged_files}/${total_files} = $(awk "BEGIN {printf \"%.1f\", $flag_pct * 100}")%)"
  fi
}

# -----------------------------------------------------------------------------
# Scan all modules
# -----------------------------------------------------------------------------
echo ""
echo "  Scanning modules/apps/..."
while IFS= read -r module_dir; do
  module_path="modules/apps/$(basename "$module_dir")"
  scan_module "$module_path"
done < <(find "$PORTAL_PATH/modules/apps" -mindepth 1 -maxdepth 1 -type d | sort)

echo ""
echo "  Scanning modules/dxp/apps/ (excluding osb)..."
while IFS= read -r module_dir; do
  module_path="modules/dxp/apps/$(basename "$module_dir")"
  # Skip osb — excluded from scoring
  [[ "$(basename "$module_dir")" == "osb" ]] && continue
  scan_module "$module_path"
done < <(find "$PORTAL_PATH/modules/dxp/apps" -mindepth 1 -maxdepth 1 -type d | sort)

echo ""
echo "  Scanning root modules..."
for root_mod in "portal-impl" "portal-kernel"; do
  scan_module "$root_mod"
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
TOTAL_ROWS=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
FLAGGED_ROWS=$(grep -c ",TRUE$" "$OUTPUT_FILE" || true)
NOT_FLAGGED=$(( TOTAL_ROWS - FLAGGED_ROWS ))

echo ""
echo "============================================================"
echo "  Done."
echo "  Total modules scanned: $TOTAL_ROWS"
echo "  Flagged (>= ${FLAG_PCT_THRESHOLD}):  $FLAGGED_ROWS"
echo "  Not flagged:           $NOT_FLAGGED"
echo "  Output: $OUTPUT_FILE"
echo "============================================================"