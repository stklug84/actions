#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	basename
#	grep
#	jq
#	ls
#	tr
# @description:
#	Discover LaTeX document variants under a root directory and emit
#	a GitHub Actions matrix. Each variant subdirectory must contain
#	exactly one *.tex file with \documentclass; an optional .engine
#	dotfile selects the build engine (latexmk | pdflatex | xelatex |
#	latex-chain). Prints single-line JSON {"include":[...]} to
#	stdout for strategy.matrix via fromJson(); diagnostics go to
#	stderr so stdout stays machine-readable.
# @arguments:
#	<root>
#	[default-engine] (default: latexmk)
## Usage: scan.sh <root> [default-engine]
### Example: scan.sh cvs latexmk | jq .

set -euo pipefail

ROOT="${1:?root directory is required}"
DEFAULT_ENGINE="${2:-latexmk}"

err() { echo "::error::$*" >&2; }
log() { echo "$*" >&2; }

if [ ! -d "$ROOT" ] || [ -z "$(ls -A "$ROOT" 2>/dev/null || true)" ]; then
  err "No variants found. Expected directories under $ROOT/."
  exit 1
fi

entries=()
for dir in "$ROOT"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  name="$(basename "$dir")"

  # Find exactly one *.tex with \documentclass in the directory.
  # (while-read instead of mapfile for bash 3.2 / macOS portability)
  tex_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && tex_files+=("$f")
  done < <(grep -l '^[[:space:]]*\\documentclass' "$dir"/*.tex 2>/dev/null || true)
  if [ "${#tex_files[@]}" -eq 0 ]; then
    err "$dir contains no main .tex (file with \\documentclass)."
    exit 1
  fi
  if [ "${#tex_files[@]}" -gt 1 ]; then
    err "$dir contains multiple main .tex files: ${tex_files[*]}"
    exit 1
  fi
  tex="${tex_files[0]}"
  main="$(basename "$tex" .tex)"

  # Resolve engine from sibling .engine dotfile (default: DEFAULT_ENGINE).
  engine_file="$dir/.engine"
  if [ -f "$engine_file" ]; then
    engine="$(tr -d '[:space:]' < "$engine_file")"
  else
    engine="$DEFAULT_ENGINE"
  fi
  case "$engine" in
    latexmk|pdflatex|xelatex|latex-chain) ;;
    *) err "Unknown engine '$engine' in $engine_file"; exit 1 ;;
  esac

  # Auxiliary-tool detection, scoped to the variant's main .tex.
  has_bib="false"
  has_biblatex="false"
  has_index="false"
  has_glossaries="false"
  has_psfrag="false"
  if grep -Eq '\\bibliography\{' "$tex"; then has_bib="true"; fi
  if grep -Eq '\\usepackage(\[[^]]*\])?\{biblatex\}' "$tex"; then has_biblatex="true"; fi
  if grep -Eq '\\makeindex|\\printindex|\\usepackage(\[[^]]*\])?\{makeidx\}|\\usepackage(\[[^]]*\])?\{imakeidx\}' "$tex"; then
    has_index="true"
  fi
  if grep -Eq '\\usepackage(\[[^]]*\])?\{glossaries\}|\\makeglossaries' "$tex"; then has_glossaries="true"; fi
  if grep -Eq '\\usepackage(\[[^]]*\])?\{psfrag\}|\\psfrag\{' "$tex"; then has_psfrag="true"; fi

  entry="$(jq -cn \
    --arg name "$name" \
    --arg dir "$dir" \
    --arg main "$main" \
    --arg engine "$engine" \
    --arg has_bib "$has_bib" \
    --arg has_biblatex "$has_biblatex" \
    --arg has_index "$has_index" \
    --arg has_glossaries "$has_glossaries" \
    --arg has_psfrag "$has_psfrag" \
    '{name:$name, dir:$dir, main:$main, engine:$engine,
      has_bib:$has_bib, has_biblatex:$has_biblatex, has_index:$has_index,
      has_glossaries:$has_glossaries, has_psfrag:$has_psfrag}')"
  entries+=("$entry")

  log "  - $name  dir=$dir  main=$main.tex  engine=$engine"
done

if [ "${#entries[@]}" -eq 0 ]; then
  err "No variants discovered under $ROOT/."
  exit 1
fi

log "Discovered ${#entries[@]} variant(s)."

# Assemble {"include":[...]} as compact single-line JSON.
printf '%s\n' "${entries[@]}" | jq -cs '{include: .}'
