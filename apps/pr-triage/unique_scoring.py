"""
apps/pr-triage/unique_scoring.py

Query testray_working_db for a case's prior FAILED occurrences in the
project, scoped to builds that closed before the target build's duedate.

Returns the raw `errors_` text per row — caller hashes via
normalize.error_signature_hash so the normalization rule set lives in
one place (Python) and isn't duplicated in SQL.

Schema reference (from user-provided \\d output):
  o_22235989312226_caseresult.r_buildtocaseresult_c_buildid
  o_22235989312226_caseresult.r_casetocaseresult_c_caseid
  o_22235989312226_caseresult.duestatus_                 — 'FAILED' for failed
  o_22235989312226_caseresult.errors_                    — full text
  o_22235989312226_build.c_buildid_
  o_22235989312226_build.r_projecttobuilds_c_projectid
  o_22235989312226_build.duedate_                        — chronological cut

Indexes that make this efficient:
  ix_a8d74b8d (caseresult.r_buildtocaseresult_c_buildid)
  ix_951b8237 (caseresult.r_casetocaseresult_c_caseid)
  ix_bcb6a688 (build.r_projecttobuilds_c_projectid)
"""

from contextlib import contextmanager
from pathlib import Path

import psycopg2
import yaml


def _load_config() -> dict:
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "config" / "config.yml"
        if candidate.exists():
            with open(candidate) as f:
                return yaml.safe_load(f)
    raise FileNotFoundError(
        "config.yml not found. Expected at project root "
        "(liferay-release-analytics/config/config.yml)"
    )


@contextmanager
def get_working_db_conn():
    """Read-only connection to testray_working_db. config.yml shape:

        databases:
          testray_working_db:
            host: localhost
            port: 5432
            dbname: testray_working_db
            user: release
            password: triage_local
    """
    cfg = _load_config().get("databases", {}).get("testray_working_db")
    if not cfg:
        raise SystemExit(
            "config.yml has no databases.testray_working_db block. "
            "See config/config.yml.example."
        )
    conn = psycopg2.connect(
        host=cfg.get("host", "localhost"),
        port=int(cfg.get("port", 5432)),
        dbname=cfg.get("dbname", "testray_working_db"),
        user=cfg["user"],
        password=cfg["password"],
    )
    try:
        yield conn
    finally:
        conn.close()


_HISTORY_SQL = """
SELECT  cr.c_caseresultid_                         AS caseresult_id,
        cr.errors_                                 AS errors,
        b.duedate_                                 AS build_duedate,
        b.c_buildid_                               AS build_id
FROM    o_22235989312226_caseresult cr
JOIN    o_22235989312226_build      b
  ON    b.c_buildid_ = cr.r_buildtocaseresult_c_buildid
WHERE   b.r_projecttobuilds_c_projectid = %s
  AND   cr.r_casetocaseresult_c_caseid  = %s
  AND   b.duedate_ < %s
  AND   cr.duestatus_ = 'FAILED'
ORDER BY b.duedate_ DESC
"""


def fetch_history(
    conn, project_id: int, case_id: int, before_duedate
) -> list[dict]:
    """Return list of {caseresult_id, errors, build_duedate, build_id} for
    every prior FAILED occurrence of this case in the project before the
    cutoff. Empty list = case has never failed in the project before."""
    with conn.cursor() as cur:
        cur.execute(_HISTORY_SQL, (project_id, case_id, before_duedate))
        rows = cur.fetchall()
    return [
        {
            "caseresult_id": r[0],
            "errors":        r[1],
            "build_duedate": r[2],
            "build_id":      r[3],
        }
        for r in rows
    ]


_CASE_ID_BATCH_SQL = """
SELECT  c_caseresultid_,
        r_casetocaseresult_c_caseid
FROM    o_22235989312226_caseresult
WHERE   c_caseresultid_ = ANY(%s)
"""


def resolve_case_ids(conn, caseresult_ids: list[int]) -> dict[int, int]:
    """Batch-resolve {caseresult_id: case_id} via PK lookup. The rich
    /o/testray-rest endpoint returns testrayCaseResultId but not the
    underlying case_id, and we need case_id to key the per-test history
    query. PK index makes this near-instant for typical batch sizes."""
    if not caseresult_ids:
        return {}
    with conn.cursor() as cur:
        cur.execute(_CASE_ID_BATCH_SQL, (caseresult_ids,))
        rows = cur.fetchall()
    return {int(r[0]): int(r[1]) for r in rows if r[1]}
