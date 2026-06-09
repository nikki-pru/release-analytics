# Standalone triage image — ghcr.io/liferay-release/triage
#
# Build context is apps/triage/. Because the package is layout-agnostic
# (relative imports + $TRIAGE_CONFIG resolution), the image is just the
# source copied in and run as the `triage` package — no transform step.
#
# Default distribution mode is api×api (Testray REST on both sides), so no
# database is required. The one external runtime dependency is a
# liferay-portal checkout for the git diff — mount it as a volume.
#
# Run:
#   docker run --rm \
#     -e ANTHROPIC_API_KEY=sk-ant-... \
#     -v "$PWD/config.yml":/config/config.yml:ro \
#     -v /path/to/liferay-portal:/portal \
#     ghcr.io/liferay-release/triage \
#     run --baseline-source api --baseline-build-id <A> --baseline-hash <sha> \
#         --target-source   api --target-build-id   <B> --target-hash   <sha> \
#         --no-upsert
FROM python:3.12-slim

# git: prepare.py shells out to `git -C <repo_path> diff` for the hunk extraction.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first for layer caching. Both base + API-mode deps so the
# image can run all four classification paths.
COPY requirements.txt requirements-api.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-api.txt

# The package itself, importable as `triage` (run via `python -m triage.*`).
COPY . /app/triage

# Config resolved from here unless overridden; mount your config.yml to it.
ENV TRIAGE_CONFIG=/config/config.yml

ENTRYPOINT ["/app/triage/entrypoint.sh"]
CMD ["help"]
