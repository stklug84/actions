#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (with PyYAML and Jinja2 importable)
#	diff
# @description:
#	Golden test entrypoint for the cv/parse composite action.
#	Regenerates every output variant into a scratch directory and
#	diffs each file against the committed goldens under test/golden/.
#	Two profile fixtures drive the goldens: the tagged-shaped
#	test/cv.yml backs the tagged + web variants, and the plain-shaped
#	test/cv-plain.yml backs every non-tagged latex variant
#	(plain/sidebar/pw/dh/vs/fs), so each golden comes from a source
#	that matches the style's schema profile. Also asserts the
#	style-dependent --check: each fixture validates under its own
#	profile and is rejected under the other, --check passes on the
#	minimal-contact fixture, and fails (nonzero, with a message) on
#	test/cv-broken.yml. PYTHONPATH is exported so parse.py is
#	importable; the script invokes parse.py directly via its CLI.
#	Run from anywhere.
# @arguments:
#	none
## Usage: cv/parse/test/run-tests.sh
### Example: PYTHON=python3 cv/parse/test/run-tests.sh

set -euo pipefail

PYTHON="${PYTHON:-python3}"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_DIR="$(cd "$TEST_DIR/.." && pwd)"
PARSE_PY="$PARSE_DIR/scripts/parse.py"
# Two profile fixtures: the tagged-shaped cv.yml drives the tagged + web
# goldens; the plain-shaped cv-plain.yml drives every non-tagged golden
# (plain/sidebar/pw/dh/vs/fs) so each golden is generated from a source that
# actually matches the style's schema profile.
FIXTURE="$TEST_DIR/cv.yml"
FIXTURE_PLAIN="$TEST_DIR/cv-plain.yml"
BROKEN="$TEST_DIR/cv-broken.yml"
GOLDEN_DIR="$TEST_DIR/golden"

export PYTHONPATH="$PARSE_DIR/scripts${PYTHONPATH:+:$PYTHONPATH}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

FAILURES=0

run_golden() {
  # run_golden <variant-name> <source-yaml> <parse.py args...>
  local variant="$1"
  local source="$2"
  shift 2
  echo "test: golden $variant"
  if ! "$PYTHON" "$PARSE_PY" --source "$source" \
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

# Non-tagged variants are generated from the plain-shaped fixture (string
# skill items, bilingual cert text, meta.pdf_title, no tagged-only fields).
run_golden plain-de   "$FIXTURE_PLAIN" --mode latex --style plain   --lang de
run_golden plain-en   "$FIXTURE_PLAIN" --mode latex --style plain   --lang en
run_golden sidebar-de "$FIXTURE_PLAIN" --mode latex --style sidebar --lang de
run_golden sidebar-en "$FIXTURE_PLAIN" --mode latex --style sidebar --lang en
# Example-CV styles. pw/dh/vs reuse the sidebar templates (see
# STYLE_TEMPLATE_DIRS in parse.py); fs/tagged render from their own template
# directories. The goldens lock both the alias behavior and the dedicated
# templates so a future divergence is caught. `tagged` additionally exercises
# skills[].size (\cvskillbar), the optional concepts[] section
# (\cvskillbubbles) and experience[].tags (\cvtechstack), so it is generated
# from the tagged-shaped fixture.
run_golden pw-de      "$FIXTURE_PLAIN" --mode latex --style pw      --lang de
run_golden dh-de      "$FIXTURE_PLAIN" --mode latex --style dh      --lang de
run_golden vs-en      "$FIXTURE_PLAIN" --mode latex --style vs      --lang en
run_golden fs-en      "$FIXTURE_PLAIN" --mode latex --style fs      --lang en
run_golden tagged-de  "$FIXTURE"       --mode latex --style tagged  --lang de
run_golden web        "$FIXTURE"       --mode web

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

# --check on the valid fixture must pass. cv.yml is tagged-shaped, so it is
# checked under the tagged profile (the dedicated cross-style assertions
# below exercise both profiles against both fixtures).
echo "test: --check valid fixture"
if ! "$PYTHON" "$PARSE_PY" --source "$FIXTURE" --style tagged --check >/dev/null; then
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

# Style-dependent schema profiles. --check selects the profile from --style
# (default plain). Each fixture must validate under its own profile and be
# rejected under the other, proving the profiles are genuinely strict:
#   * cv-plain.yml  (string skills, cert text)        -> plain  PASS / tagged FAIL
#   * cv.yml        ({name,size} skills, structured)  -> tagged PASS / plain  FAIL
# meta.pdf_title is accepted under BOTH (validated in the shared core); the
# plain fixture carries it and still passes plain --check above.

check_pass() {
  # check_pass <label> <source> <style>
  echo "test: --check $1"
  if ! "$PYTHON" "$PARSE_PY" --source "$2" --style "$3" --check >/dev/null 2>&1; then
    echo "  FAIL: --style $3 --check rejected $1 (expected PASS)"
    FAILURES=$((FAILURES + 1))
  fi
}

check_fail() {
  # check_fail <label> <source> <style>
  echo "test: --check $1"
  if CHECK_OUT="$("$PYTHON" "$PARSE_PY" --source "$2" --style "$3" --check 2>&1)"; then
    echo "  FAIL: --style $3 --check accepted $1 (expected FAIL)"
    FAILURES=$((FAILURES + 1))
  else
    echo "  ok: rejected with -> $CHECK_OUT"
  fi
}

check_pass "plain profile on plain fixture"   "$FIXTURE_PLAIN" plain
check_fail "tagged profile on plain fixture"  "$FIXTURE_PLAIN" tagged
check_pass "tagged profile on tagged fixture" "$FIXTURE"       tagged
check_fail "plain profile on tagged fixture"  "$FIXTURE"       plain

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All cv/parse tests passed."
else
  echo "$FAILURES cv/parse test(s) failed."
fi
[ "$FAILURES" -eq 0 ]
