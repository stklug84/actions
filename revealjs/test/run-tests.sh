#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	docker, node + npm, python3 (PyYAML, pypdf), jq, diff
# @description:
#	Integration test for the revealjs/* composite actions: resolves the
#	pinned toolchain images from test/docker/Dockerfile
#	(resolve-images), discovers the fixture deck (discover-decks),
#	builds it into a self-contained HTML deck (build-html: pandoc pass
#	1 + mermaid-cli + pandoc pass 2) and exports it to PDF with
#	DeckTape (build-pdf), asserting slide/page counts, the absence of
#	remote resources, the embedded Mermaid fonts and the structural
#	golden of the slide markup (test/golden/showcase/sections.txt).
#	Runs the actions' scripts directly with the fixture deck/themes of
#	revealjs/build-html/test as the workspace; needs docker (pulls
#	three images on first use) and network access for that pull only.
# @arguments:
#	none
## Usage: revealjs/test/run-tests.sh
### Example: UPDATE_GOLDEN=1 revealjs/test/run-tests.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVEALJS_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKSPACE="$REVEALJS_DIR/build-html"
GOLDEN="$TEST_DIR/golden/showcase"
SCRATCH_REL="test/.integration"

FAILURES=0
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

cd "$WORKSPACE"
rm -rf "$SCRATCH_REL"
mkdir -p "$SCRATCH_REL"
trap 'rm -rf "$WORKSPACE/$SCRATCH_REL"' EXIT

echo "test: resolve-images"
images="$("$REVEALJS_DIR/resolve-images/scripts/resolve.sh" "$TEST_DIR/docker/Dockerfile" "pandoc mermaid decktape")"
PANDOC_IMAGE="$(sed -n 's/^pandoc-image=//p' <<< "$images")"
MERMAID_IMAGE="$(sed -n 's/^mermaid-image=//p' <<< "$images")"
DECKTAPE_IMAGE="$(sed -n 's/^decktape-image=//p' <<< "$images")"
[ -n "$PANDOC_IMAGE" ] && [ -n "$MERMAID_IMAGE" ] && [ -n "$DECKTAPE_IMAGE" ] || { fail "could not resolve all images"; exit 1; }

echo "test: resolve-images rejects an unpinned stage"
printf 'FROM pandoc/core:3.11.0.0-alpine AS pandoc\n' > "$SCRATCH_REL/unpinned.Dockerfile"
if "$REVEALJS_DIR/resolve-images/scripts/resolve.sh" "$SCRATCH_REL/unpinned.Dockerfile" "pandoc" >/dev/null 2>&1; then
  fail "unpinned FROM accepted"
fi

echo "test: discover-decks"
matrix="$("$REVEALJS_DIR/discover-decks/scripts/scan.sh" test/decks slides.md 2>/dev/null)"
[ "$(jq -r '.include | length' <<< "$matrix")" -eq 1 ] || fail "expected 1 deck, got: $matrix"
[ "$(jq -r '.include[0].name' <<< "$matrix")" = "showcase" ] || fail "unexpected deck name: $matrix"
[ "$(jq -r '.include[0].source' <<< "$matrix")" = "test/decks/showcase/slides.md" ] || fail "unexpected source: $matrix"

echo "test: build-html (docker)"
OUTPUTS="$SCRATCH_REL/html-outputs.txt"
if ! SOURCE=test/decks/showcase/slides.md NAME=showcase THEMES_DIR=test/themes \
    OUT_DIR="$SCRATCH_REL/dist" BUILD_ROOT="$SCRATCH_REL/build" \
    PANDOC_IMAGE="$PANDOC_IMAGE" MERMAID_IMAGE="$MERMAID_IMAGE" GITHUB_OUTPUT="$OUTPUTS" \
    bash "$REVEALJS_DIR/build-html/scripts/run.sh" > "$SCRATCH_REL/build-html.log" 2>&1; then
  tail -n 30 "$SCRATCH_REL/build-html.log"
  fail "build-html failed"
  exit 1
fi
HTML="$(sed -n 's/^html=//p' "$OUTPUTS")"
SLIDES="$(sed -n 's/^slides=//p' "$OUTPUTS")"
[ "$SLIDES" = "9" ] || fail "expected 9 slides, got $SLIDES"
[ "$(sed -n 's/^pdf-size=//p' "$OUTPUTS")" = "1280x720" ] || fail "unexpected pdf-size output"
[ "$(sed -n 's/^title=//p' "$OUTPUTS")" = "Fixture Deck" ] || fail "unexpected title output"
[ "$(find "$SCRATCH_REL/build/showcase/mermaid" -name "*.svg" | wc -l)" -eq 2 ] || fail "expected 2 rendered SVGs"
grep -L 'deck-fonts' "$SCRATCH_REL/build/showcase/mermaid/"*.svg | grep -q . && fail "an SVG lacks the embedded font"
grep -q 'data:image/svg+xml' "$HTML" || fail "diagrams not embedded as data URIs"
grep -q 'katex.min.css\|class="katex"' "$HTML" || fail "KaTeX not embedded"

# Structural golden: the slide skeleton (section tags) must be stable.
grep -oE '<section[^>]*>' "$HTML" > "$SCRATCH_REL/sections.txt"
if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
  mkdir -p "$GOLDEN" && cp "$SCRATCH_REL/sections.txt" "$GOLDEN/sections.txt" && echo "  updated golden sections.txt"
elif ! diff -u "$GOLDEN/sections.txt" "$SCRATCH_REL/sections.txt"; then
  fail "slide skeleton differs from golden"
fi

echo "test: build-pdf (docker)"
PDF_OUTPUTS="$SCRATCH_REL/pdf-outputs.txt"
if ! HTML="$HTML" DECKTAPE_IMAGE="$DECKTAPE_IMAGE" SIZE=1280x720 PAUSE=200 LOAD_PAUSE=1000 \
    PDF_TITLE="Fixture Deck" PDF_AUTHOR="Steffen Klug" EXPECTED_PAGES="$SLIDES" GITHUB_OUTPUT="$PDF_OUTPUTS" \
    bash "$REVEALJS_DIR/build-pdf/scripts/run.sh" > "$SCRATCH_REL/build-pdf.log" 2>&1; then
  tail -n 30 "$SCRATCH_REL/build-pdf.log"
  fail "build-pdf failed"
else
  [ "$(sed -n 's/^pages=//p' "$PDF_OUTPUTS")" = "9" ] || fail "expected 9 PDF pages"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All revealjs integration tests passed."
else
  echo "$FAILURES revealjs integration test(s) failed."
fi
[ "$FAILURES" -eq 0 ]
