#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	find
#	mktemp
#	ShellCheck
#	tr
#	yq (mikefarah)
# @description:
#	Run shellcheck on every `run:` block with `shell: bash` extracted
#	from the composite action.yml files. Needed because actionlint
#	only covers .github/workflows/*, not composite actions. Rules are
#	picked up from .shellcheckrc in the repository root, so run this
#	from there. All dependencies are preinstalled on ubuntu-latest.
# @arguments:
#	none
## Usage: scripts/shellcheck-actions.sh
### Example: scripts/shellcheck-actions.sh

set -euo pipefail

command -v yq >/dev/null 2>&1 || { echo "::error::yq not found" >&2; exit 1; }
command -v shellcheck >/dev/null 2>&1 || { echo "::error::shellcheck not found" >&2; exit 1; }

TMPDIR_SNIPPETS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SNIPPETS"' EXIT

FAILURES=0
CHECKED=0

# All composite action manifests, excluding anything under .github/.
while IFS= read -r -d '' ACTION_FILE; do
  STEP_COUNT="$(yq '.runs.steps | length' "$ACTION_FILE")"
  for ((i = 0; i < STEP_COUNT; i++)); do
    SHELL_KIND="$(yq ".runs.steps[$i].shell // \"\"" "$ACTION_FILE")"
    [ "$SHELL_KIND" = "bash" ] || continue

    STEP_NAME="$(yq ".runs.steps[$i].name // \"step-$i\"" "$ACTION_FILE")"
    SNIPPET="$TMPDIR_SNIPPETS/$(echo "$ACTION_FILE-$i" | tr '/ ' '__').sh"

    {
      echo "#!/usr/bin/env bash"
      yq ".runs.steps[$i].run" "$ACTION_FILE"
    } > "$SNIPPET"

    CHECKED=$((CHECKED + 1))
    echo "shellcheck: $ACTION_FILE :: $STEP_NAME"
    if ! shellcheck "$SNIPPET"; then
      echo "::error file=$ACTION_FILE::shellcheck failed for step '$STEP_NAME'"
      FAILURES=$((FAILURES + 1))
    fi
  done
done < <(find . -path ./.git -prune -o -path ./.github -prune -o -name 'action.yml' -print0)

echo
echo "Checked $CHECKED bash step(s), $FAILURES failure(s)."
[ "$FAILURES" -eq 0 ]
