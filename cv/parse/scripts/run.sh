#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (>= 3.9, preinstalled on ubuntu-latest)
#	pip (installs PyYAML and Jinja2 at pinned versions)
# @description:
#	Thin wrapper around scripts/parse.py for the cv/parse composite
#	action. Driven entirely by environment variables set in
#	action.yml: SOURCE (canonical cv.yaml), MODE (latex | web),
#	STYLE (plain | sidebar, latex only), CV_LANG (de | en — named
#	CV_LANG, not LANG, to avoid clobbering the system locale),
#	OUT_DIR (output directory), and CHECK ('true'/'false' — validate
#	only,
#	write nothing). Ensures PyYAML and Jinja2 are present at the
#	pinned versions (installed with `pip --user` when missing), then
#	dispatches to parse.py. SCRIPT_DIR is resolved from BASH_SOURCE
#	so the action works regardless of the caller's working
#	directory (GITHUB_ACTION_PATH points here in CI).
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: SOURCE=<path> MODE=<latex|web> [STYLE=..] [CV_LANG=..] OUT_DIR=<dir> [CHECK=true] run.sh
### Example: MODE=web OUT_DIR=_data SOURCE=data/cv.yaml run.sh

set -euo pipefail

# Pinned runtime dependencies (keep in sync with DECISIONS.md).
PYYAML_VERSION="6.0.2"
JINJA2_VERSION="3.1.5"

SOURCE="${SOURCE:-data/cv.yaml}"
MODE="${MODE:-latex}"
STYLE="${STYLE:-plain}"
LANG_IN="${CV_LANG:-de}"
OUT_DIR="${OUT_DIR:?OUT_DIR is required}"
CHECK="${CHECK:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { echo "::error::$*" >&2; }

# Ensure the pinned dependencies are importable; install on demand.
if ! python3 -c 'import yaml, jinja2' >/dev/null 2>&1; then
  echo "Installing PyYAML==$PYYAML_VERSION and Jinja2==$JINJA2_VERSION"
  python3 -m pip install --user --quiet \
    "PyYAML==$PYYAML_VERSION" "Jinja2==$JINJA2_VERSION"
fi

ARGS=(--source "$SOURCE" --mode "$MODE" --out-dir "$OUT_DIR")

case "$CHECK" in
  true|1|yes) ARGS+=(--check) ;;
  *) ;;
esac

if [ "$MODE" = "latex" ]; then
  ARGS+=(--style "$STYLE" --lang "$LANG_IN")
fi

if ! python3 "$SCRIPT_DIR/parse.py" "${ARGS[@]}"; then
  err "cv/parse failed (mode=$MODE style=$STYLE lang=$LANG_IN)."
  exit 1
fi
