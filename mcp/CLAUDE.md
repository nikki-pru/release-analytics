# Testray MCP Server

Read-only Model Context Protocol server wrapping the Testray API. Lives in `release-analytics/mcp/` and runs locally per dev via stdio transport.

**Status: pre-implementation.** The design is scoped in `DESIGN.md`; some tool contracts are frozen, others are still being validated against real Testray responses. Read `DESIGN.md` before making non-trivial changes.

## What this MCP is and isn't

**Is:** a thin, read-only adapter exposing Testray's API as MCP tools so Claude Code can fetch case results and build metadata as structured calls.

**Isn't:** an analytics layer, a replacement for RAP, or a write surface. Those are deliberate v1 boundaries — see `DESIGN.md` "Scope".

The MCP is dumb about RAP taxonomy on purpose. Component canonicalization, team mapping, and release labels live in `releases.yml` and `module_component_map.csv`, not here. If a change makes the MCP smarter about RAP, push back — that smartness belongs in Claude Code's reasoning layer or in the RAP repo.

## Three-layer mental model

The MCP is the bridge between Claude Code and **Testray only**. Two other layers are accessed separately:

- **Testray** (this MCP) — operational identity: builds, case results, components, teams.
- **RAP** (shell/SQL from the clone) — intelligence: complexity, churn, LPD/LPP, composite risk.
- **Release registry** (`releases.yml` as a plain file) — release labels, quarters, git tags, dates.

Claude Code combines these at reasoning time. The MCP never queries RAP or reads `releases.yml`.

## Stack and layout

- Python with the official `mcp` SDK using `FastMCP` (decorator-based tool definitions)
- `httpx` for async HTTP
- `pydantic` for input/output schemas
- `pyyaml` for config
- `uv` for dependency management
- stdio transport

```
mcp/
├── README.md
├── DESIGN.md                  # read this before non-trivial changes
├── CLAUDE.md                  # this file
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

**`client.py` contains zero MCP imports.** Tool handlers in `tools/*.py` are thin adapters: they call client methods and shape responses into Pydantic models. Anything HTTP-specific stays in the client.

This separation is the entire point of the design. When the MCP migrates onto Testray-side and queries Postgres directly, **only `client.py` gets swapped**. Tools, models, validation, scope types — all unchanged.

Things that MUST NOT leak out of `client.py`:

- HTTP response shapes (`r_buildToCaseResult_c_buildId`, etc.)
- Testray's filter syntax (`?status=FAILED`)
- Pagination query construction
- Auth token handling
- Retry / timeout logic
- Stringy-null coercion (`gitHash: "null"` → `None`)
- Double-encoded JSON parsing (`attachments`)

If you find yourself reaching for any of those in a tool handler, stop and push it back into the client. That's the most common way this MCP could decay; guard against it.

## Bounded-scope discipline

Unbounded queries are a hard "no". The MCP enforces scope **structurally** via a discriminated union (`BuildScope | BuildsScope | DateRangeScope`) so it's impossible to ask for "all case results in routine X".

Hard caps to preserve:

- `BuildsScope.build_ids`: 1 to 20
- `DateRangeScope`: max 14 days
- `list_case_results.page_size`: ≤ 200
- `get_case_history.limit`: ≤ 100
- `list_builds`: requires `date_range` OR `limit ≤ 100`

If you're tempted to relax these for a specific use case, the answer is almost always "make multiple bounded calls" or "use `summarize_case_results`". Relaxing scope caps is a design change, not an implementation tweak — discuss before doing it.

## Pydantic model conventions

Three case-result shapes exist because Testray exposes two different API surfaces:

- `CaseResultSummary` — flat shape from `/o/testray-rest/v1.0/...`. Has human-readable names, no `build_id` per item.
- `CaseResultDetail` — raw shape from `/o/c/caseresults/{id}`. Has linked IDs and attachments.
- `CaseResultHistoryItem` — raw shape from `/o/c/cases/{case_id}/caseToCaseResult`. Has `build_id` per item.

Don't try to unify these into one model. The shapes carry different information for different reasons; collapsing them loses fidelity.

Aliasing rules:

- `r_*ToCase*_c_*Id` → clean snake_case (`build_id`, `case_id`, `component_id`, etc.)
- `error` (singular, flat) and `errors` (plural, raw) → both surfaced as `error`
- `testray*Name` prefix dropped (`testrayCaseName` → `case_name`)
- `gitHash: "null"` string → `None` via `field_validator(mode="before")`
- `attachments` JSON string → parsed `list[Attachment]` with `name`, `value`, `url`

Drop these noise fields entirely: `actions`, `creator`, `keywords`, `taxonomyCategoryBriefs`, `template*`, all `*ERC` fields, `playwrightReports`, the Liferay object lifecycle `status` (different from build/case-result status — confusing name collision).

## Pagination

Page-based, matching Testray's native shape (`page`, `pageSize`, `lastPage`, `totalCount`). Don't invent cursor semantics for v1. `totalCount` is genuinely useful for size estimation and it's free.

`Build.stats` (pre-aggregated case result counts on the build object) is the short-circuit for any "how many failures in build X" question. `summarize_case_results` should use it whenever the scope is build-level, instead of paginating through case results.

## Config

`config.yml` has a `testray:` block:

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

**Never** store credentials anywhere else, log them, or echo them back in error messages. If you see a code path that might leak the token (logged exception with full request, debug print of headers, etc.), fix it.

The `routines` block is the canonical place for Claude Code to look up routine IDs by name. New routines get added here, not hardcoded.

## Validation status (as of last DESIGN.md update)

| Tool | Schema status | Notes |
|---|---|---|
| `list_builds` | ✅ frozen | `git_hash` unreliable on this endpoint — use `get_build` for authoritative value |
| `get_build` | ✅ frozen | Authoritative `git_hash`; `promoted=true` filter works |
| `list_case_results` | 🟡 in progress | Filter syntax for non-status fields not yet confirmed |
| `get_case_result` | 🟡 in progress | Attachments parsing handled at client boundary |
| `get_case_history` | 🟡 in progress | Hard cap on `limit` is non-negotiable; one case had 2,875 results |
| `get_case` | 🔴 unvalidated | Endpoint presumed `/o/c/cases/{case_id}`; needs sample |
| `summarize_case_results` | 🟡 contract open | Build-stats short-circuit confirmed; `group_by` dimensions TBD |
| `compare_builds` | 🟡 contract open | Convenience wrapper over `list_case_results` × 2 |

**Don't implement yellow/red items without sampling the real endpoint first.** The case for the design is built on observed response shapes, not assumed ones. Past surprises:

- Testray exposes two different API surfaces with different field shapes for the same conceptual entity
- `attachments` is a JSON string inside a JSON field
- `gitHash` comes back as the literal string `"null"` rather than JSON null on the list endpoint
- `gitHash` is reliably populated on the detail endpoint but not the list endpoint

Assume more surprises exist for the unvalidated tools. Pull a sample, walk the six-step validation in `DESIGN.md`, then implement.

## Migration awareness

Phase 2 of this work moves the MCP onto Testray-side, querying Postgres directly. The tool contract stays identical; `client.py` gets swapped wholesale.

When making changes, ask: "would this still make sense in a SQL-backed implementation?"

- API-era artifact: stringy-null `gitHash` coercion → handled in client, drops in Phase 2 ✅
- API-era artifact: two-call `list_builds` then `get_build` for authoritative `git_hash` → drops in Phase 2 ✅
- Tool surface choice: `compare_builds` as a wrapper over two list calls → still makes sense in Phase 2, just becomes one SQL query ✅
- Hypothetical bad change: tool handler that does `if response['r_buildToCaseResult_c_buildId']:` → leaks API shape into Phase 2 ❌

The "would this make sense in SQL" check is the cheap version of "is this a migration hazard".

## Test surface

(Pending — tests directory exists but no v1 tests yet.) When tests get written:

- `client.py` tests use recorded HTTP responses (the JSON samples we validated against). Don't hit the live API in tests.
- Tool handler tests mock the client. Goal is verifying Pydantic shaping and scope validation, not Testray itself.
- Scope validation has its own test file. The hard caps are part of the contract; regressing them silently is a design violation.

## Common operations

```bash
# Run the server locally (stdio)
uv run testray-mcp

# Add a dependency
uv add httpx

# Run tests
uv run pytest

# Type check
uv run mypy src/
```

`uv sync` after a fresh clone gets you to a working environment.

## When in doubt

1. Read `DESIGN.md`. It's the authoritative scoping doc.
2. Check the validation status table above. Don't implement against assumed schemas.
3. Ask "would this still work in the Postgres-backed Phase 2 version?"
4. Push HTTP-specific concerns into `client.py`, not tool handlers.
5. Preserve scope-bounding caps; relaxing them is a design change.
