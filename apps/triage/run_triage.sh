#!/usr/bin/env bash
# apps/triage/run_triage.sh
#
# Claude Code mode entry point — runs apps.triage.prepare and prints the
# bundle path. Classification happens in your Claude Code session
# (read prompt.md, write results.json), then run apps.triage.submit on
# the bundle path printed below.
#
# For the headless / Jenkins API path that chains prepare + classify_api
# + submit automatically, use run_triage_api.sh instead.
#
# Usage:
#   # Both builds in testray_analytical (the common case)
#   ./apps/triage/run_triage.sh --build-a <A> --build-b <B>
#
#   # Mixed sources — pass through to prepare.py directly, no --build-a
#   ./apps/triage/run_triage.sh \
#       --baseline-source db  --baseline-build-id 451312408 \
#       --target-source   csv --target-build-id   462975400 \
#           --target-csv ~/Downloads/case_results.csv --target-hash <sha>
#
#   # No flags → interactive prompts for both build ids (db × db).
#   ./apps/triage/run_triage.sh
#
# Flags:
#   --build-a <id>             Baseline build id. Implies --baseline-source=db.
#   --build-b <id>             Target build id. Implies --target-source=db.
#   --baseline-source ...      Full orthogonal source flags pass through to
#   --target-source   ...      apps.triage.prepare (use for csv/api sides).
#   --by-subtask               Subtask-aware mode — pass through to prepare.py.
#   -h, --help                 Show this help.

set -eo pipefail

# Layout-agnostic: run the package by its directory name from its parent,
# so this works both in-repo (apps/triage -> `-m triage.…` from apps/) and
# standalone (triage/ -> `-m triage.…` from its parent).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(basename "$SCRIPT_DIR")"
cd "$SCRIPT_DIR/.."

BUILD_A=""
BUILD_B=""
PREPARE_EXTRA=()

show_help() {
    sed -n '/^# Usage:/,/^# *-h, --help/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-a)        BUILD_A="$2";    shift 2 ;;
        --build-b)        BUILD_B="$2";    shift 2 ;;
        --by-subtask)     PREPARE_EXTRA+=(--by-subtask); shift ;;
        -h|--help)        show_help; exit 0 ;;
        --baseline-source|--baseline-build-id|--baseline-csv|--baseline-hash|--baseline-name|\
        --target-source|--target-build-id|--target-csv|--target-hash|--target-name)
            PREPARE_EXTRA+=("$1" "$2"); shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

has_flag() {
    local needle="$1"
    for arg in "${PREPARE_EXTRA[@]}"; do
        [[ "$arg" == "$needle" ]] && return 0
    done
    return 1
}

if [[ -n "$BUILD_A" ]]; then
    if has_flag "--baseline-source" || has_flag "--baseline-build-id"; then
        echo "Error: --build-a conflicts with --baseline-source / --baseline-build-id. Pick one." >&2
        exit 1
    fi
    PREPARE_EXTRA+=(--baseline-source db --baseline-build-id "$BUILD_A")
fi
if [[ -n "$BUILD_B" ]]; then
    if has_flag "--target-source" || has_flag "--target-build-id"; then
        echo "Error: --build-b conflicts with --target-source / --target-build-id. Pick one." >&2
        exit 1
    fi
    PREPARE_EXTRA+=(--target-source db --target-build-id "$BUILD_B")
fi

if ! has_flag "--baseline-build-id" && ! has_flag "--target-build-id"; then
    echo ""
    read -rp "Enter Build A (baseline, older build) ID: " BUILD_A
    read -rp "Enter Build B (target,  newer build)  ID: " BUILD_B
    if [[ -z "$BUILD_A" || -z "$BUILD_B" ]]; then
        echo "Error: both Build A and Build B required." >&2
        exit 1
    fi
    PREPARE_EXTRA+=(--baseline-source db --baseline-build-id "$BUILD_A")
    PREPARE_EXTRA+=(--target-source   db --target-build-id   "$BUILD_B")
fi

echo ""
echo "=========================================================="
echo "apps.triage.prepare"
echo "=========================================================="

PREPARE_OUT=$(python3 -m "$PKG.prepare" "${PREPARE_EXTRA[@]}" | tee /dev/stderr)

RUN_DIR=$(printf '%s\n' "$PREPARE_OUT" | sed -n 's|^Run bundle ready: ||p' | tail -1)
if [[ -z "$RUN_DIR" ]]; then
    echo "Error: could not extract run_dir from prepare output. Did prepare fail?" >&2
    exit 1
fi

cat <<EOF

==========================================================
Bundle ready — classify in your Claude Code session
==========================================================

Bundle:   $RUN_DIR

Next steps:
  1. In Claude Code, read $RUN_DIR/prompt.md and classify each
     non-flaky, non-pre-classified row per the rubric in
     .claude/skills/triage.skill.
  2. Write $RUN_DIR/results.json matching results.schema.json.
  3. Submit:
       python3 -m "$PKG.submit" $RUN_DIR
     Add --no-upsert to validate + print the summary without
     writing to fact_triage_results.

For headless / Jenkins runs that skip the in-session step, use
run_triage_api.sh instead.
EOF
