#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	find
#	jq
#	sort
# @description:
#	Discover Markdown slide decks under a root directory and emit a
#	GitHub Actions matrix. The tree is scanned RECURSIVELY: every
#	directory that contains a file named <main> (default slides.md) is
#	a deck. The deck `name` is the directory path relative to <root>
#	with '/' replaced by '-', so nested layouts yield unique names;
#	names are restricted to [A-Za-z0-9._-] because they become
#	artifact and output file names. Prints single-line JSON
#	{"include":[...]} to stdout for strategy.matrix via fromJson();
#	diagnostics go to stderr so stdout stays machine-readable. An
#	empty root yields {"include":[]}.
# @arguments:
#	<root>  directory scanned recursively for decks
#	[main]  deck file name (default: slides.md)
## Usage: scan.sh <root> [main]
### Example: scan.sh decks slides.md | jq .

set -euo pipefail

ROOT="${1:?root directory is required}"
MAIN="${2:-slides.md}"

if [ ! -d "$ROOT" ]; then
  echo "::error::Deck root '$ROOT' is not a directory." >&2
  exit 1
fi

ROOT="${ROOT%/}"
entries=()

while IFS= read -r -d '' file; do
  dir="$(dirname "$file")"
  rel="${dir#"$ROOT"/}"
  if [ "$rel" = "$ROOT" ]; then
    # <main> directly inside root: the deck is named after the root itself.
    rel="$(basename "$ROOT")"
  fi
  name="${rel//\//-}"
  if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "::error::Deck directory '$dir' yields the name '$name'; only [A-Za-z0-9._-] are allowed (artifact/file names)." >&2
    exit 1
  fi
  echo "deck: $name ($file)" >&2
  entries+=("$(jq -cn --arg name "$name" --arg dir "$dir" --arg source "$file" \
    '{name: $name, dir: $dir, source: $source}')")
done < <(find "$ROOT" -type f -name "$MAIN" -print0 | sort -z)

if [ "${#entries[@]}" -eq 0 ]; then
  echo "::warning::No '$MAIN' found under '$ROOT'; emitting an empty matrix." >&2
  echo '{"include":[]}'
  exit 0
fi

printf '%s\n' "${entries[@]}" | jq -cs '{include: .}'
