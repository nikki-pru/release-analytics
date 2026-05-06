"""
apps/pr-triage/normalize.py

Error signature normalization for uniqueness detection.

Two test failures are considered the "same error" if their normalized
forms are byte-identical. The normalization strips run-specific noise
(timestamps, hex addresses, thread IDs, line numbers in stack frames)
that would otherwise mark every occurrence as unique.

The hash is md5 — collision risk is negligible at the scale we operate
(tens of thousands of historical failures per project) and avoids the
pgcrypto extension if any caller wants to compute hashes server-side.

Tunable: the rule set is intentionally short for v0.1. Iterate by
adding cases as we see false-uniqueness hits during validation.
"""

import hashlib
import re


_RULES: list[tuple[re.Pattern, str]] = [
    # ISO-8601 timestamps (with or without milliseconds / Z suffix)
    (re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"), ""),
    # Hex addresses bare and after @
    (re.compile(r"@[0-9a-fA-F]{4,}"), ""),
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), ""),
    # Thread / process IDs
    (re.compile(r"Thread-\d+"), "Thread-"),
    (re.compile(r"\bpid=\d+\b"), "pid="),
    # Line numbers inside stack frames: `Foo.java:42)` → `Foo.java:)`
    (re.compile(r":\d+\)"), ":)"),
    # Whitespace collapse
    (re.compile(r"\s+"), " "),
]


def normalize_error(text: str | None) -> str:
    """Apply normalization rules in order. None / empty → empty string."""
    if not text:
        return ""
    out = text
    for pattern, replacement in _RULES:
        out = pattern.sub(replacement, out)
    return out.strip()


def error_signature_hash(text: str | None) -> str:
    """md5 of the normalized error. Empty errors hash to the empty-string
    signature — callers should treat empty-error rows specially if that
    matters."""
    normalized = normalize_error(text)
    return hashlib.md5(normalized.encode("utf-8")).hexdigest()
