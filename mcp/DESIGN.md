# Testray MCP Server — Design

Location: `release-analytics/mcp/`
Status: design / pre-implementation
Last updated: 2026-04-26

## Purpose

Expose read-only access to Testray via the Model Context Protocol so that Claude Code, running against a dev's local RAP clone, can fetch case results and build metadata as structured tool calls instead of ad-hoc HTTP or SQL.

The MCP is the **bridge between Claude Code and Testray**. RAP is consumed separately via shell/SQL from the RAP clone. The two data sources are combined by Claude Code at reasoning time, not by the MCP.

## Mental model

Three data layers, each with one owner:

- **Testray** — operational identity layer. Builds, case results, components, teams. Source of truth for what was tested and what happened. Accessed via this MCP.
- **RAP** — intelligence layer. Complexity, churn, LPD/LPP, composite risk, forecasts. Accessed via shell/SQL in the RAP clone.
- **Release registry (`releases.yml`)** — join table for release labels, quarters, git tags, dates. Accessed by Claude Code as a plain file.

The MCP is deliberately dumb about RAP taxonomy (component canonicalization, team mapping, release labels). Those live in `releases.yml` and `module_component_map.csv`. The MCP surfaces Testray's own strings and lets Claude Code resolve them against RAP-side taxonomy. If a proposed change makes the MCP smarter about RAP, push back — that smartness belongs in Claude Code or in the RAP repo.

## Use cases driving scope

**1. Release scoring.** Dev asks "what should I watch for in release 2026.Q1.2 for my team Content Management?" Claude Code resolves the release via `releases.yml`, resolves the team/component via `module_component_map.csv`, queries RAP for complexity/churn/LPD signals, and queries the MCP for Testray case result summaries scoped to the release's builds.

**2. Weekly triage.** Dev asks "based on last week's development and test results, any failures I should watch?" Claude Code identifies the active release, scopes to the Acceptance routine for the last-week date range, uses the MCP to find builds with failures and drill into specific case results, and enriches with RAP data for PR/churn context.

## Scope

**In v1:**

- Read-only Testray API access
- Case results (primary)
- Build metadata (primary)
- Case definitions and case history (supporting)
- Bounded-scope queries enforced at the schema level

**Out of v1:**

- Writes (mutations, status updates, comments)
- Attachment content download (URLs only)
- Subtask management
- Cross-routine queries in a single call
- Anything that would require >20 API calls per tool invocation

**Deferred explicitly:**

- Testray-side migration (see Migration implications below)
- Sync script that populates `build_id` into `releases.yml` for RELEASED entries
- Writes once the read pattern is battle-tested

## Tool surface

Eight tools, all read-only.

| Tool | Purpose | Scope enforcement |
|---|---|---|
| `list_builds` | List builds for a routine with filters | routine_id required; date_range OR limit required |
| `get_build` | Single build detail (authoritative `git_hash`) | build_id required |
| `list_case_results` | Case results for a build, with filters | build_id required; paginated |
| `summarize_case_results` | Counts grouped by dimension | scope required; uses build-level stats when possible |
| `get_case_result` | Single case result detail with attachments | case_result_id required |
| `get_case` | Case definition | case_id required |
| `get_case_history` | Recent executions of a case across builds | case_id required; limit hard-capped |
| `compare_builds` | PASSED→FAILED / FAILED→PASSED / new-failure deltas | two build_ids required |

`compare_builds` is a convenience wrapper over `list_case_results` on both builds and is in v1 because it's the single most common triage action.

## Stack

- **Python** with the official `mcp` SDK using `FastMCP` (decorator-based tool definitions).
- **httpx** for async HTTP to Testray.
- **pydantic** for tool input/output schemas and config validation.
- **pyyaml** for `config.yml` parsing.
- **uv** for dependency management.
- **stdio transport** for local per-dev deployment.

Rationale: rest of the triage tooling in `apps/triage/` is Python, devs are already on Claude Code, FastMCP removes boilerplate, stdio is trivial for local runs. No language switch, no service to stand up.

## Repository layout

```
mcp/
├── README.md                  # run instructions, auth, canonical call patterns
├── DESIGN.md                  # this document
├── CLAUDE.md                  # conventions for Claude Code sessions building this MCP
├── pyproject.toml
├── src/testray_mcp/
│   ├── server.py              # FastMCP app, tool registration
│   ├── client.py              # Testray HTTP client — NO MCP imports
│   ├── config.py              # config.yml loader + pydantic schema
│   ├── models/
│   │   ├── build.py
│   │   ├── case_result.py
│   │   └── case.py
│   └── tools/
│       ├── builds.py
│       ├── cases.py
│       └── compare.py
└── tests/
```

## The load-bearing architectural rule

`client.py` contains zero MCP imports. Tool handlers are thin adapters: they call client methods and shape responses into Pydantic models. This separation is the entire point of the design — when the MCP migrates onto Testray-side, only `client.py` gets swapped.

Things that **must not** leak out of `client.py`:

- HTTP response shapes (`r_buildToCaseResult_c_buildId`, etc.)
- Testray's filter syntax (`?status=FAILED`)
- Pagination query construction
- Auth token handling
- Retry / timeout logic
- Stringy-null coercion (`gitHash: "null"` → `None`)
- Double-encoded JSON parsing (`attachments`)

If any of these show up in a tool handler, it's a migration hazard. Push it back.

## Configuration

`config.yml` gains a `testray:` block:

```yaml
testray:
  base_url: https://testray.liferay.com
  auth_token: <personal OAuth token>
  timeout: 30
  routines:
    release:    "82964"
    acceptance: "590307"
    stable:     "79529"
```

Existing RAP database credentials are untouched. The auth model changes in the Testray-side version (see Migration implications); keeping `testray:` separate now means the RAP consumers of `config.yml` don't need to know or care.

Rules: never repeat or store credentials elsewhere; never log them; never echo them back in error messages. The `routines` block is the canonical place for routine ID lookups — new routines get added here, never hardcoded in tool handlers.

## Bounded-scope discipline

Unbounded queries against Testray are a quick route to slow responses and irrelevant data. The MCP enforces scope **structurally** via a discriminated union:

```python
class BuildScope(BaseModel):
    kind: Literal["build"] = "build"
    build_id: str

class BuildsScope(BaseModel):
    kind: Literal["builds"] = "builds"
    build_ids: list[str]   # 1 <= len <= 20

class DateRangeScope(BaseModel):
    kind: Literal["date_range"] = "date_range"
    routine_id: str
    start: datetime
    end: datetime          # end - start <= 14 days

Scope = Annotated[
    BuildScope | BuildsScope | DateRangeScope,
    Field(discriminator="kind"),
]
```

Tools that operate over case results take `Scope` as their first input. There is no "all case results in routine X" mode. The 14-day cap on date ranges is a hard cap chosen to match the largest reasonable triage window.

Per-tool hard limits beyond the scope type:

- `list_case_results`: `page_size <= 200`
- `get_case_history`: `limit <= 100`
- `list_builds`: requires either `date_range` or `limit <= 100`

Relaxing scope caps is a design change, not an implementation tweak. Discuss before doing it.

## Pagination

Page-based, matching Testray's native pattern (`page`, `pageSize`, `lastPage`, `totalCount`). Decision: adopt Testray's shape rather than inventing cursors, because (a) the mapping is 1:1 and (b) `totalCount` is genuinely useful for size estimation before drilling in.

Build-level pre-aggregated stats (`caseResultPassed`, `caseResultFailed`, etc.) are surfaced as `Build.stats` so that questions like "how many failures in build X" answer in one call, not 82. `summarize_case_results` should use these whenever scope is build-level, instead of paginating through case results.

## Pydantic models

### Build (frozen, validated)

```python
class BuildStats(BaseModel):
    passed: int
    failed: int
    blocked: int
    untested: int
    test_fix: int
    incomplete: int
    did_not_run: int
    in_progress: int

class Build(BaseModel):
    id: int
    name: str
    routine_id: int             # alias from r_routineToBuilds_c_routineId
    promoted: bool
    archived: bool
    git_hash: str | None        # "null" string coerced to None; authoritative only via get_build
    github_compare_urls: str | None
    created_at: datetime
    modified_at: datetime
    due_date: datetime | None
    import_status: str          # flattened from {key, name}
    stats: BuildStats
```

Known quirks handled at the client boundary:

- `gitHash: "null"` (string) coerced to `None`
- `r_routineToBuilds_c_routineId` renamed to `routine_id`
- Internal noise fields dropped: `actions`, `creator`, `keywords`, `taxonomyCategoryBriefs`, `template*`, all `*ERC` fields, `playwrightReports`, the Liferay object lifecycle `status` (different concept from build/case-result status — confusing name collision)
- `get_build` returns authoritative `git_hash`; `list_builds` may return `None` even when the DB has it (list-endpoint hydration quirk)

### Case result models (in progress, not yet frozen)

Two API surfaces exist in Testray; the MCP splits them across tools:

- `CaseResultSummary` from `/o/testray-rest/v1.0/testray-case-result/{build_id}` — flat shape, denormalized human names, no build_id per item (scoped by URL). Used by `list_case_results`.
- `CaseResultDetail` from `/o/c/caseresults/{id}` — raw shape, linked IDs, attachments, dates. Used by `get_case_result`.
- `CaseResultHistoryItem` from `/o/c/cases/{case_id}/caseToCaseResult` — raw shape with `build_id` per item. Used by `get_case_history`.

Don't try to unify these into one model. The shapes carry different information for different reasons; collapsing them loses fidelity.

Client-boundary normalization required for all three:

- `error` (flat) and `errors` (raw) → both aliased to `error`
- `attachments` is double-encoded JSON in the raw shape; parse at client boundary into `list[Attachment]` where each has `name`, `value`, `url`
- All `r_*_c_*Id` fields aliased to clean snake_case (`build_id`, `case_id`, `component_id`, `team_id`, `run_id`, `user_id`, `subtask_id`)
- `testray*Name` prefix dropped (`testrayCaseName` → `case_name`)

`get_case` contract is not yet validated. Pending sample from `/o/c/cases/{case_id}`.

## Canonical call patterns

Documented in README, referenced here so design intent is clear:

**Release scoring (RELEASED release):**
```
releases.yml lookup → build_id available
→ list_case_results(scope=build) with status/component/team filters
→ summarize_case_results if a count answer suffices
```

**Release scoring (IN_DEVELOPMENT release):**
```
releases.yml lookup → quarter + date window, no build_id yet
→ list_builds(routine_id=release, name_contains=<label>, promoted=true)
→ get_build(build_id) for authoritative git_hash if needed
→ proceed as above
```

**Weekly triage on Acceptance:**
```
releases.yml → identify active release context
→ list_builds(routine_id=acceptance, date_range=last_week)
→ for each build with stats.failed > 0: list_case_results(scope=build, status=FAILED)
→ get_build(build_id) to correlate git SHA with RAP churn, when desired
```

## Validation status

| Area | Status | Notes |
|---|---|---|
| `list_builds` schema | ✅ frozen | Validated against Stable, Release, Acceptance routines. Known quirk: `git_hash` unreliable on list endpoint. |
| `get_build` schema | ✅ frozen | Validated on Acceptance build 468171804 and Release build 462975400. `promoted=true` confirmed working. |
| `list_case_results` schema | 🟡 in progress | Flat shape mapped. Filter syntax for non-status fields still to confirm. |
| `get_case_result` schema | 🟡 in progress | Raw shape mapped. Attachments double-encoding handled at client. |
| `get_case_history` schema | 🟡 in progress | Endpoint identified. Scale confirmed (2875 results on one case → hard limit required). |
| `get_case` schema | 🔴 unvalidated | Endpoint presumed to be `/o/c/cases/{case_id}`; sample needed. |
| `summarize_case_results` contract | 🟡 open | Build-stats short-circuit confirmed; group_by dimensions still to scope. |
| `compare_builds` contract | 🟡 open | Intended as a convenience wrapper; shape TBD. |

**Don't implement yellow/red items without sampling the real endpoint first.** The design is built on observed response shapes, not assumed ones. Past surprises:

- Testray exposes two different API surfaces with different field shapes for the same conceptual entity
- `attachments` is a JSON string inside a JSON field
- `gitHash` comes back as the literal string `"null"` rather than JSON null on the list endpoint
- `gitHash` is reliably populated on the detail endpoint but not the list endpoint

Assume more surprises exist for the unvalidated tools. Pull a sample, walk the six-step validation, then implement.

## Migration implications

The MCP is built in two phases, and the v1 design is intentional about what survives and what gets swapped.

**Phase 1 — Local-per-dev (this work):** MCP wraps Testray's public API over HTTP. Auth via personal OAuth token in `config.yml`. Response shapes match Liferay Headless serialization. Network-bound, subject to API rate limits.

**Phase 2 — Testray-side (future):** MCP runs inside Testray and queries Postgres directly. No HTTP, no list-endpoint hydration quirks, no stringy nulls. Auth is whatever Testray uses internally (likely app-scoped OAuth or a service context), not dev tokens. Query shape is SQL, not REST filters.

The **tool contract** — names, parameters, response shapes Claude Code sees — is identical across both phases. This is the whole point of MCP as an abstraction layer. Claude Code calls `list_case_results(scope, status=FAILED)` and does not know or care whether the implementation is HTTP or SQL.

**The "would this make sense in SQL" heuristic.** When making any change, ask: "would this still work in a Postgres-backed implementation?" Examples:

- ✅ Stringy-null `gitHash` coercion in `client.py` — drops cleanly in Phase 2
- ✅ Two-call `list_builds` then `get_build` for authoritative `git_hash` — collapses to one SELECT in Phase 2, no contract change
- ✅ `compare_builds` as a wrapper over two `list_case_results` calls — becomes one SQL query in Phase 2
- ❌ Tool handler that does `if response['r_buildToCaseResult_c_buildId']:` — leaks API shape into Phase 2

The heuristic is the cheap version of "is this a migration hazard".

**What survives the migration unchanged:**

- Tool names, parameters, response models
- Scope types and validation
- Pagination semantics
- `config.yml`'s `testray.routines` block (routine IDs don't change)

**What changes in the migration:**

- `client.py` replaced wholesale — HTTP calls become SQL queries
- Auth section of `config.yml` replaced with whatever Testray uses internally
- Rate-limit handling (if added in v1) is removed — no API rate limits when you are the API

**API-era workarounds the migration can drop:**

- Stringy-null coercion for `gitHash` and `githubCompareURLs` (Postgres columns are nullable normally)
- Double-encoded attachments JSON parsing (real Postgres column, probably `jsonb`)
- Relationship-field aliasing (`r_buildToCaseResult_c_buildId` → `build_id`) (SQL joins produce clean column names)
- Two-endpoint dance for authoritative `git_hash` (one SELECT, always hydrated)

These should be documented as API-era artifacts in the client module so the migrator has a checklist.

**One deliberate design choice deferred to the migration:**

Page-based pagination works in both phases. It's a convenience match in Phase 1 and trivially implementable as `LIMIT N OFFSET (page-1)*N` in Phase 2. If keyset pagination is wanted in Phase 2 for correctness, it can be added as a separate cursor-based input on the same tools without breaking existing callers. Keep the door open; don't walk through it now.

## Test surface

Tests directory exists; no v1 tests yet. When tests get written:

- `client.py` tests use **recorded HTTP responses** — the JSON samples we validated against during design. Don't hit the live API in tests.
- Tool handler tests **mock the client**. Goal is verifying Pydantic shaping and scope validation, not Testray itself.
- Scope validation has its own test file. The hard caps are part of the contract; regressing them silently is a design violation worth catching at the test layer.

## Future work (deferred, not in v1)

- **Sync script** that iterates `releases.yml`, finds each RELEASED entry's promoted build via `list_builds(promoted=true, name_contains=<git_tag>)`, hydrates via `get_build`, and writes `build_id` back to a `testray:` sub-block in `releases.yml`. Requires MCP to exist; ~50 lines once it does. Must error loudly if more than one build matches — silent first-match would corrupt the registry.
- **Writes** (subtask updates, triage status changes, comment posting). Deferred until read patterns are stable.
- **Attachment content retrieval** (currently URLs only). Adds complexity (GCS auth) for uncertain benefit given Claude Code can fetch directly.
- **Cross-routine queries** in a single call. Not needed for the two v1 scenarios; would re-open scope bounding questions.
- **Testray-side migration** (see Migration implications).

## Open decisions

- **Rate-limit handling.** Whether to ship retry-with-backoff in v1 or rely on Testray's server-side limits. Leaning toward minimal retry-with-backoff at the `httpx` layer in `client.py` and nothing more.
- **`summarize_case_results` group_by shape.** Whether to support cross-product grouping (`group_by=["team", "component", "status"]`) or only single-dimension. Leaning single-dimension for v1; cross-product is composable by calling multiple times.
- **`compare_builds` as a tool vs. a documented call pattern.** Leaning real tool, because triage frequency justifies the wrapper and it cleanly becomes one SQL query in Phase 2.
