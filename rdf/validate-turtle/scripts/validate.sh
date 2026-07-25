#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	find
#	riot (Apache Jena, on PATH — installed by action.yml)
# @description:
#	Validate Turtle/RDF files with `riot --validate` for the
#	rdf/validate-turtle composite action. Driven by the GLOB
#	environment variable: space-separated glob pattern(s),
#	find-style — a pattern without `/` is matched by file name
#	anywhere in the tree (find -name); a pattern with `/` is matched
#	against the path relative to the working directory (find -path,
#	whose `*` crosses `/`, so `**` behaves as "any directories"; a
#	leading `**/` additionally matches files at the root). Prints
#	`OK <file>` / `FAIL <file>` (plus riot's diagnostics on failure)
#	and exits nonzero when any file fails or no file matches.
# @arguments:
#	none (configured via the GLOB environment variable)
## Usage: GLOB="<pattern> [<pattern> ...]" scripts/validate.sh
### Example: GLOB="**/*.ttl vocab/*.trig" scripts/validate.sh

set -euo pipefail

GLOB="${GLOB:?GLOB is required (space-separated glob patterns)}"

err() { echo "::error::$*" >&2; }

command -v riot >/dev/null 2>&1 || {
	err "riot not found on PATH"
	exit 1
}

read -ra PATTERNS <<<"$GLOB"
if [ "${#PATTERNS[@]}" -eq 0 ]; then
	err "GLOB contains no patterns."
	exit 1
fi

# Translate the glob patterns into a find(1) condition. find's `*`
# matches across `/`, so `**` needs no special casing — except that a
# leading `**/` cannot match root-level files via -path (every path
# starts with `./`), hence the extra -name alternative.
COND=()
for pat in "${PATTERNS[@]}"; do
	if [ "${#COND[@]}" -gt 0 ]; then
		COND+=(-o)
	fi
	if [[ "$pat" == */* ]]; then
		COND+=(-path "./$pat")
		rest="${pat#\*\*/}"
		if [[ "$rest" != "$pat" && "$rest" != */* ]]; then
			COND+=(-o -name "$rest")
		fi
	else
		COND+=(-name "$pat")
	fi
done

CHECKED=0
FAILURES=0
while IFS= read -r -d '' file; do
	CHECKED=$((CHECKED + 1))
	if OUTPUT="$(riot --validate "$file" 2>&1)"; then
		echo "OK   $file"
	else
		echo "FAIL $file"
		if [ -n "$OUTPUT" ]; then
			echo "$OUTPUT"
		fi
		FAILURES=$((FAILURES + 1))
	fi
done < <(find . -path ./.git -prune -o -type f \( "${COND[@]}" \) -print0)

if [ "$CHECKED" -eq 0 ]; then
	err "No files matched GLOB='$GLOB'."
	exit 1
fi

echo
echo "Validated $CHECKED file(s), $FAILURES failure(s)."
[ "$FAILURES" -eq 0 ]
