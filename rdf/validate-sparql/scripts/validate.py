#!/usr/bin/env python3
"""Validate SPARQL query files by parsing them with rdflib.

Helper for the ``rdf/validate-sparql`` composite action. Every file
matching the given glob pattern(s) (Python :mod:`pathlib` style,
relative to the working directory; ``**`` matches any number of
directories) is read as UTF-8 and parsed with
:func:`rdflib.plugins.sparql.prepareQuery`. ``OK <file>`` /
``FAIL <file>`` is printed per file (plus the parser diagnostics on
failure); the exit status is nonzero when any file fails to parse or
no file matches.

Limitation: ``prepareQuery`` implements the SPARQL 1.1 *Query* grammar
only (SELECT / CONSTRUCT / ASK / DESCRIBE). SPARQL *Update* requests
(INSERT / DELETE / LOAD / ...) are not covered and are reported as
syntax errors -- keep update scripts out of the matched patterns.

Usage: scripts/validate.py <pattern> [<pattern> ...]
Example: scripts/validate.py '**/*.rq' 'queries/*.sparql'
"""

# Console reporting is this script's interface, so `print` is intended,
# not an oversight (T201); the repository carries no per-file copyright
# headers (CPY001).
# ruff: noqa: T201, CPY001

from __future__ import annotations

import sys
from pathlib import Path

from rdflib.plugins.sparql import prepareQuery


def matching_files(patterns: list[str]) -> list[Path]:
    """Collect the files matching any pattern, de-duplicated and sorted."""
    root = Path()
    matches: set[Path] = set()
    for pattern in patterns:
        matches.update(path for path in root.glob(pattern) if path.is_file())
    return sorted(matches)


def parse_error(path: Path) -> str | None:
    """Parse one query file; return the error message, or None on success."""
    try:
        prepareQuery(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 -- no stable rdflib parse-error type
        return f"{type(exc).__name__}: {exc}"
    return None


def main(argv: list[str]) -> int:
    """Validate every file matching the given glob patterns."""
    if not argv:
        print("::error::usage: validate.py <pattern> [<pattern> ...]", file=sys.stderr)
        return 2
    files = matching_files(argv)
    if not files:
        print(f"::error::No files matched patterns: {' '.join(argv)}", file=sys.stderr)
        return 1
    failures = 0
    for path in files:
        error = parse_error(path)
        if error is None:
            print(f"OK   {path}")
        else:
            print(f"FAIL {path}")
            print(error)
            failures += 1
    print()
    print(f"Validated {len(files)} file(s), {failures} failure(s).")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
