#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	docker (runs the digest-pinned DeckTape image)
#	python3 + pip (installs pypdf at the pinned version for verification)
#	stat, dirname, basename
# @description:
#	Export a self-contained reveal.js HTML deck to PDF with DeckTape
#	(reveal plugin) and verify the result. Driven entirely by
#	environment variables set in action.yml: HTML (deck file inside the
#	workspace), PDF (output path; default <html-dir>/<basename>.pdf),
#	DECKTAPE_IMAGE (digest-pinned ghcr.io/astefanutti/decktape),
#	SIZE (<width>x<height> px, must match the deck's size), FRAGMENTS
#	('true' = one page per fragment step), PAUSE / LOAD_PAUSE (ms),
#	PDF_TITLE / PDF_AUTHOR (PDF metadata) and EXPECTED_PAGES (slide
#	count from build-html; '0' skips the equality check). The
#	container runs with --network none as the workspace owner (uid:gid
#	of the checkout) and reads the deck via file://, so the export is
#	deterministic and needs no network. Outputs are appended to
#	$GITHUB_OUTPUT when set.
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: HTML=<deck.html> DECKTAPE_IMAGE=<ref> [PDF=<out.pdf>] [SIZE=1280x720] [FRAGMENTS=false] [EXPECTED_PAGES=N] run.sh
### Example: HTML=dist/showcase.html DECKTAPE_IMAGE=ghcr.io/astefanutti/decktape:3.16.1@sha256:... SIZE=1280x720 run.sh

set -euo pipefail

# Pinned runtime dependency (keep in sync with the lint job).
PYPDF_VERSION="6.19.0"

HTML="${HTML:?HTML is required}"
DECKTAPE_IMAGE="${DECKTAPE_IMAGE:?DECKTAPE_IMAGE is required}"
PDF="${PDF:-}"
SIZE="${SIZE:-1280x720}"
FRAGMENTS="${FRAGMENTS:-false}"
PAUSE="${PAUSE:-500}"
LOAD_PAUSE="${LOAD_PAUSE:-2000}"
PDF_TITLE="${PDF_TITLE:-}"
PDF_AUTHOR="${PDF_AUTHOR:-}"
EXPECTED_PAGES="${EXPECTED_PAGES:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { echo "::error::$*" >&2; }

command -v docker >/dev/null 2>&1 || { err "docker not found on PATH"; exit 1; }

if [ ! -s "$HTML" ]; then
  err "HTML deck not found or empty: $HTML"
  exit 1
fi
if ! [[ "$SIZE" =~ ^([0-9]{3,5})x([0-9]{3,5})$ ]]; then
  err "SIZE must be <width>x<height> in px, got '$SIZE'"
  exit 1
fi
WIDTH="${BASH_REMATCH[1]}"
HEIGHT="${BASH_REMATCH[2]}"
for n in "$PAUSE" "$LOAD_PAUSE" "$EXPECTED_PAGES"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    err "PAUSE, LOAD_PAUSE and EXPECTED_PAGES must be non-negative integers (got '$n')"
    exit 1
  fi
done

if [ -z "$PDF" ]; then
  PDF="${HTML%.html}.pdf"
fi

WORKSPACE="$(pwd -P)"
case "$HTML" in
  /*) err "HTML must be a workspace-relative path (got absolute '$HTML')"; exit 1 ;;
esac
case "$PDF" in
  /*) err "PDF must be a workspace-relative path (got absolute '$PDF')"; exit 1 ;;
esac

# Containers run as the owner of the checkout (see build-html/run.sh).
WS_OWNER="$(stat -c '%u:%g' "$WORKSPACE")"
own() {
  if [ "$(id -u)" = "0" ] && [ "${WS_OWNER%%:*}" != "0" ]; then
    chown -R "$WS_OWNER" "$@"
  fi
}

mkdir -p "$(dirname "$PDF")"
own "$(dirname "$PDF")"
rm -f "$PDF"

args=(reveal -s "${WIDTH}x${HEIGHT}" -p "$PAUSE" --load-pause "$LOAD_PAUSE")
case "$FRAGMENTS" in
  true|1|yes) args+=(--fragments) ;;
  *) ;;
esac
if [ -n "$PDF_TITLE" ]; then
  args+=(--pdf-title "$PDF_TITLE")
fi
if [ -n "$PDF_AUTHOR" ]; then
  args+=(--pdf-author "$PDF_AUTHOR")
fi

echo "DeckTape: $HTML -> $PDF (${WIDTH}x${HEIGHT}, fragments=$FRAGMENTS, pause=${PAUSE}ms, load-pause=${LOAD_PAUSE}ms)"
# The image's entrypoint already passes --chrome-path and --no-sandbox;
# HOME must be writable for Chromium under an arbitrary uid.
docker run --rm --network none -u "$WS_OWNER" -e HOME=/tmp \
  -v "$WORKSPACE:/data" -w /data \
  "$DECKTAPE_IMAGE" "${args[@]}" "$HTML" "$PDF"
own "$(dirname "$PDF")"

if ! python3 -c 'import pypdf' >/dev/null 2>&1; then
  echo "Installing pypdf==$PYPDF_VERSION"
  python3 -m pip install --user --quiet "pypdf==$PYPDF_VERSION"
fi

verify="$(python3 "$SCRIPT_DIR/verify.py" --pdf "$PDF" --expected-pages "$EXPECTED_PAGES" \
  --width "$WIDTH" --height "$HEIGHT")"
echo "$verify"
ls -la "$PDF"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "pdf=$PDF"
    echo "$verify" | grep -E '^pages='
  } >> "$GITHUB_OUTPUT"
fi
