#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	grep
#	sed
# @description:
#	Resolve digest-pinned container image references from a pin-only,
#	multi-stage Dockerfile. Every non-blank, non-comment line must be a
#	`FROM <ref>@sha256:<64 hex> AS <stage>` instruction (the file is a
#	Dependabot/hadolint-friendly pin registry and is never built). Each
#	requested stage must appear exactly once. Prints one
#	`<stage>-image=<ref>` line per requested stage to stdout, in a form
#	that can be appended to $GITHUB_OUTPUT; diagnostics go to stderr.
# @arguments:
#	<dockerfile>  path to the pin-only Dockerfile
#	<stages>      space-separated stage names that must be present
## Usage: scripts/resolve.sh <dockerfile> "<stage> [<stage>...]"
### Example: scripts/resolve.sh .github/docker/revealjs/Dockerfile "pandoc mermaid decktape"

set -euo pipefail

DOCKERFILE="${1:?dockerfile path is required}"
STAGES="${2:?stage list is required}"

if [ ! -f "$DOCKERFILE" ]; then
  echo "::error::Dockerfile not found: $DOCKERFILE" >&2
  exit 1
fi

# Every instruction must be a digest-pinned, named FROM. Anything else
# (RUN, COPY, ARG, unpinned or unnamed FROM lines) is rejected so a
# partially understood file can never yield partially resolved images.
FROM_RE='^[Ff][Rr][Oo][Mm][[:space:]]+([^[:space:]]+@sha256:[0-9a-f]{64})[[:space:]]+[Aa][Ss][[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]*$'
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  # Skip blank lines and comments (incl. `# syntax=` / hadolint directives).
  if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
    continue
  fi
  if ! [[ "$line" =~ $FROM_RE ]]; then
    echo "::error file=$DOCKERFILE,line=$lineno::Only 'FROM <image>@sha256:<digest> AS <stage>' lines are allowed in the pin-only Dockerfile; got: $line" >&2
    exit 1
  fi
done < "$DOCKERFILE"

for stage in $STAGES; do
  refs="$(sed -nE "s/$FROM_RE/\1 \2/p" "$DOCKERFILE" | awk -v s="$stage" '$2 == s {print $1}')"
  count="$(printf '%s\n' "$refs" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    echo "::error file=$DOCKERFILE::Stage '$stage' not found (expected 'FROM <image>@sha256:... AS $stage')." >&2
    exit 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "::error file=$DOCKERFILE::Stage '$stage' is defined $count times; it must appear exactly once." >&2
    exit 1
  fi
  echo "resolved $stage -> $refs" >&2
  printf '%s-image=%s\n' "$stage" "$refs"
done
