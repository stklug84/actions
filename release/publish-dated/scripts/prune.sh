#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	gh (GitHub CLI, authenticated via GH_TOKEN)
#	jq
# @description:
#	Fail-safe pruning of dated releases. Keeps the <keep> newest
#	releases whose tag matches <pattern> and deletes the older ones
#	together with their tags, then removes tags matching <pattern>
#	that have no release (orphans left by older runs or a partial
#	prune). Both inventories (releases via `gh release list`, tags via
#	the paginated git-refs API) MUST succeed before anything is
#	deleted: a failed listing aborts the prune with a nonzero exit and
#	zero deletions, which is what the inline latex-build-cv version
#	got wrong (its `|| true` turned a failed release listing into an
#	"everything is an orphan" sweep). Manually created releases or
#	tags in other formats are never touched. In dry-run mode every
#	deletion is printed instead of executed.
# @arguments:
#	<keep>     number of newest matching releases to keep (> 0)
#	<pattern>  extended regex the tags must match
#	[dry-run]  'true' prints deletions instead of running them
## Usage: prune.sh <keep> <pattern> [true|false]
### Example: prune.sh 10 '^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[0-9]+$' false

set -euo pipefail

KEEP="${1:?keep is required}"
PATTERN="${2:?pattern is required}"
DRY_RUN="${3:-false}"
: "${GH_REPO:?GH_REPO is required}"

err() { echo "::error::$*" >&2; }

if ! [[ "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
  err "keep must be a positive integer, got '$KEEP'"
  exit 1
fi

run() {
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

# --- inventory: both listings must succeed before any deletion -----------
if ! releases_json="$(gh release list --limit 1000 --json tagName,createdAt)"; then
  err "gh release list failed; refusing to prune (nothing deleted)."
  exit 1
fi
if ! tags_json="$(gh api --paginate "repos/${GH_REPO}/git/matching-refs/tags/" --jq '.[].ref')"; then
  err "listing tags failed; refusing to prune (nothing deleted)."
  exit 1
fi

# Newest first by creation date. `grep` exits 1 on "no match", which is a
# legitimate empty result here; any other failure has already aborted above.
mapfile -t release_tags < <(
  jq -r 'sort_by(.createdAt) | reverse | .[].tagName' <<< "$releases_json" | { grep -E "$PATTERN" || true; }
)
mapfile -t all_tags < <(
  printf '%s\n' "${tags_json//refs\/tags\//}" | { grep -E "$PATTERN" || true; }
)

echo "Found ${#release_tags[@]} matching release(s) and ${#all_tags[@]} matching tag(s); keeping the newest $KEEP release(s)."

# (1) Prune old RELEASES together with their tags.
for ((i = KEEP; i < ${#release_tags[@]}; i++)); do
  echo "Pruning release ${release_tags[$i]} (and its tag)"
  run gh release delete "${release_tags[$i]}" --cleanup-tag --yes
done

# (2) Sweep ORPHAN TAGS: matching tags with no release at all. Tags whose
# release was just pruned above are gone (or, in dry-run, about to be) and
# must not be reported twice, so consider only the tags of surviving releases
# as "live" and everything that was never a release as an orphan.
declare -A live=()
for ((i = 0; i < ${#release_tags[@]}; i++)); do
  live["${release_tags[$i]}"]=1
done
for tag in "${all_tags[@]}"; do
  if [ -z "${live[$tag]:-}" ]; then
    echo "Deleting orphan tag $tag (no matching release)"
    run gh api -X DELETE "repos/${GH_REPO}/git/refs/tags/${tag}"
  fi
done
echo "Prune complete."
