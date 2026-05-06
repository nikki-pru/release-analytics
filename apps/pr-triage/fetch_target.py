"""
apps/pr-triage/fetch_target.py

Testray API: fetch the target build's metadata + failing caseresults.

Two endpoints:
  - GET /o/c/builds/{build_id}                                    — project_id + duedate
  - GET /o/testray-rest/v1.0/testray-case-result/{build_id}       — failing rows + errors

We use the rich `testray-rest/v1.0` endpoint (not /o/c/caseresults)
because it returns names, components, status, and the full `error`
text in one paginated call — exactly the shape we need for uniqueness
checking without per-row follow-up.
"""

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional


def _oauth_token(cfg: dict) -> str:
    """OAuth2 client_credentials grant against Testray. Same pattern as
    apps/triage/prepare.py."""
    base = cfg["base_url"].rstrip("/")
    data = urllib.parse.urlencode({
        "grant_type":    "client_credentials",
        "client_id":     cfg["client_id"],
        "client_secret": cfg["client_secret"],
    }).encode()
    req = urllib.request.Request(f"{base}/o/oauth2/token", data=data)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    token = body.get("access_token")
    if not token:
        raise SystemExit(f"OAuth2 token response had no access_token: {body}")
    return token


def _get_json(url: str, token: str) -> dict:
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise SystemExit("Testray API 401 — token expired. Re-run.")
        raise


def fetch_build_meta(build_id: int, cfg: dict) -> dict:
    """Return {build_id, project_id, duedate, name, routine_id} for a build.

    `duedate` comes back as an ISO-8601 string from Testray; the caller
    casts it to a Postgres timestamp parameter. Raises SystemExit if the
    build can't be fetched — there's no sensible default."""
    token = _oauth_token(cfg)
    base  = cfg["base_url"].rstrip("/")
    body  = _get_json(f"{base}/o/c/builds/{build_id}", token)

    # Liferay Object endpoints expose foreign-key fields with the
    # `r_<relation>_c_<targetIdField>` convention. Names are CamelCase
    # in REST output but snake_case in raw schema.
    project_id = (
        body.get("r_projectToBuilds_c_projectId")
        or body.get("r_projecttobuilds_c_projectid")
    )
    routine_id = (
        body.get("r_routineToBuilds_c_routineId")
        or body.get("r_routinetobuilds_c_routineid")
    )
    if project_id is None:
        raise SystemExit(
            f"Build {build_id}: response had no project_id field. "
            f"Response keys: {sorted(body.keys())}"
        )
    return {
        "build_id":   int(build_id),
        "project_id": int(project_id),
        "routine_id": int(routine_id) if routine_id else None,
        "duedate":    body.get("dueDate") or body.get("duedate"),
        "name":       body.get("name"),
    }


def fetch_failing_caseresults(build_id: int, cfg: dict) -> list[dict]:
    """Return list of failing case-results for a build via the rich
    /o/testray-rest endpoint. Each row has the shape user pasted in
    discussion #2:

        testrayCaseResultId, testrayCaseName, testrayComponentName,
        testrayTeamName, testrayRunName, testrayCaseTypeName,
        status, error, flaky, issues, priority, duration, comment

    We filter to status == 'FAILED' here, after the fetch. The endpoint
    doesn't accept a status filter."""
    token = _oauth_token(cfg)
    base  = cfg["base_url"].rstrip("/")
    items: list[dict] = []
    page = 1
    page_size = 500
    while True:
        url = (
            f"{base}/o/testray-rest/v1.0/testray-case-result/{build_id}"
            f"?{urllib.parse.urlencode({'page': page, 'pageSize': page_size})}"
        )
        data = _get_json(url, token)
        items.extend(data.get("items", []))
        last_page = data.get("lastPage", 1)
        print(
            f"   [caseresults build {build_id}] page {page}/{last_page} "
            f"({len(items)} rows so far)",
            file=sys.stderr, flush=True,
        )
        if page >= last_page:
            break
        page += 1
        time.sleep(0.3)

    failed = [it for it in items if (it.get("status") or "") == "FAILED"]
    print(
        f"   total caseresults: {len(items)} · "
        f"FAILED: {len(failed)}",
        file=sys.stderr, flush=True,
    )
    return failed
