#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	bash, jq, mktemp
# @description:
#	Behavioural tests for release/publish-dated against a MOCKED `gh`
#	(a bash script placed first on PATH). The mock is scripted per test
#	via environment variables: MOCK_RELEASES (JSON for `gh release
#	list`), MOCK_TAGS (newline list of refs for the git-refs API),
#	MOCK_FAIL_RELEASE_LIST / MOCK_FAIL_TAG_LIST ('1' makes that
#	listing exit nonzero) and records every mutating call in
#	MOCK_LOG. Asserts, among others, that a failed inventory produces
#	ZERO deletion calls, that pruning keeps exactly N releases, that
#	orphan tags are swept, that a re-run reuses the -r<N> release, that
#	an invalid `keep` and a missing asset are rejected, and that
#	dry-run mode never calls a mutating gh subcommand. No network, no
#	token, no real repository is touched.
# @arguments:
#	none
## Usage: release/publish-dated/test/run-tests.sh
### Example: release/publish-dated/test/run-tests.sh

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "$TEST_DIR/.." && pwd)"
PUBLISH="$ACTION_DIR/scripts/publish.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

FAILURES=0
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# --- gh mock ----------------------------------------------------------------
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock of the GitHub CLI for release/publish-dated tests.
set -euo pipefail
log() { printf '%s\n' "$*" >> "$MOCK_LOG"; }
case "$1 $2" in
  "release list")
    if [ "${MOCK_FAIL_RELEASE_LIST:-0}" = "1" ]; then echo "mock: release list failed" >&2; exit 1; fi
    printf '%s\n' "${MOCK_RELEASES:-[]}" ;;
  "release create") log "$*"; ;;
  "release upload") log "$*"; ;;
  "release edit")   log "$*"; ;;
  "release delete") log "$*"; ;;
  "api --paginate")
    if [ "${MOCK_FAIL_TAG_LIST:-0}" = "1" ]; then echo "mock: tag list failed" >&2; exit 1; fi
    printf '%s\n' "${MOCK_TAGS:-}" ;;
  "api -X") log "$*"; ;;
  *) echo "mock gh: unexpected call: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$SCRATCH/bin/gh"
export PATH="$SCRATCH/bin:$PATH"

# Common environment for the action script.
export GH_REPO="stklug84/example"
export GH_TOKEN="mock-token"
export GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
export GITHUB_RUN_NUMBER="42"
export GITHUB_EVENT_PATH="$SCRATCH/event.json"
printf '%s\n' '{"head_commit":{"message":"feat: something\n\nbody"}}' > "$GITHUB_EVENT_PATH"
mkdir -p "$SCRATCH/dist"
printf 'pdf' > "$SCRATCH/dist/a.pdf"
printf 'pdf' > "$SCRATCH/dist/b.pdf"
cd "$SCRATCH"

run_publish() {
  # run_publish <log-name> <env...> -- runs publish.sh with the given env, captures output
  local name="$1"; shift
  export MOCK_LOG="$SCRATCH/$name.log"
  : > "$MOCK_LOG"
  env "$@" bash "$PUBLISH" > "$SCRATCH/$name.out" 2>&1
}
count_calls() { grep -c "^$2" "$SCRATCH/$1.log" || true; }

TODAY="$(date +%Y.%m.%d)"
RELEASES='[
  {"tagName":"v2026.01.05-r5","createdAt":"2026-01-05T10:00:00Z"},
  {"tagName":"v2026.01.04-r4","createdAt":"2026-01-04T10:00:00Z"},
  {"tagName":"v2026.01.03-r3","createdAt":"2026-01-03T10:00:00Z"},
  {"tagName":"v2026.01.02-r2","createdAt":"2026-01-02T10:00:00Z"},
  {"tagName":"v1.2.3","createdAt":"2025-12-01T10:00:00Z"}
]'
TAGS=$'refs/tags/v2026.01.05-r5\nrefs/tags/v2026.01.04-r4\nrefs/tags/v2026.01.03-r3\nrefs/tags/v2026.01.02-r2\nrefs/tags/v2026.01.01-r1\nrefs/tags/v1.2.3\nrefs/tags/manual-tag'

# --- 1. create + prune keeps N -------------------------------------------------
echo "test: create release, prune to keep=2, sweep orphan"
if run_publish t1 FILES='dist/*.pdf' TITLE_PREFIX=Slides LIST_HEADING='Decks:' KEEP=2 \
    MOCK_RELEASES="$RELEASES" MOCK_TAGS="$TAGS"; then
  grep -q "^release create v${TODAY}-r42 dist/a.pdf dist/b.pdf --target $GITHUB_SHA --title Slides " t1.log \
    || fail "unexpected create call: $(grep '^release create' t1.log || echo none)"
  [ "$(count_calls t1 'release delete')" -eq 2 ] || fail "expected 2 release deletions, got $(count_calls t1 'release delete')"
  grep -q '^release delete v2026.01.03-r3 --cleanup-tag --yes' t1.log || fail "r3 not pruned"
  grep -q '^release delete v2026.01.02-r2 --cleanup-tag --yes' t1.log || fail "r2 not pruned"
  grep -q 'v2026.01.05-r5' t1.log && fail "newest release must be kept"
  grep -q 'v1.2.3' t1.log && fail "non-matching release must never be touched"
  grep -q '^api -X DELETE repos/stklug84/example/git/refs/tags/v2026.01.01-r1' t1.log || fail "orphan tag r1 not swept"
  grep -q 'manual-tag' t1.log && fail "non-matching tag must never be touched"
  grep -q 'Commit: feat: something' t1.out || fail "commit subject missing from output"
else
  fail "publish.sh exited nonzero: $(tail -n 3 t1.out)"
fi

# --- 2. failed release listing => zero deletions, nonzero exit ---------------
echo "test: failed release inventory deletes nothing"
if run_publish t2 FILES='dist/a.pdf' KEEP=1 MOCK_RELEASES="$RELEASES" MOCK_TAGS="$TAGS" MOCK_FAIL_RELEASE_LIST=1; then
  fail "expected nonzero exit when the release listing fails"
fi
[ "$(count_calls t2 'release delete')" -eq 0 ] || fail "release deletions despite failed inventory"
[ "$(count_calls t2 'api -X DELETE')" -eq 0 ] || fail "tag deletions despite failed inventory"

# --- 3. failed tag listing => zero deletions (release already created) ---------
echo "test: failed tag inventory deletes nothing"
if run_publish t3 FILES='dist/a.pdf' KEEP=1 MOCK_RELEASES="$RELEASES" MOCK_TAGS="$TAGS" MOCK_FAIL_TAG_LIST=1; then
  fail "expected nonzero exit when the tag listing fails"
fi
grep -q '^release create' t3.log || fail "release should have been created before the prune"
[ "$(count_calls t3 'release delete')" -eq 0 ] || fail "release deletions despite failed tag inventory"
[ "$(count_calls t3 'api -X DELETE')" -eq 0 ] || fail "tag deletions despite failed tag inventory"

# --- 4. keep=0 disables pruning ------------------------------------------------
echo "test: keep=0 never prunes"
run_publish t4 FILES='dist/a.pdf' KEEP=0 MOCK_RELEASES="$RELEASES" MOCK_TAGS="$TAGS" || fail "keep=0 run failed"
[ "$(count_calls t4 'release delete')" -eq 0 ] || fail "deletions with keep=0"
[ "$(count_calls t4 'api -X DELETE')" -eq 0 ] || fail "tag deletions with keep=0"

# --- 5. re-run reuses the -r<N> release --------------------------------------
echo "test: re-run reuses existing release of the same run number"
RERUN='[{"tagName":"v2026.01.09-r42","createdAt":"2026-01-09T10:00:00Z"}]'
if run_publish t5 FILES='dist/*.pdf' KEEP=0 MOCK_RELEASES="$RERUN" MOCK_TAGS=$'refs/tags/v2026.01.09-r42'; then
  grep -q '^release upload v2026.01.09-r42 dist/a.pdf dist/b.pdf --clobber' t5.log || fail "assets not re-uploaded with --clobber"
  grep -q '^release edit v2026.01.09-r42 --title' t5.log || fail "release not re-titled"
  grep -q '^release create' t5.log && fail "re-run must not create a second release"
else
  fail "re-run exited nonzero: $(tail -n 3 t5.out)"
fi

# --- 6. invalid keep / missing asset -----------------------------------------
echo "test: invalid keep is rejected"
run_publish t6 FILES='dist/a.pdf' KEEP=ten MOCK_RELEASES='[]' && fail "keep=ten accepted"
[ "$(wc -l < t6.log)" -eq 0 ] || fail "gh called despite invalid keep"

echo "test: missing asset is rejected"
run_publish t7 FILES='dist/missing-*.pdf' KEEP=0 MOCK_RELEASES='[]' && fail "missing asset accepted"
[ "$(wc -l < t7.log)" -eq 0 ] || fail "gh called despite missing asset"

# --- 7. dry-run: no mutations, no token needed -------------------------------
echo "test: dry-run performs no mutation"
if run_publish t8 FILES='dist/*.pdf' KEEP=1 DRY_RUN=true GH_TOKEN= MOCK_RELEASES="$RELEASES" MOCK_TAGS="$TAGS"; then
  [ "$(wc -l < t8.log)" -eq 0 ] || fail "dry-run issued mutating gh calls: $(cat t8.log)"
  grep -q '^\[dry-run\] gh release create' t8.out || fail "dry-run did not print the create call"
  grep -q '^\[dry-run\] gh release delete v2026.01.04-r4' t8.out || fail "dry-run did not print the prune plan"
else
  fail "dry-run exited nonzero: $(tail -n 3 t8.out)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All release/publish-dated tests passed."
else
  echo "$FAILURES release/publish-dated test(s) failed."
fi
[ "$FAILURES" -eq 0 ]
