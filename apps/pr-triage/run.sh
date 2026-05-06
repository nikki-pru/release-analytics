#!/bin/bash
# =============================================================================
# apps/pr-triage/run.sh
#
# Uniqueness-based PR-triage.
#
# Usage:
#   bash apps/pr-triage/run.sh \
#     --target-branch  PR-38301 \
#     --target-source  api \
#     --target-build-id 471865557 \
#     --base-branch    release-2026.q1
#
# Scope: classify failing tests as UNIQUE_NEW_TEST / UNIQUE_NEW_ERROR /
# NOT_UNIQUE against project history, then match unique failures against
# the PR's diff. Writes a Claude Code bundle under runs/ for human/LLM
# reasoning. No DB write yet.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TARGET_BRANCH=""
TARGET_SOURCE=""
TARGET_BUILD_ID=""
BASE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-branch)   TARGET_BRANCH="$2";   shift 2 ;;
    --target-source)   TARGET_SOURCE="$2";   shift 2 ;;
    --target-build-id) TARGET_BUILD_ID="$2"; shift 2 ;;
    --base-branch)     BASE_BRANCH="$2";     shift 2 ;;
    -h|--help)
      sed -n '2,18p' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1 ;;
  esac
done

if [[ -z "$TARGET_BRANCH" || -z "$TARGET_SOURCE" || -z "$TARGET_BUILD_ID" || -z "$BASE_BRANCH" ]]; then
  echo "Error: --target-branch, --target-source, --target-build-id, and --base-branch are all required" >&2
  echo "" >&2
  sed -n '6,12p' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

if [[ "$TARGET_SOURCE" != "api" ]]; then
  echo "Error: --target-source=$TARGET_SOURCE not supported (only 'api')" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Validate portal repo + both branches exist locally. Wrong base branch
# silently produces a garbage diff, so we hard-require it on the CLI and
# verify it resolves before doing any work.
# -----------------------------------------------------------------------------
PORTAL_REPO=$(
  python3 - <<'PY' "${PLATFORM_DIR}"
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1])
cfg = yaml.safe_load(open(root / "config" / "config.yml"))
print(pathlib.Path(cfg["git"]["repo_path"]).expanduser())
PY
)

if [[ ! -d "$PORTAL_REPO/.git" ]]; then
  echo "Error: portal repo not found at $PORTAL_REPO (config.yml git.repo_path)" >&2
  exit 1
fi

if ! git -C "$PORTAL_REPO" rev-parse --verify "$TARGET_BRANCH" > /dev/null 2>&1; then
  echo "Error: branch '$TARGET_BRANCH' not found in $PORTAL_REPO" >&2
  echo "  Fetch or check out the branch locally first." >&2
  exit 1
fi

if ! git -C "$PORTAL_REPO" rev-parse --verify "$BASE_BRANCH" > /dev/null 2>&1; then
  echo "Error: base branch '$BASE_BRANCH' not found in $PORTAL_REPO" >&2
  echo "  Fetch the base branch locally first (git fetch origin $BASE_BRANCH:$BASE_BRANCH)." >&2
  exit 1
fi

if ! git -C "$PORTAL_REPO" merge-base "$BASE_BRANCH" "$TARGET_BRANCH" > /dev/null 2>&1; then
  echo "Error: no merge base between '$BASE_BRANCH' and '$TARGET_BRANCH'" >&2
  echo "  The branches share no history — check the base branch is correct." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
cd "$PLATFORM_DIR"
exec python3 "${SCRIPT_DIR}/run.py" \
  --target-branch   "$TARGET_BRANCH" \
  --target-source   "$TARGET_SOURCE" \
  --target-build-id "$TARGET_BUILD_ID" \
  --base-branch     "$BASE_BRANCH"
