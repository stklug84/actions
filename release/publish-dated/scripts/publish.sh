#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	gh (GitHub CLI, authenticated via GH_TOKEN)
#	jq
#	date, head, sed, mktemp
# @description:
#	Publish build artifacts as a dated, run-numbered GitHub release
#	(tag v<YYYY.MM.DD>-r<run-number>) and optionally prune older
#	releases created by the same scheme. Driven by environment
#	variables set in action.yml: FILES (newline/space-separated glob
#	list of assets), TITLE_PREFIX (release title "<prefix> <date>
#	(<short-sha>)"), LIST_HEADING (heading above the asset list in the
#	notes), KEEP (prune to the N newest matching releases; 0 = keep
#	all), DRY_RUN ('true' = print every mutation instead of running
#	it), plus GH_TOKEN, GH_REPO, GITHUB_SHA, GITHUB_RUN_NUMBER and the
#	event payload at GITHUB_EVENT_PATH (commit subject for the notes).
#	Extracted from the latex-build-cv reusable workflow; see the
#	README for the behaviour it preserves and the two fixes it adds:
#	  * a re-run reuses the release already tagged -r<run-number>
#	    (assets replaced with --clobber) instead of failing;
#	  * pruning is fail-safe: it runs only when BOTH the release list
#	    and the tag list were retrieved successfully, so a failed
#	    inventory can never delete the tags of live releases.
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: FILES=<globs> [TITLE_PREFIX=Release] [LIST_HEADING=Files:] [KEEP=0] [DRY_RUN=false] publish.sh
### Example: FILES='dist/*.pdf' TITLE_PREFIX=Slides LIST_HEADING='Decks:' KEEP=10 publish.sh

set -euo pipefail

: "${FILES:?FILES is required}"
TITLE_PREFIX="${TITLE_PREFIX:-Release}"
LIST_HEADING="${LIST_HEADING:-Files:}"
KEEP="${KEEP:-0}"
DRY_RUN="${DRY_RUN:-false}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
: "${GH_REPO:?GH_REPO is required}"

err() { echo "::error::$*" >&2; }

if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
  err "keep must be a non-negative integer, got '$KEEP'"
  exit 1
fi
case "$DRY_RUN" in
  true|1|yes) DRY_RUN=true ;;
  *) DRY_RUN=false ;;
esac
if [ "$DRY_RUN" = false ]; then
  : "${GH_TOKEN:?GH_TOKEN is required unless dry-run}"
fi

run() {
  # run <cmd...>: execute, or print in dry-run mode.
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# --- collect assets ------------------------------------------------------
assets=()
shopt -s nullglob
# FILES is a whitespace/newline-separated glob list; word splitting and
# globbing are intended.
# shellcheck disable=SC2086
for pattern in $FILES; do
  # Expand the glob into an array (globbing intended).
  # shellcheck disable=SC2206
  matches=($pattern)
  if [ "${#matches[@]}" -eq 0 ]; then
    err "no file matches '$pattern'"
    exit 1
  fi
  for f in "${matches[@]}"; do
    if [ ! -s "$f" ]; then
      err "asset is missing or empty: $f"
      exit 1
    fi
    assets+=("$f")
  done
done
shopt -u nullglob
if [ "${#assets[@]}" -eq 0 ]; then
  err "no assets to release"
  exit 1
fi

# --- tag / title / notes -------------------------------------------------
# Workflow tag pattern: v<YYYY.MM.DD>-r<N>. Only releases/tags matching it
# are ever touched; manually created releases or tags in other formats are
# left alone.
PATTERN='^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[0-9]+$'
RUN_SUFFIX="-r${GITHUB_RUN_NUMBER}"
SHORT_SHA="${GITHUB_SHA:0:7}"
SUBJECT=""
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  SUBJECT="$(jq -r '.head_commit.message // ""' "$GITHUB_EVENT_PATH" | head -n1)"
fi

# Re-run detection: a previous attempt of THIS run (same -r<N>) may already
# have published. Reuse its tag (the date in the tag is the first attempt's)
# and replace the assets instead of failing on "tag exists".
existing=""
if [ "$DRY_RUN" = false ]; then
  if ! releases_json="$(gh release list --limit 1000 --json tagName)"; then
    err "gh release list failed; cannot check for an existing release of run ${GITHUB_RUN_NUMBER}"
    exit 1
  fi
  existing="$(jq -r --arg suffix "$RUN_SUFFIX" '.[].tagName | select(endswith($suffix))' <<< "$releases_json" \
    | grep -E "$PATTERN" | head -n1 || true)"
fi

if [ -n "$existing" ]; then
  TAG="$existing"
  echo "Release $TAG already exists for run ${GITHUB_RUN_NUMBER} (re-run); replacing its assets."
else
  TAG="v$(date +%Y.%m.%d)${RUN_SUFFIX}"
fi
TITLE="$TITLE_PREFIX $(date +%Y-%m-%d) ($SHORT_SHA)"

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
{
  echo "Built from $GITHUB_SHA"
  echo
  if [ -n "$SUBJECT" ]; then
    echo "Commit: $SUBJECT"
    echo
  fi
  echo "$LIST_HEADING"
  for f in "${assets[@]}"; do
    echo "- $(basename "$f")"
  done
} > "$notes"

echo "Release tag:   $TAG"
echo "Release title: $TITLE"
echo "Release notes:"
sed 's/^/  | /' "$notes"

if [ -n "$existing" ]; then
  run gh release upload "$TAG" "${assets[@]}" --clobber
  run gh release edit "$TAG" --title "$TITLE" --notes-file "$notes"
else
  run gh release create "$TAG" "${assets[@]}" \
    --target "$GITHUB_SHA" --title "$TITLE" --notes-file "$notes"
fi
echo "Published release $TAG"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "tag=$TAG"
    echo "title=$TITLE"
  } >> "$GITHUB_OUTPUT"
fi

# --- prune -----------------------------------------------------------------
if [ "$KEEP" -eq 0 ]; then
  echo "keep=0: pruning disabled."
  exit 0
fi
"$(dirname "${BASH_SOURCE[0]}")/prune.sh" "$KEEP" "$PATTERN" "$DRY_RUN"
