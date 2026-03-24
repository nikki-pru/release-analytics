#!/usr/bin/env bash
# =============================================================================
# extract_churn.sh
# Extracts code churn metrics per module per release from git history.
#
# Fully regenerates churn CSVs from scratch:
#   data/churn_by_module_Q.csv  — Q releases (cumulative, tag-to-tag)
#   data/churn_by_module_U.csv  — U releases (incremental, consecutive tags)
#
# Usage:
#   bash extract/extract_churn.sh              # run both Q and U modes
#   bash extract/extract_churn.sh --mode Q     # Q releases only
#   bash extract/extract_churn.sh --mode U     # U releases only
#   bash extract/extract_churn.sh --portal-path /path/to/liferay-portal
#   bash extract/extract_churn.sh --dry-run    # preview without writing
#
# Module scope:
#   modules/apps/*     — direct subdirs (category level)
#   modules/dxp/apps/* — direct subdirs (category level)
#   portal-impl        — root-level module
#   portal-kernel      — root-level module
#
# Excludes test files and test directories.
# =============================================================================

set -eo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PROJECT_ROOT/data"
Q_CSV="$DATA_DIR/churn_by_module_Q.csv"
U_CSV="$DATA_DIR/churn_by_module_U.csv"

PORTAL_PATH="${LIFERAY_PORTAL_PATH:-$HOME/dev/projects/liferay-portal}"
MODE="both"   # Q, U, or both
DRY_RUN=false

INCLUDE_TEST_FILES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --portal-path) PORTAL_PATH="$2"; shift 2 ;;
    --mode)        MODE="$2";        shift 2 ;;
    --dry-run)     DRY_RUN=true;     shift ;;
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
echo "  extract_churn.sh"
echo "  Portal path: $PORTAL_PATH"
echo "  Mode:        $MODE"
[[ "$DRY_RUN" == true ]] && echo "  DRY RUN — no files will be written"
echo "============================================================"

# -----------------------------------------------------------------------------
# CSV header
# -----------------------------------------------------------------------------
CSV_HEADER="Quarter,Module,Total_FileCount,Total_LinesOfCode,Total_ModifiedFileCount,Total_Insertions,Total_Deletions,java_FileCount,java_LinesOfCode,java_ModifiedFileCount,java_Insertions,java_Deletions,js_FileCount,js_LinesOfCode,js_ModifiedFileCount,js_Insertions,js_Deletions,jsp_FileCount,jsp_LinesOfCode,jsp_ModifiedFileCount,jsp_Insertions,jsp_Deletions,ts_FileCount,ts_LinesOfCode,ts_ModifiedFileCount,ts_Insertions,ts_Deletions,tsx_FileCount,tsx_LinesOfCode,tsx_ModifiedFileCount,tsx_Insertions,tsx_Deletions,css_FileCount,css_LinesOfCode,css_ModifiedFileCount,css_Insertions,css_Deletions,scss_FileCount,scss_LinesOfCode,scss_ModifiedFileCount,scss_Insertions,scss_Deletions"

EXTENSIONS=("java" "js" "jsp" "ts" "tsx" "css" "scss")

# -----------------------------------------------------------------------------
# Q release ranges
# Tag format: YYYY.qN.P (lowercase q)
# Quarter format: YYYY.QN (uppercase Q)
# -----------------------------------------------------------------------------
Q_QUARTERS=(
  "2024.Q1" "2024.Q2" "2024.Q3" "2024.Q4"
  "2025.Q1" "2025.Q2" "2025.Q3" "2025.Q4"
  "2026.Q1"
)
declare -A Q_RANGES
Q_RANGES["2024.Q1"]="2023.q4.0...2024.q1.1"
Q_RANGES["2024.Q2"]="2024.q1.1...2024.q2.0"
Q_RANGES["2024.Q3"]="2024.q2.0...2024.q3.0"
Q_RANGES["2024.Q4"]="2024.q3.0...2024.q4.0"
Q_RANGES["2025.Q1"]="2024.q4.0...2025.q1.0"
Q_RANGES["2025.Q2"]="2025.q1.0...2025.q2.0"
Q_RANGES["2025.Q3"]="2025.q2.0...2025.q3.0"
Q_RANGES["2025.Q4"]="2025.q3.0...2025.q4.0"
Q_RANGES["2026.Q1"]="2025.q4.0...2026.q1.0"

# -----------------------------------------------------------------------------
# U release ranges
# Tag format: 7.4.13-uN
# Gaps (no tag): U115, U117, U119, U125 — these are skipped
# -----------------------------------------------------------------------------
U_RELEASES=(
  "U110" "U111" "U112" "U113" "U114"
  "U116" "U118"
  "U120" "U121" "U122" "U123" "U124"
  "U126" "U127" "U128" "U129" "U130"
  "U131" "U132" "U133" "U134" "U135"
  "U136" "U137" "U138" "U139" "U140"
  "U141" "U142" "U143" "U144" "U145"
  "U146" "U147"
)
declare -A U_RANGES
U_RANGES["U110"]="7.4.13-u109...7.4.13-u110"
U_RANGES["U111"]="7.4.13-u110...7.4.13-u111"
U_RANGES["U112"]="7.4.13-u111...7.4.13-u112"
U_RANGES["U113"]="7.4.13-u112...7.4.13-u113"
U_RANGES["U114"]="7.4.13-u113...7.4.13-u114"
U_RANGES["U116"]="7.4.13-u114...7.4.13-u116"
U_RANGES["U118"]="7.4.13-u116...7.4.13-u118"
U_RANGES["U120"]="7.4.13-u118...7.4.13-u120"
U_RANGES["U121"]="7.4.13-u120...7.4.13-u121"
U_RANGES["U122"]="7.4.13-u121...7.4.13-u122"
U_RANGES["U123"]="7.4.13-u122...7.4.13-u123"
U_RANGES["U124"]="7.4.13-u123...7.4.13-u124"
U_RANGES["U126"]="7.4.13-u124...7.4.13-u126"
U_RANGES["U127"]="7.4.13-u126...7.4.13-u127"
U_RANGES["U128"]="7.4.13-u127...7.4.13-u128"
U_RANGES["U129"]="7.4.13-u128...7.4.13-u129"
U_RANGES["U130"]="7.4.13-u129...7.4.13-u130"
U_RANGES["U131"]="7.4.13-u130...7.4.13-u131"
U_RANGES["U132"]="7.4.13-u131...7.4.13-u132"
U_RANGES["U133"]="7.4.13-u132...7.4.13-u133"
U_RANGES["U134"]="7.4.13-u133...7.4.13-u134"
U_RANGES["U135"]="7.4.13-u134...7.4.13-u135"
U_RANGES["U136"]="7.4.13-u135...7.4.13-u136"
U_RANGES["U137"]="7.4.13-u136...7.4.13-u137"
U_RANGES["U138"]="7.4.13-u137...7.4.13-u138"
U_RANGES["U139"]="7.4.13-u138...7.4.13-u139"
U_RANGES["U140"]="7.4.13-u139...7.4.13-u140"
U_RANGES["U141"]="7.4.13-u140...7.4.13-u141"
U_RANGES["U142"]="7.4.13-u141...7.4.13-u142"
U_RANGES["U143"]="7.4.13-u142...7.4.13-u143"
U_RANGES["U144"]="7.4.13-u143...7.4.13-u144"
U_RANGES["U145"]="7.4.13-u144...7.4.13-u145"
U_RANGES["U146"]="7.4.13-u145...7.4.13-u146"
U_RANGES["U147"]="7.4.13-u146...7.4.13-u147"

# -----------------------------------------------------------------------------
# Module list — direct subdirs of target directories + root-level modules
# -----------------------------------------------------------------------------
get_modules() {
  local portal="$1"
  local modules=()

  # modules/apps/* — direct subdirs only (category level)
  if [[ -d "$portal/modules/apps" ]]; then
    while IFS= read -r d; do
      modules+=("$(basename "$d")" "modules/apps/$(basename "$d")")
    done < <(find "$portal/modules/apps" -mindepth 1 -maxdepth 1 -type d | sort)
  fi

  # modules/dxp/apps/* — direct subdirs only
  if [[ -d "$portal/modules/dxp/apps" ]]; then
    while IFS= read -r d; do
      modules+=("$(basename "$d")" "modules/dxp/apps/$(basename "$d")")
    done < <(find "$portal/modules/dxp/apps" -mindepth 1 -maxdepth 1 -type d | sort)
  fi

  echo "${modules[@]}"
}

# -----------------------------------------------------------------------------
# Process one module for one release
# Returns CSV row (without newline)
# -----------------------------------------------------------------------------
process_module() {
  local portal="$1" release="$2" tag1="$3" tag2="$4" module_path="$5"
  local module_dir="$portal/$module_path"
  [[ ! -d "$module_dir" ]] && return

  local total_files=0 total_loc=0 total_modified=0 total_insertions=0 total_deletions=0
  local ext_metrics=""

  for ext in "${EXTENSIONS[@]}"; do
    local file_c=0 loc_c=0 mod_c=0 ins_c=0 del_c=0

    # Static: file count + LOC
    local static_data
    set +e
    static_data=$(find "$module_dir" -type f -name "*.${ext}" \
        ! -path "*/test/*" ! -path "*/tests/*" \
        ! -path "*-test/*" ! -path "*-tests/*" \
        ! -name "*Test.java" ! -name "*Test.js" ! -name "*Test.ts" ! -name "*Test.tsx" \
        ! -name "*.test.js" ! -name "*.test.ts" ! -name "*.test.tsx" \
        ! -name "*.spec.js" ! -name "*.spec.ts" ! -name "*.spec.tsx" \
        2>/dev/null | awk '{
          while ((getline line < $0) > 0) loc++
          close($0)
          fc++
        } END { printf "%d %d", fc+0, loc+0 }' 2>/dev/null)
    set -e
    read -r file_c loc_c <<< "${static_data:-0 0}" || true
    file_c="${file_c:-0}"; loc_c="${loc_c:-0}"

    # Git metrics — use set +e to prevent grep -v with no matches killing the pipeline
    local git_raw git_stats
    set +e
    git_raw=$(cd "$portal" && git diff --numstat "$tag1" "$tag2" -- "${module_path}/" 2>/dev/null)
    git_stats=$(echo "$git_raw" | \
      grep "\.${ext}$" | \
      grep -v '/test/' | grep -v '/tests/' | grep -v '\-test/' | grep -v '\-tests/' | \
      grep -v "Test\.${ext}$" | grep -v "\.test\.${ext}$" | grep -v "\.spec\.${ext}$" | \
      awk '{ins+=$1; del+=$2; fc++} END {printf "%d %d %d", fc+0, ins+0, del+0}' 2>/dev/null)
    set -e
    mod_c=0; ins_c=0; del_c=0
    read -r mod_c ins_c del_c <<< "${git_stats:-0 0 0}" || true
    mod_c="${mod_c:-0}"; ins_c="${ins_c:-0}"; del_c="${del_c:-0}"

    total_files=$((total_files + file_c))
    total_loc=$((total_loc + loc_c))
    total_modified=$((total_modified + mod_c))
    total_insertions=$((total_insertions + ins_c))
    total_deletions=$((total_deletions + del_c))
    ext_metrics="${ext_metrics},${file_c},${loc_c},${mod_c},${ins_c},${del_c}"
  done

  echo "\"${release}\",\"${module_path}\",${total_files},${total_loc},${total_modified},${total_insertions},${total_deletions}${ext_metrics}"
}

process_root_module() {
  local portal="$1" release="$2" tag1="$3" tag2="$4" module_name="$5"
  local module_dir="$portal/$module_name"
  [[ ! -d "$module_dir" ]] && return

  local total_files=0 total_loc=0 total_modified=0 total_insertions=0 total_deletions=0
  local ext_metrics=""

  for ext in "${EXTENSIONS[@]}"; do
    local file_c=0 loc_c=0 mod_c=0 ins_c=0 del_c=0

    local static_data
    set +e
    static_data=$(find "$module_dir" -type f -name "*.${ext}" \
        ! -path "*/test/*" ! -path "*/tests/*" \
        ! -name "*Test.java" ! -name "*.test.js" ! -name "*.spec.js" \
        2>/dev/null | awk '{
          while ((getline line < $0) > 0) loc++
          close($0)
          fc++
        } END { printf "%d %d", fc+0, loc+0 }' 2>/dev/null)
    set -e
    read -r file_c loc_c <<< "${static_data:-0 0}" || true
    file_c="${file_c:-0}"; loc_c="${loc_c:-0}"

    local git_raw git_stats
    set +e
    git_raw=$(cd "$portal" && git diff --numstat "$tag1" "$tag2" -- "${module_name}/" 2>/dev/null)
    git_stats=$(echo "$git_raw" | \
      grep "\.${ext}$" | \
      grep -v '/test/' | grep -v '/tests/' | \
      grep -v "Test\.${ext}$" | grep -v "\.test\.${ext}$" | grep -v "\.spec\.${ext}$" | \
      awk '{ins+=$1; del+=$2; fc++} END {printf "%d %d %d", fc+0, ins+0, del+0}' 2>/dev/null)
    set -e
    mod_c=0; ins_c=0; del_c=0
    read -r mod_c ins_c del_c <<< "${git_stats:-0 0 0}" || true
    mod_c="${mod_c:-0}"; ins_c="${ins_c:-0}"; del_c="${del_c:-0}"

    total_files=$((total_files + file_c))
    total_loc=$((total_loc + loc_c))
    total_modified=$((total_modified + mod_c))
    total_insertions=$((total_insertions + ins_c))
    total_deletions=$((total_deletions + del_c))
    ext_metrics="${ext_metrics},${file_c},${loc_c},${mod_c},${ins_c},${del_c}"
  done

  echo "\"${release}\",\"${module_name}\",${total_files},${total_loc},${total_modified},${total_insertions},${total_deletions}${ext_metrics}"
}

run_mode() {
  local mode="$1"       # Q or U
  local output="$2"     # output CSV path
  local -n releases=$3  # nameref to release array
  local -n ranges=$4    # nameref to ranges associative array

  echo ""
  echo "  === Mode: $mode ==="
  echo "  Output: $output"

  if [[ "$DRY_RUN" == true ]]; then
    for release in "${releases[@]}"; do
      local range="${ranges[$release]}"
      local tag1="${range%%...*}"
      local tag2="${range##*...}"
      if cd "$PORTAL_PATH" && git rev-parse "$tag1" &>/dev/null && git rev-parse "$tag2" &>/dev/null; then
        echo "  [$release] WOULD process: $range"
      else
        echo "  [$release] SKIP — tag(s) not found: $range"
      fi
    done
    return
  fi

  # Write header
  echo "$CSV_HEADER" > "$output"
  echo "  Header written to $output"

  # Build module list once
  local module_paths=()
  while IFS= read -r d; do
    module_paths+=("modules/apps/$(basename "$d")")
  done < <(find "$PORTAL_PATH/modules/apps" -mindepth 1 -maxdepth 1 -type d | sort)
  while IFS= read -r d; do
    module_paths+=("modules/dxp/apps/$(basename "$d")")
  done < <(find "$PORTAL_PATH/modules/dxp/apps" -mindepth 1 -maxdepth 1 -type d | sort)

  local root_modules=("portal-impl" "portal-kernel")

  local total_releases=0
  local total_rows=0

  for release in "${releases[@]}"; do
    local range="${ranges[$release]}"
    local tag1="${range%%...*}"
    local tag2="${range##*...}"

    # Verify tags exist
    if ! cd "$PORTAL_PATH" && git rev-parse "$tag1" &>/dev/null; then
      echo "  [$release] SKIP — tag not found: $tag1"
      continue
    fi
    if ! git rev-parse "$tag2" &>/dev/null; then
      echo "  [$release] SKIP — tag not found: $tag2"
      continue
    fi

    echo ""
    echo "  [$release] Processing: $tag1 → $tag2"
    local release_rows=0

    # modules/apps/* and modules/dxp/apps/*
    for module_path in "${module_paths[@]}"; do
      local row
      row=$(process_module "$PORTAL_PATH" "$release" "$tag1" "$tag2" "$module_path" || true)
      if [[ -n "$row" ]]; then
        echo "$row" >> "$output"
        release_rows=$((release_rows + 1))
      fi
    done

    # portal-impl, portal-kernel
    for root_mod in "${root_modules[@]}"; do
      local row
      row=$(process_root_module "$PORTAL_PATH" "$release" "$tag1" "$tag2" "$root_mod" || true)
      if [[ -n "$row" ]]; then
        echo "$row" >> "$output"
        release_rows=$((release_rows + 1))
      fi
    done

    echo "  [$release] Rows written: $release_rows"
    total_releases=$((total_releases + 1))
    total_rows=$((total_rows + release_rows))
  done

  echo ""
  echo "  [$mode] Complete — $total_releases releases, $total_rows rows → $output"
}

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------
cd "$PORTAL_PATH"

if [[ "$MODE" == "Q" || "$MODE" == "both" ]]; then
  run_mode "Q" "$Q_CSV" Q_QUARTERS Q_RANGES
fi

if [[ "$MODE" == "U" || "$MODE" == "both" ]]; then
  run_mode "U" "$U_CSV" U_RELEASES U_RANGES
fi

echo ""
echo "============================================================"
if [[ "$DRY_RUN" == true ]]; then
  echo "  DRY RUN complete — no files written"
else
  echo "  Done."
  [[ "$MODE" == "Q" || "$MODE" == "both" ]] && echo "  Q CSV: $Q_CSV"
  [[ "$MODE" == "U" || "$MODE" == "both" ]] && echo "  U CSV: $U_CSV"
fi
echo "============================================================"