#!/usr/bin/env bash
# Container entrypoint — dispatches to the triage package.
# WORKDIR is /app, so `python -m triage.*` resolves the package at /app/triage.
set -euo pipefail

cmd="${1:-help}"
shift || true

case "$cmd" in
    prepare)
        exec python -m triage.prepare "$@" ;;
    classify)
        exec python -m triage.classify_api "$@" ;;
    submit)
        exec python -m triage.submit "$@" ;;
    run)
        # Full api-mode pipeline: prepare -> classify_api -> submit.
        exec /app/triage/run_triage_api.sh "$@" ;;
    help|-h|--help)
        cat <<'EOF'
triage — Testray regression triage

Usage: docker run ... ghcr.io/liferay-release/triage <command> [args]

Commands:
  prepare   Build a run bundle           (python -m triage.prepare ...)
  classify  Classify a bundle via API    (python -m triage.classify_api <run_dir> ...)
  submit    Validate + persist results   (python -m triage.submit <run_dir> ...)
  run       One-shot api pipeline         (prepare -> classify -> submit)
  help      Show this message

Mounts/env:
  -e ANTHROPIC_API_KEY=...                  required for classify / run
  -v <config.yml>:/config/config.yml:ro     testray creds, git.repo_path, classifier
  -v <liferay-portal>:/portal               checkout for the git diff (repo_path: /portal)

Example (api×api, no DB):
  docker run --rm -e ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
    -v "$PWD/config.yml":/config/config.yml:ro -v /src/liferay-portal:/portal \
    ghcr.io/liferay-release/triage run \
      --baseline-source api --baseline-build-id <A> --baseline-hash <sha> \
      --target-source   api --target-build-id   <B> --target-hash   <sha> \
      --no-upsert
EOF
        ;;
    *)
        echo "Unknown command: $cmd (try 'help')" >&2
        exit 1 ;;
esac
