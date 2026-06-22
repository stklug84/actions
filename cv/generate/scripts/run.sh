#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (>= 3.9, preinstalled on ubuntu-latest)
#	pip (installs PyYAML and Jinja2 at pinned versions)
# @description:
#	Thin wrapper around scripts/render_variants.py for the cv/generate
#	composite action. Expands the build matrix declared in a manifest
#	into a per-variant CV tree (one main .tex + .engine + cv/parse
#	section bodies per leaf). Driven entirely by environment variables
#	set in action.yml: MANIFEST (build matrix), TEMPLATES_DIR (Jinja2
#	per-style main templates), CVS_ROOT (output root), DATA_DIR
#	(directory holding the source YAMLs), MAIN_NAME (leaf main basename),
#	and CHECK ('true'/'false' — validate only, write nothing).
#
#	The cv/parse emitter (parse.py) ships in the sibling cv/parse action
#	within this same actions checkout; it is resolved relative to this
#	script so generation and --check both drive the canonical emitter.
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: MANIFEST=.. TEMPLATES_DIR=.. CVS_ROOT=.. DATA_DIR=.. [MAIN_NAME=..] [CHECK=true] run.sh
### Example: MANIFEST=data/variants.yml TEMPLATES_DIR=templates CVS_ROOT=cvs DATA_DIR=data run.sh

set -euo pipefail

# Pinned runtime dependencies (keep in sync with cv/parse).
PYYAML_VERSION="6.0.2"
JINJA2_VERSION="3.1.5"

MANIFEST="${MANIFEST:?MANIFEST is required}"
TEMPLATES_DIR="${TEMPLATES_DIR:?TEMPLATES_DIR is required}"
CVS_ROOT="${CVS_ROOT:?CVS_ROOT is required}"
DATA_DIR="${DATA_DIR:?DATA_DIR is required}"
MAIN_NAME="${MAIN_NAME:-sklug-cv}"
CHECK="${CHECK:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# parse.py lives in the sibling cv/parse action (../../parse/scripts).
PARSE_PY="${PARSE_PY:-$SCRIPT_DIR/../../parse/scripts/parse.py}"

err() { echo "::error::$*" >&2; }

if ! python3 -c 'import yaml, jinja2' >/dev/null 2>&1; then
  echo "Installing PyYAML==$PYYAML_VERSION and Jinja2==$JINJA2_VERSION"
  python3 -m pip install --user --quiet \
    "PyYAML==$PYYAML_VERSION" "Jinja2==$JINJA2_VERSION"
fi

ARGS=(
  --manifest "$MANIFEST"
  --templates-dir "$TEMPLATES_DIR"
  --cvs-root "$CVS_ROOT"
  --data-dir "$DATA_DIR"
  --main-name "$MAIN_NAME"
)

if [ -f "$PARSE_PY" ]; then
  ARGS+=(--parse-py "$PARSE_PY")
fi

case "$CHECK" in
  true|1|yes) ARGS+=(--check) ;;
  *) ;;
esac

if ! python3 "$SCRIPT_DIR/render_variants.py" "${ARGS[@]}"; then
  err "cv/generate failed."
  exit 1
fi
