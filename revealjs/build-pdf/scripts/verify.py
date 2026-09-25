#!/usr/bin/env python3
"""Verify a DeckTape-exported PDF: magic bytes, page count, page size.

Pure Python (pypdf, pinned by the wrapper). Exits nonzero with a
``::error::`` message on the first problem and prints ``pages=<n>`` on
success so the wrapper can forward it as a step output.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from pypdf import PdfReader

# CSS px -> PDF points (DeckTape prints at 96 dpi; a point is 1/72 in).
PT_PER_PX = 72 / 96
# Chromium rounds page sizes; allow a little slack (in points).
SIZE_TOLERANCE_PT = 2.0


def fail(message: str) -> int:
    print(f"::error::{message}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdf", required=True)
    parser.add_argument("--expected-pages", type=int, default=0, help="0 = only require >= 1 page")
    parser.add_argument("--width", type=int, default=0, help="expected page width in CSS px (0 = skip)")
    parser.add_argument("--height", type=int, default=0, help="expected page height in CSS px (0 = skip)")
    args = parser.parse_args(argv)

    path = Path(args.pdf)
    if not path.is_file() or path.stat().st_size == 0:
        return fail(f"{path} was not produced or is empty")
    with path.open("rb") as fh:
        if fh.read(5) != b"%PDF-":
            return fail(f"{path} is not a PDF (bad magic bytes)")

    reader = PdfReader(str(path))
    pages = len(reader.pages)
    if pages < 1:
        return fail(f"{path} has no pages")
    if args.expected_pages and pages != args.expected_pages:
        return fail(f"{path} has {pages} page(s) but the deck has {args.expected_pages} slide(s)")

    if args.width and args.height:
        box = reader.pages[0].mediabox
        want_w, want_h = args.width * PT_PER_PX, args.height * PT_PER_PX
        got_w, got_h = float(box.width), float(box.height)
        if abs(got_w - want_w) > SIZE_TOLERANCE_PT or abs(got_h - want_h) > SIZE_TOLERANCE_PT:
            return fail(
                f"{path}: page size {got_w:.1f}x{got_h:.1f} pt does not match the deck size "
                f"{args.width}x{args.height} px ({want_w:.1f}x{want_h:.1f} pt)"
            )

    print(f"pages={pages}")
    print(f"bytes={path.stat().st_size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
