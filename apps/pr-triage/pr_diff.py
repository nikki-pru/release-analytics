"""
apps/pr-triage/pr_diff.py

Fetch and parse the PR diff from a local liferay-portal checkout.

We use `git diff $(merge-base <base> <branch>) <branch>` rather than
`<base>...<branch>` to get a true PR-style diff (changes the branch
introduced relative to the merge base, ignoring later commits to base).
"""

import subprocess
from pathlib import Path
from typing import NamedTuple


class FileDiff(NamedTuple):
    path:          str   # b/-side path (the new file's location)
    hunks_text:    str   # raw hunks block including the diff/index/--- /+++ header
    changed_lines: int   # count of + / - lines (excluding hunk headers)


def fetch_diff(portal_repo: Path, base_branch: str, target_branch: str) -> str:
    """Return the unified diff between merge-base(base, target) and target.

    Raises CalledProcessError if any git command fails — caller should
    let it bubble; the bash wrapper has already validated the refs exist."""
    merge_base = subprocess.check_output(
        ["git", "-C", str(portal_repo), "merge-base", base_branch, target_branch],
        text=True,
    ).strip()
    diff = subprocess.check_output(
        ["git", "-C", str(portal_repo), "diff", merge_base, target_branch],
        text=True,
    )
    return diff


def parse_diff(diff_text: str) -> list[FileDiff]:
    """Split a unified diff into per-file blocks. Each block is the full
    `diff --git` section, including any binary-file markers.

    `path` is the b/-side path. New-file deletions yield `path=/dev/null`;
    we filter those out (they have no surface for a failure to fail
    against). Renames keep the new path."""
    blocks: list[FileDiff] = []
    current: list[str] = []

    def _flush():
        if not current:
            return
        text = "".join(current)
        path = _b_path(text)
        if not path or path == "/dev/null":
            return
        changed = sum(
            1 for line in text.splitlines()
            if (line.startswith("+") and not line.startswith("+++"))
            or (line.startswith("-") and not line.startswith("---"))
        )
        blocks.append(FileDiff(path=path, hunks_text=text, changed_lines=changed))

    for line in diff_text.splitlines(keepends=True):
        if line.startswith("diff --git "):
            _flush()
            current = [line]
        else:
            current.append(line)
    _flush()
    return blocks


def _b_path(file_block: str) -> str:
    """Pull the b/-side path from a single-file diff block. Falls back to
    the `diff --git a/X b/Y` header if there's no `+++` line (binary or
    pure rename)."""
    for line in file_block.splitlines():
        if line.startswith("+++ "):
            rest = line[4:].strip()
            if rest.startswith("b/"):
                return rest[2:]
            return rest
    # No +++ — likely binary or rename-only. Pull from the header.
    first = file_block.splitlines()[0] if file_block else ""
    if first.startswith("diff --git "):
        parts = first.split()
        if len(parts) >= 4 and parts[3].startswith("b/"):
            return parts[3][2:]
    return ""
