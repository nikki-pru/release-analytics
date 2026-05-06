"""
apps/pr-triage/hunk_match.py

Match diff files to a failing test by token substring.

Test names from Testray are colon-separated module paths, e.g.
`:dxp:apps:analytics:analytics-reports-js-components-web:packageRunTest`.
The middle tokens map directly into liferay-portal file paths, so a
substring match against the diff path works well as a first cut.

A failing test "claims" any diff file whose b/-side path contains at
least one of the test's tokens. Component name and team name are also
folded in as auxiliary tokens for tests whose names are too short to
match (e.g. CI/E2E suites).

This is intentionally simpler than apps/triage/extract_relevant_hunks.py
— that tool runs against build-triage's existing CSV bundle. PR-triage
v0.2 just needs an inline matcher with no extra dependencies.
"""

import re
from pr_diff import FileDiff


# Tokens to drop from test-name splits. These are gradle/maven verbs and
# generic Liferay path segments that match thousands of files.
_STOP_TOKENS = {
    "", "dxp", "apps", "modules", "ee", "private", "src", "main",
    "test", "tests", "java", "resources", "meta-inf",
    "packagerunTest".lower(), "packagerunjstest", "compile",
    "build", "deploy", "run", "task", "target", "clean",
}

_MIN_TOKEN_LEN = 4


def extract_test_tokens(
    case_name: str | None,
    component: str | None = None,
    team: str | None = None,
) -> list[str]:
    """Return distinct lowercase tokens to match against diff paths.

    Splits the test name on `:`, `/`, `.`, then folds in the component
    and team names. Drops short and generic tokens."""
    raw: list[str] = []
    if case_name:
        raw.extend(re.split(r"[:/.\s]+", case_name))
    if component:
        raw.extend(re.split(r"[:/.\s]+", component))
    if team:
        raw.extend(re.split(r"[:/.\s]+", team))

    seen: set[str] = set()
    out: list[str] = []
    for t in raw:
        t = t.strip().lower()
        if (
            len(t) >= _MIN_TOKEN_LEN
            and t not in _STOP_TOKENS
            and t not in seen
        ):
            seen.add(t)
            out.append(t)
    return out


def match_files(file_diffs: list[FileDiff], tokens: list[str]) -> list[FileDiff]:
    """Return file_diffs whose path contains at least one of the tokens.
    Order preserved from the input. Empty token list returns []."""
    if not tokens:
        return []
    out: list[FileDiff] = []
    for fd in file_diffs:
        path_lower = fd.path.lower()
        if any(tok in path_lower for tok in tokens):
            out.append(fd)
    return out


def format_inline(matched: list[FileDiff], max_lines_per_file: int = 60) -> str:
    """Render matched file diffs for inline display under a report row.

    Keeps each file's hunk text bounded to `max_lines_per_file` so the
    stdout report stays readable. Files with more than that get a
    truncation marker; full content lives in the v0.3 bundle's
    `diff_full.diff`."""
    if not matched:
        return "  matched_files: 0  matched_hunks: 0\n"

    total_hunks = sum(_count_hunks(fd.hunks_text) for fd in matched)
    lines: list[str] = [
        f"  matched_files: {len(matched)}  matched_hunks: {total_hunks}\n",
    ]
    for fd in matched:
        n_hunks = _count_hunks(fd.hunks_text)
        lines.append(
            f"  ── {fd.path} ({n_hunks} hunk{'s' if n_hunks != 1 else ''}, "
            f"{fd.changed_lines} changed lines) "
            + "─" * max(0, 40 - len(fd.path))
            + "\n"
        )
        body_lines = fd.hunks_text.splitlines()
        if len(body_lines) > max_lines_per_file:
            body_lines = body_lines[:max_lines_per_file] + [
                f"  … ({len(body_lines) - max_lines_per_file} more lines truncated; "
                "see diff_full.diff in the bundle)"
            ]
        for ln in body_lines:
            lines.append("    " + ln + "\n")
        lines.append("\n")
    return "".join(lines)


def _count_hunks(text: str) -> int:
    return sum(1 for line in text.splitlines() if line.startswith("@@"))
