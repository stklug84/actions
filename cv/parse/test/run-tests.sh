#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (with PyYAML and Jinja2 importable)
#	diff
# @description:
#	Golden test entrypoint for the cv/parse composite action.
#	Regenerates every output variant from the representative fixture
#	(test/cv.yml) into a scratch directory and diffs each file
#	against the committed goldens under test/golden/. Covers the
#	five required variants: latex/plain/{de,en}, latex/sidebar/{de,
#	en}, and web. Also asserts that --check passes on the valid
#	fixture and fails (nonzero, with a message) on test/cv-broken.
#	yml. PYTHONPATH is exported so parse.py is importable; the
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
FIXTURE="$TEST_DIR/cv.yml"
BROKEN="$TEST_DIR/cv-broken.yml"
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
# Example-CV styles. pw/dh/vs reuse the sidebar templates (see
# STYLE_TEMPLATE_DIRS in parse.py); fs/tagged render from their own template
# directories. The goldens lock both the alias behavior and the dedicated
# templates so a future divergence is caught. `tagged` additionally exercises
# skills[].size (\cvskillbar), the optional concepts[] section
# (\cvskillbubbles) and experience[].tags (\cvtechstack).
run_golden pw-de      --mode latex --style pw      --lang de
run_golden dh-de      --mode latex --style dh      --lang de
run_golden vs-en      --mode latex --style vs      --lang en
run_golden fs-en      --mode latex --style fs      --lang en
run_golden tagged-de  --mode latex --style tagged  --lang de
run_golden web         --mode web

# Minimal-contact variant: all optional contact fields (birthdate,
# birthplace, address, location_signature, photo_path, signature_path)
# omitted. Locks the empty-macro emission so the optionality cannot
# regress. Uses the dedicated cv-minimal-contact.yml fixture.
echo "test: golden minimal-de"
if ! "$PYTHON" "$PARSE_PY" --source "$TEST_DIR/cv-minimal-contact.yml" \
    --out-dir "$SCRATCH/minimal-de" --mode latex --style plain --lang de \
    >/dev/null; then
  echo "  FAIL: parse.py errored for minimal-de"
  FAILURES=$((FAILURES + 1))
elif ! diff -ru "$GOLDEN_DIR/minimal-de" "$SCRATCH/minimal-de"; then
  echo "  FAIL: output differs from golden for minimal-de"
  FAILURES=$((FAILURES + 1))
fi

# --check on the valid fixture must pass.
echo "test: --check valid fixture"
if ! "$PYTHON" "$PARSE_PY" --source "$FIXTURE" --check >/dev/null; then
  echo "  FAIL: --check rejected the valid fixture"
  FAILURES=$((FAILURES + 1))
fi

# --check on the minimal-contact fixture (optional contact fields omitted)
# must also pass.
echo "test: --check minimal-contact fixture"
if ! "$PYTHON" "$PARSE_PY" --source "$TEST_DIR/cv-minimal-contact.yml" \
    --check >/dev/null; then
  echo "  FAIL: --check rejected the minimal-contact fixture"
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
