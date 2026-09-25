#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (with PyYAML importable)
#	diff
# @description:
#	Golden and contract tests for the revealjs/build-html planner
#	(scripts/prepare.py). Runs WITHOUT docker or npm: it exercises the
#	pure-Python side of the action — front-matter/theme validation
#	(`check`, `check-themes`), the pass-1 plan (`plan`: metadata.yml,
#	pass1.yml, mermaid.json, plan.json, plan.env), the pass-2 defaults
#	(`finalize` against a canned structure.json), the SVG font embedding
#	(`embed-fonts`) and the HTML verifier (`verify-html`). Generated
#	files are diffed against test/golden/showcase/. Every broken fixture
#	under test/decks/broken/ must be rejected with a message. Runs with
#	the action directory as the working directory so every path in the
#	goldens is workspace-relative and deterministic. Set UPDATE_GOLDEN=1
#	to regenerate the goldens. The docker integration test lives in
#	revealjs/test/run-tests.sh.
# @arguments:
#	none
## Usage: revealjs/build-html/test/run-tests.sh
### Example: UPDATE_GOLDEN=1 revealjs/build-html/test/run-tests.sh

set -euo pipefail

PYTHON="${PYTHON:-python3}"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "$TEST_DIR/.." && pwd)"
PREPARE="$ACTION_DIR/scripts/prepare.py"
GOLDEN="$TEST_DIR/golden/showcase"
# Scratch lives INSIDE the action directory (= the test workspace) so that
# every path prepare.py writes stays workspace-relative; the fixed name
# keeps the goldens deterministic. Gitignored.
SCRATCH_REL="test/.scratch"
SCRATCH="$ACTION_DIR/$SCRATCH_REL"
FIXED_MERMAID_IMAGE="example.invalid/mermaid-cli:test@sha256:0000000000000000000000000000000000000000000000000000000000000000"

cd "$ACTION_DIR"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

FAILURES=0
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

compare_golden() {
  # compare_golden <name> <generated-file>
  local name="$1" generated="$2"
  if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
    mkdir -p "$GOLDEN"
    cp "$generated" "$GOLDEN/$name"
    echo "  updated golden $name"
    return
  fi
  if [ ! -f "$GOLDEN/$name" ]; then
    fail "missing golden $name (run with UPDATE_GOLDEN=1)"
    return
  fi
  if ! diff -u "$GOLDEN/$name" "$generated"; then
    fail "$name differs from golden"
  fi
}

# --- check / check-themes -----------------------------------------------
echo "test: check valid fixture"
"$PYTHON" "$PREPARE" check --source test/decks/showcase/slides.md --themes-dir test/themes >/dev/null \
  || fail "check rejected the valid fixture"

echo "test: check-themes"
"$PYTHON" "$PREPARE" check-themes --themes-dir test/themes >/dev/null \
  || fail "check-themes rejected the fixture theme"

for broken in test/decks/broken/*.md; do
  echo "test: check rejects $(basename "$broken")"
  if out="$("$PYTHON" "$PREPARE" check --source "$broken" --themes-dir test/themes 2>&1)"; then
    fail "check accepted $broken"
  else
    case "$out" in
      *"::error::"*) echo "  ok: $out" ;;
      *) fail "rejection without ::error:: message: $out" ;;
    esac
  fi
done

# --- plan ---------------------------------------------------------------
echo "test: plan"
BUILD="$SCRATCH_REL/build/showcase"
if ! "$PYTHON" "$PREPARE" plan --source test/decks/showcase/slides.md --themes-dir test/themes \
    --name showcase --build-dir "$BUILD" --out-dir "$SCRATCH_REL/dist" \
    --mermaid-image "$FIXED_MERMAID_IMAGE" >/dev/null; then
  fail "plan errored"
else
  for f in metadata.yml pass1.yml mermaid.json plan.json plan.env; do
    compare_golden "$f" "$BUILD/$f"
  done
  [ -f "$BUILD/fonts/Test-Regular.woff2" ] || fail "plan did not stage the theme font"
fi

# --- finalize (canned structure summary, as written by structure.lua) ----
echo "test: finalize"
printf '{"slide_level":2,"headings":{"1":2,"2":5}}\n' > "$BUILD/structure.json"
if ! "$PYTHON" "$PREPARE" finalize --build-dir "$BUILD" >/dev/null; then
  fail "finalize errored"
else
  compare_golden pass2.yml "$BUILD/pass2.yml"
fi

echo "test: finalize rejects a slide-level mismatch"
printf '{"slide_level":1,"headings":{"1":2}}\n' > "$BUILD/structure.json"
cp "$BUILD/plan.json" "$BUILD/plan.json.bak"
"$PYTHON" - "$BUILD/plan.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["slide_level"] = 2
json.dump(d, open(p, "w"))
EOF
if "$PYTHON" "$PREPARE" finalize --build-dir "$BUILD" >/dev/null 2>&1; then
  fail "finalize accepted a slide-level mismatch"
fi
mv "$BUILD/plan.json.bak" "$BUILD/plan.json"

# --- embed-fonts --------------------------------------------------------
echo "test: embed-fonts"
cat > "$BUILD/mermaid/deadbeef.svg" <<'EOF'
<svg id="m-deadbeef" width="100%" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><text style="font-family:Test Sans, Helvetica, Arial, sans-serif">x</text></svg>
EOF
if ! "$PYTHON" "$PREPARE" embed-fonts --build-dir "$BUILD" >/dev/null; then
  fail "embed-fonts errored"
else
  svg="$BUILD/mermaid/deadbeef.svg"
  grep -q '<!-- deck-fonts --><style>@font-face{font-family:"Test Sans";font-weight:400;font-style:normal;src:url(data:font/woff2;base64,' "$svg" \
    || fail "embed-fonts did not inject the @font-face rule"
  "$PYTHON" "$PREPARE" embed-fonts --build-dir "$BUILD" >/dev/null || fail "embed-fonts is not idempotent (errored)"
  [ "$(grep -o 'deck-fonts' "$svg" | wc -l)" -eq 1 ] || fail "embed-fonts embedded twice"
fi

# --- verify-html --------------------------------------------------------
echo "test: verify-html counts leaf slides"
cat > "$SCRATCH/ok.html" <<'EOF'
<html><body><div class="reveal"><div class="slides">
<section id="title-slide"><h1>T</h1></section>
<section><section id="a" class="title-slide slide level1"><h1>A</h1></section><section id="b" class="slide level2"><p>b</p></section></section>
<section id="c" class="slide level2"><a href="https://example.com">link</a><img src="data:image/svg+xml;base64,AAAA"></section>
</div></div></body></html>
EOF
if out="$("$PYTHON" "$PREPARE" verify-html --html "$SCRATCH/ok.html" --build-dir "$BUILD")"; then
  echo "$out" | grep -qx 'slides=4' || fail "expected slides=4, got: $out"
else
  fail "verify-html rejected a valid document"
fi

echo "test: verify-html rejects remote resources"
cat > "$SCRATCH/remote.html" <<'EOF'
<html><head><link rel="stylesheet" href="https://cdn.example.com/x.css"></head><body><div class="reveal"><div class="slides"><section>x</section></div></div></body></html>
EOF
if "$PYTHON" "$PREPARE" verify-html --html "$SCRATCH/remote.html" --build-dir "$BUILD" >/dev/null 2>&1; then
  fail "verify-html accepted a remote stylesheet"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All revealjs/build-html tests passed."
else
  echo "$FAILURES revealjs/build-html test(s) failed."
fi
[ "$FAILURES" -eq 0 ]
