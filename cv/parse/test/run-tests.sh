#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (with PyYAML and Jinja2 importable)
#	diff
# @description:
#	Golden test entrypoint for the cv/parse composite action.
#	Regenerates every output variant from the representative fixture
#	(test/cv.yaml) into a scratch directory and diffs each file
#	against the committed goldens under test/golden/. Covers the
#	five required variants: latex/plain/{de,en}, latex/sidebar/{de,
#	en}, and web. Also asserts that --check passes on the valid
#	fixture and fails (nonzero, with a message) on test/cv-broken.
#	yaml. PYTHONPATH is exported so parse.py is importable; the
#	script invokes parse.py directly via its CLI. Run from anywhere.
# @arguments:
#	none
## Usage: cv/parse/test/run-tests.sh
### Example: PYTHON=python3 cv/parse/test/run-tests.sh

set -euo pipefail

PYTHON="${PYTHON:-python3}"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSE_PY="$PARSE_DIR/scripts/parse.py"
FIXTURE="$TEST_DIR/cv.yaml"
BROKEN="$TEST_DIR/cv-broken.yaml"
GOLDEN_DIR="$TEST_DIR/golden"

export PYTHONPATH="$PARSE_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

FAILURES=0

run_golden() {
  # run_golden <variant-name> <parse.py args...>
  local variant="$1"
  shift
  echo "test: golden $variant"
  if ! "$PYTHON" "$PARSE_PY" --source "$FIXTURE" \
      --out-dir "$SCRATCH/$variant" "$@" >/dev/null; then
    echo "  FAIL: parse.py errored for $variant"
    FAILURES=$((FAILURES + 1))
    return
  fi
  if ! diff -ru "$GOLDEN_DIR/$variant" "$SCRATCH/$variant"; then
    echo "  FAIL: output differs from golden for $variant"
    FAILURES=$((FAILURES + 1))
  fi
}

run_golden plain-de   --mode latex --style plain   --lang de
run_golden plain-en   --mode latex --style plain   --lang en
run_golden sidebar-de --mode latex --style sidebar --lang de
run_golden sidebar-en --mode latex --style sidebar --lang en
run_golden web         --mode web

# --check on the valid fixture must pass.
echo "test: --check valid fixture"
if ! "$PYTHON" "$PARSE_PY" --source "$FIXTURE" --check >/dev/null; then
  echo "  FAIL: --check rejected the valid fixture"
  FAILURES=$((FAILURES + 1))
fi

# --check on the broken fixture must fail with a message.
echo "test: --check broken fixture"
if CHECK_OUT="$("$PYTHON" "$PARSE_PY" --source "$BROKEN" --check 2>&1)"; then
  echo "  FAIL: --check accepted the broken fixture"
  FAILURES=$((FAILURES + 1))
else
  echo "  ok: rejected with -> $CHECK_OUT"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All cv/parse tests passed."
else
  echo "$FAILURES cv/parse test(s) failed."
fi
[ "$FAILURES" -eq 0 ]
