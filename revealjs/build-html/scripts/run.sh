#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	python3 (>= 3.9, preinstalled on ubuntu-latest)
#	pip (installs PyYAML at the pinned version)
#	docker (runs the digest-pinned pandoc and mermaid-cli images)
#	node + npm (vendors reveal.js and KaTeX from the lockfile)
#	stat, sha256sum
# @description:
#	Build one Markdown slide deck into a self-contained reveal.js HTML
#	file. Driven entirely by environment variables set in action.yml:
#	SOURCE (deck Markdown), NAME (deck name = output basename), OUT_DIR,
#	BUILD_ROOT, THEMES_DIR, PANDOC_IMAGE, MERMAID_IMAGE (optional; only
#	needed when the deck has ```mermaid blocks) and CHECK ('true' =
#	validate front matter + theme only, no docker). Pipeline:
#	  1. prepare.py plan      front matter + theme -> pass-1 defaults,
#	                          metadata, mermaid config, plan.env
#	  2. pandoc (container)   Markdown -> JSON AST; Lua filters extract
#	                          ```mermaid blocks to <build>/mermaid/*.mmd,
#	                          apply the divider/callout rules and write
#	                          the structure summary
#	  3. mermaid-cli          renders only the SVGs that are missing,
#	     (container)          with the theme fonts mounted as system fonts
#	  4. prepare.py embed-fonts / finalize
#	  5. pandoc (container)   JSON AST -> reveal.js HTML, own template,
#	                          --embed-resources, vendored reveal.js/KaTeX
#	  6. prepare.py verify-html
#	Every container runs with --network none as the workspace owner
#	(uid:gid of the checkout); files created by a root shell (gh act)
#	are handed back to that owner. Outputs are appended to
#	$GITHUB_OUTPUT when set.
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: SOURCE=<md> NAME=<deck> PANDOC_IMAGE=<ref> [MERMAID_IMAGE=<ref>] [OUT_DIR=dist] [CHECK=true] run.sh
### Example: SOURCE=decks/showcase/slides.md NAME=showcase PANDOC_IMAGE=pandoc/core:3.11.0.0-alpine@sha256:... run.sh

set -euo pipefail

# Pinned runtime dependency (keep in sync with DECISIONS.md and the lint job).
PYYAML_VERSION="6.0.2"

SOURCE="${SOURCE:?SOURCE is required}"
NAME="${NAME:?NAME is required}"
OUT_DIR="${OUT_DIR:-dist}"
BUILD_ROOT="${BUILD_ROOT:-build}"
THEMES_DIR="${THEMES_DIR:-themes}"
PANDOC_IMAGE="${PANDOC_IMAGE:-}"
MERMAID_IMAGE="${MERMAID_IMAGE:-}"
CHECK="${CHECK:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE="$SCRIPT_DIR/prepare.py"

err() { echo "::error::$*" >&2; }
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "Installing PyYAML==$PYYAML_VERSION"
  python3 -m pip install --user --quiet "PyYAML==$PYYAML_VERSION"
fi

# ---------------------------------------------------------------------
# check mode: validate the front matter and the theme, write nothing.
# ---------------------------------------------------------------------
case "$CHECK" in
  true|1|yes)
    python3 "$PREPARE" check --source "$SOURCE" --themes-dir "$THEMES_DIR"
    exit 0
    ;;
  *) ;;
esac

: "${PANDOC_IMAGE:?PANDOC_IMAGE is required unless CHECK=true}"
command -v docker >/dev/null 2>&1 || { err "docker not found on PATH"; exit 1; }
command -v npm >/dev/null 2>&1 || { err "npm not found on PATH (needed to vendor reveal.js/KaTeX)"; exit 1; }

BUILD_DIR="$BUILD_ROOT/$NAME"
WORKSPACE="$(pwd -P)"
# Containers run as the owner of the checkout (the runner user on hosted
# runners, the host user under `gh act --bind`); a root shell hands every
# file it creates back to that owner so nothing is left root-owned.
WS_OWNER="$(stat -c '%u:%g' "$WORKSPACE")"
own() {
  if [ "$(id -u)" = "0" ] && [ "${WS_OWNER%%:*}" != "0" ]; then
    chown -R "$WS_OWNER" "$@"
  fi
}
drun() {
  docker run --rm --network none -u "$WS_OWNER" -e HOME=/tmp \
    -v "$WORKSPACE:/data" -w /data "$@"
}

mkdir -p "$BUILD_DIR" "$OUT_DIR"
own "$BUILD_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------
# 1. plan
# ---------------------------------------------------------------------
group "Plan deck $NAME"
python3 "$PREPARE" plan --source "$SOURCE" --themes-dir "$THEMES_DIR" \
  --name "$NAME" --build-dir "$BUILD_DIR" --out-dir "$OUT_DIR" \
  --mermaid-image "$MERMAID_IMAGE"
# plan.env holds shell-quoted KEY=VALUE pairs written by prepare.py.
# shellcheck disable=SC1090,SC1091
source "$BUILD_DIR/plan.env"
endgroup

# ---------------------------------------------------------------------
# stage the engine (template + filters) and the vendored assets inside
# the workspace: bind-mounted containers cannot see GITHUB_ACTION_PATH.
# ---------------------------------------------------------------------
group "Stage engine and vendored assets"
rm -rf "$BUILD_DIR/engine" "$BUILD_DIR/vendor"
cp -r "$ACTION_DIR/pandoc" "$BUILD_DIR/engine"
LOCK_HASH="$(sha256sum "$ACTION_DIR/package-lock.json" | cut -c1-16)"
VENDOR_CACHE="${RUNNER_TEMP:-/tmp}/revealjs-vendor-$LOCK_HASH"
if [ ! -d "$VENDOR_CACHE/node_modules/reveal.js/dist" ] || [ ! -d "$VENDOR_CACHE/node_modules/katex/dist" ]; then
  mkdir -p "$VENDOR_CACHE"
  cp "$ACTION_DIR/package.json" "$ACTION_DIR/package-lock.json" "$VENDOR_CACHE/"
  (cd "$VENDOR_CACHE" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
fi
mkdir -p "$BUILD_DIR/vendor/reveal.js" "$BUILD_DIR/vendor/katex"
cp -r "$VENDOR_CACHE/node_modules/reveal.js/dist" "$BUILD_DIR/vendor/reveal.js/dist"
cp -r "$VENDOR_CACHE/node_modules/katex/dist" "$BUILD_DIR/vendor/katex/dist"
own "$BUILD_DIR"
endgroup

# ---------------------------------------------------------------------
# 2. pass 1: Markdown -> JSON AST (+ mermaid extraction, structure)
# ---------------------------------------------------------------------
group "pandoc pass 1 (Markdown -> AST)"
drun "$PANDOC_IMAGE" --defaults "$BUILD_DIR/pass1.yml" 2> >(tee "$BUILD_DIR/logs/pass1.log" >&2)
endgroup

# ---------------------------------------------------------------------
# 3. mermaid: render the diagrams whose SVG is missing (hash-named, so
#    unchanged diagrams under an unchanged config/fonts/renderer are reused)
# ---------------------------------------------------------------------
shopt -s nullglob
mmds=("$MERMAID_DIR"/*.mmd)
shopt -u nullglob
if [ "${#mmds[@]}" -gt 0 ]; then
  group "mermaid-cli (${#mmds[@]} diagram(s))"
  if [ -z "$MERMAID_IMAGE" ]; then
    err "The deck contains ${#mmds[@]} \`\`\`mermaid block(s) but no mermaid-image was provided."
    exit 1
  fi
  font_mount=()
  if [ "${FONT_COUNT:-0}" -gt 0 ]; then
    font_mount=(-v "$WORKSPACE/$FONTS_DIR:/usr/share/fonts/deck:ro")
  fi
  for mmd in "${mmds[@]}"; do
    hash="$(basename "$mmd" .mmd)"
    svg="$MERMAID_DIR/$hash.svg"
    if [ -s "$svg" ]; then
      echo "cached: $svg"
      continue
    fi
    echo "rendering: $mmd"
    drun "${font_mount[@]}" "$MERMAID_IMAGE" \
      -i "$mmd" -o "$svg" -c "$BUILD_DIR/mermaid.json" \
      -I "m-${hash:0:12}" -b transparent 2>&1 | tee -a "$BUILD_DIR/logs/mermaid.log"
    if [ ! -s "$svg" ]; then
      err "mermaid-cli produced no SVG for $mmd"
      exit 1
    fi
  done
  python3 "$PREPARE" embed-fonts --build-dir "$BUILD_DIR"
  endgroup
fi

# ---------------------------------------------------------------------
# 4./5. finalize + pass 2: JSON AST -> self-contained reveal.js HTML
# ---------------------------------------------------------------------
group "pandoc pass 2 (AST -> reveal.js HTML)"
python3 "$PREPARE" finalize --build-dir "$BUILD_DIR"
drun "$PANDOC_IMAGE" --defaults "$BUILD_DIR/pass2.yml" 2> >(tee "$BUILD_DIR/logs/pass2.log" >&2)
endgroup

# ---------------------------------------------------------------------
# 6. verify + outputs
# ---------------------------------------------------------------------
group "Verify $OUT_HTML"
verify="$(python3 "$PREPARE" verify-html --html "$OUT_HTML" --build-dir "$BUILD_DIR")"
echo "$verify"
own "$BUILD_DIR" "$OUT_DIR"
ls -la "$OUT_HTML"
endgroup

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "html=$OUT_HTML"
    echo "$verify" | grep -E '^slides='
    echo "title=$DECK_TITLE"
    echo "author=$DECK_AUTHOR"
    echo "theme=$DECK_THEME"
    echo "size=${WIDTH}x${HEIGHT}"
    echo "pdf-size=${PDF_WIDTH}x${PDF_HEIGHT}"
    echo "pdf-fragments=$PDF_FRAGMENTS"
    echo "pdf-pause=$PDF_PAUSE"
    echo "pdf-load-pause=$PDF_LOAD_PAUSE"
    echo "build-dir=$BUILD_DIR"
  } >> "$GITHUB_OUTPUT"
fi
