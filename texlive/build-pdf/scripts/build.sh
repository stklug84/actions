#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	latexmk | pdflatex | xelatex | latex (per ENGINE)
#	biber | bibtex (if HAS_BIBLATEX / HAS_BIB)
#	makeindex (if HAS_INDEX)
#	makeglossaries (if HAS_GLOSSARIES)
#	dvips, ps2pdf, gs (if ENGINE=latex-chain)
# @description:
#	Compile a LaTeX document to PDF. Driven entirely by environment
#	variables set in action.yml: ENGINE selects the build engine
#	(latexmk | pdflatex | xelatex | latex-chain), MAIN names the
#	main .tex basename without extension, TEXINPUTS_IN optionally
#	extends the kpathsea search path, EPS_FROM_PDF optionally lists
#	PDF graphics converted to .eps siblings for the DVI-mode
#	latex-chain engine, and the flags HAS_BIB, HAS_BIBLATEX,
#	HAS_INDEX, HAS_GLOSSARIES, and HAS_PSFRAG ('true'/'false')
#	enable the matching auxiliary tools. Must run inside the
#	document directory; action.yml sets working-directory.
# @arguments:
#	none (configured via environment variables, see @description)
## Usage: ENGINE=<engine> MAIN=<basename> [TEXINPUTS_IN=<path>] [EPS_FROM_PDF=<paths>] [HAS_*=true|false] build.sh
### Example: ENGINE=xelatex MAIN=lebenslauf-sidebar build.sh

set -euo pipefail

: "${ENGINE:?ENGINE is required}"
: "${MAIN:?MAIN is required}"
HAS_BIB="${HAS_BIB:-false}"
HAS_BIBLATEX="${HAS_BIBLATEX:-false}"
HAS_INDEX="${HAS_INDEX:-false}"
HAS_GLOSSARIES="${HAS_GLOSSARIES:-false}"
HAS_PSFRAG="${HAS_PSFRAG:-false}"

# Optional kpathsea search path (empty input leaves the env untouched).
if [ -n "${TEXINPUTS_IN:-}" ]; then
  export TEXINPUTS="$TEXINPUTS_IN"
fi

# Derive .eps siblings for DVI-mode graphics. graphicx + dvips cannot
# embed PDF graphics: the dvips driver resolves extension-less
# \includegraphics arguments to .eps, so each PDF listed in
# EPS_FROM_PDF (newline-separated, relative to the working directory)
# is converted next to its source (ghostscript ships with TeX Live; it
# powers ps2pdf). Only relevant for latex-chain; the PDF-mode engines
# embed the .pdf directly and ignore the derived .eps.
if [ "$ENGINE" = "latex-chain" ] && [ -n "${EPS_FROM_PDF:-}" ]; then
  while IFS= read -r pdf; do
    pdf="$(echo "$pdf" | xargs)"   # trim
    [ -z "$pdf" ] && continue
    if [ ! -f "$pdf" ]; then
      echo "::error::eps-from-pdf: $pdf not found."
      exit 1
    fi
    eps="${pdf%.pdf}.eps"
    gs -dNOPAUSE -dBATCH -dSAFER -dEPSCrop \
       -sDEVICE=eps2write -sOutputFile="$eps" "$pdf"
    echo "Derived $eps from $pdf"
  done <<< "$EPS_FROM_PDF"
fi

psfrag_unsupported() {
  echo "::error::psfrag detected. $1 cannot perform psfrag substitutions."
  echo "::error::psfrag requires the classic latex -> dvips -> ps2pdf chain;"
  echo "::error::use engine 'latex-chain' for this document."
  exit 1
}

# ---------------------------------------------------------------------
# latexmk: self-contained driver, handles aux tools and reruns itself.
# ---------------------------------------------------------------------
if [ "$ENGINE" = "latexmk" ]; then
  latexmk -pdf \
          -interaction=nonstopmode -halt-on-error -file-line-error \
          -g "$MAIN.tex"
  exit 0
fi

# ---------------------------------------------------------------------
# Manual multi-pass chain for pdflatex | xelatex | latex-chain.
# ---------------------------------------------------------------------
case "$ENGINE" in
  pdflatex)
    LATEX_CMD="pdflatex"
    [ "$HAS_PSFRAG" = "true" ] && psfrag_unsupported "pdflatex"
    ;;
  xelatex)
    LATEX_CMD="xelatex"
    [ "$HAS_PSFRAG" = "true" ] && psfrag_unsupported "xelatex"
    ;;
  latex-chain)
    LATEX_CMD="latex"
    if [ "$HAS_BIBLATEX" = "true" ]; then
      echo "::warning::biblatex detected; using biber. Ensure backend=biber in your preamble."
    fi
    ;;
  *)
    echo "::error::Unknown engine '$ENGINE'. Use latexmk, pdflatex, xelatex, or latex-chain."
    exit 1
    ;;
esac

# Pass 1.
"$LATEX_CMD" -interaction=nonstopmode -halt-on-error "$MAIN.tex"

# Bibliography: tolerate "no citations" warnings (exit 1) but fail on
# real errors (>=2).
if [ "$HAS_BIBLATEX" = "true" ]; then
  biber "$MAIN" || { rc=$?; [ "$rc" -ge 2 ] && exit "$rc"; }
elif [ "$HAS_BIB" = "true" ]; then
  bibtex "$MAIN" || { rc=$?; [ "$rc" -ge 2 ] && exit "$rc"; }
fi

# Index.
if [ "$HAS_INDEX" = "true" ] && [ -f "$MAIN.idx" ]; then
  makeindex "$MAIN.idx"
fi

# Glossaries: tolerate missing glossary files but surface real failures.
if [ "$HAS_GLOSSARIES" = "true" ]; then
  makeglossaries "$MAIN" || { rc=$?; [ "$rc" -ge 2 ] && exit "$rc"; }
fi

# Pass 2 + 3 to resolve refs / TOC / index / bibliography.
"$LATEX_CMD" -interaction=nonstopmode -halt-on-error "$MAIN.tex"
"$LATEX_CMD" -interaction=nonstopmode -halt-on-error "$MAIN.tex"

# latex-chain only: convert DVI -> PS (where psfrag substitutions are
# performed) -> PDF.
if [ "$ENGINE" = "latex-chain" ]; then
  dvips -Ppdf -G0 -o "$MAIN.ps" "$MAIN.dvi"
  ps2pdf -dPDFSETTINGS=/prepress "$MAIN.ps" "$MAIN.pdf"
  if [ "$HAS_PSFRAG" = "true" ]; then
    echo "psfrag substitutions were processed by dvips."
  fi
fi
