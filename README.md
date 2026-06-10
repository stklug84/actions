# actions

[![Lint](https://github.com/stklug84/actions/actions/workflows/lint.yml/badge.svg)](https://github.com/stklug84/actions/actions/workflows/lint.yml)
[![CodeQL](https://github.com/stklug84/actions/actions/workflows/codeql.yml/badge.svg)](https://github.com/stklug84/actions/actions/workflows/codeql.yml)

Central, reusable **composite actions** for this account. Unlike reusable
workflows (which must live flat in `.github/workflows/`), composite actions can
be grouped into subdirectories — so they are organized here by domain.

## `ruby/setup-ruby-bundler`

Install Ruby and bootstrap Bundler with caching (wraps `ruby/setup-ruby`).

```yaml
- uses: stklug84/actions/ruby/setup-ruby-bundler@v1
  with:
    ruby-version: ""        # optional; empty → resolve from .ruby-version / Gemfile
    bundler-cache: "true"   # optional
```

| Input           | Default | Description                                                       |
|-----------------|---------|-------------------------------------------------------------------|
| `ruby-version`  | `""`    | Ruby version. Empty → resolve from `.ruby-version`/`Gemfile`.     |
| `bundler-cache` | `"true"`| Enable Bundler caching.                                           |

## `jekyll/jekyll-build`

Build a Jekyll site with Bundler (`bundle exec jekyll build`). Requires Ruby +
Bundler to be set up first (use `ruby/setup-ruby-bundler`).

```yaml
- uses: stklug84/actions/jekyll/jekyll-build@v1
  with:
    source: "./"
    destination: "./_site"
    baseurl: ${{ steps.pages.outputs.base_path }}   # optional
```

| Input               | Default       | Description                                                  |
|---------------------|---------------|--------------------------------------------------------------|
| `source`            | `./`          | Jekyll source directory.                                     |
| `destination`       | `./_site`     | Build output directory.                                      |
| `baseurl`           | `""`          | Optional `--baseurl`. Empty → flag omitted.                  |
| `jekyll-env`        | `production`  | Value for `JEKYLL_ENV`.                                      |
| `working-directory` | `.`           | Directory to run the build from.                             |

## `texlive/detect`

Detect TeX Live build configuration: resolve engine / local-mode / main-document
inputs and scan the main `.tex` for auxiliary toolchain requirements
(bibtex/biblatex, makeindex, glossaries, psfrag). Requires the repository to be
checked out first (`actions/checkout`).

```yaml
- uses: actions/checkout@v6
- id: detect
  uses: stklug84/actions/texlive/detect@v1
  with:
    engine: ""     # optional; empty → default-engine
    local: ""      # optional; empty → auto-detect via ACT env
    main-tex: ""   # optional; empty → auto-detect via \documentclass
```

| Input            | Default     | Description                                                                       |
|------------------|-------------|-----------------------------------------------------------------------------------|
| `engine`         | `""`        | LaTeX toolchain (`latexmk`, `pdflatex`, `latex-chain`). Empty → `default-engine`. |
| `default-engine` | `"latexmk"` | Engine used when `engine` is empty.                                               |
| `local`          | `""`        | Local (gh act) mode. Empty → auto-detect via `ACT` env, else `false`.             |
| `main-tex`       | `""`        | Main document basename without `.tex`. Empty → auto-detect via `\documentclass`.  |

| Output           | Description                                              |
|------------------|----------------------------------------------------------|
| `main`           | Main document basename (without `.tex`).                 |
| `local`          | Whether the run is in local (gh act) mode.               |
| `engine`         | Resolved LaTeX toolchain.                                |
| `has_bib`        | Main `.tex` uses BibTeX (`\bibliography{...}`).          |
| `has_biblatex`   | Main `.tex` loads biblatex (biber backend).              |
| `has_index`      | Main `.tex` builds an index (makeindex).                 |
| `has_glossaries` | Main `.tex` uses glossaries (makeglossaries).            |
| `has_psfrag`     | Main `.tex` uses psfrag (latex-chain only).              |

## `texlive/build-pdflatex`

Three-pass pdflatex PDF build with bibliography (bibtex/biber), index
(makeindex), and glossaries (makeglossaries) handling. Fails fast when psfrag
is required (psfrag needs `texlive/build-latex-chain`). Requires a TeX Live
toolchain on PATH (e.g. the `texlive/texlive` container) and a checked-out
workspace. Pair with `texlive/detect`.

```yaml
- uses: stklug84/actions/texlive/build-pdflatex@v1
  with:
    main: book
    has-bib:        ${{ needs.detect.outputs.has_bib }}
    has-biblatex:   ${{ needs.detect.outputs.has_biblatex }}
    has-index:      ${{ needs.detect.outputs.has_index }}
    has-glossaries: ${{ needs.detect.outputs.has_glossaries }}
    has-psfrag:     ${{ needs.detect.outputs.has_psfrag }}
```

| Input            | Default   | Description                                                  |
|------------------|-----------|--------------------------------------------------------------|
| `main`           | —         | Main document basename without `.tex`. Required.             |
| `has-bib`        | `"false"` | Run BibTeX.                                                  |
| `has-biblatex`   | `"false"` | Run biber (takes precedence over `has-bib`).                 |
| `has-index`      | `"false"` | Run makeindex when an `.idx` file is produced.               |
| `has-glossaries` | `"false"` | Run makeglossaries.                                          |
| `has-psfrag`     | `"false"` | `true` → hard error (pdflatex cannot process psfrag).        |

## `texlive/build-latex-chain`

Three-pass latex PDF build followed by `dvips -Ppdf -G0` and
`ps2pdf -dPDFSETTINGS=/prepress`, with the same bibliography / index /
glossaries handling as `texlive/build-pdflatex`. The only engine that supports
psfrag substitutions (performed by dvips). Same inputs as
`texlive/build-pdflatex`; `has-psfrag` is informational only.

```yaml
- uses: stklug84/actions/texlive/build-latex-chain@v1
  with:
    main: book
    has-glossaries: "true"
```

## `texlive/build-epub`

Build an EPUB 3 with tex4ebook: installs poppler-utils/zip tools, optionally
stages TeX Live-shipped OTF fonts (via kpsewhich) plus a license file,
optionally rasterizes a PDF to PNG, writes `.xbb` bounding-box sidecars for
**every** png/jpg/jpeg under `images-dir` (DVI-mode htlatex cannot measure
raster images natively), runs tex4ebook, and patches the result (assets
injected under `OEBPS/`, OPF manifest entries generated dynamically, empty
`<title>` elements backfilled, EPUB rebuilt with the mandated zip layout).

```yaml
- uses: stklug84/actions/texlive/build-epub@v1
  with:
    main: book
    config: config/ebook.cfg
    build-file: config/ebook.mk4
    rasterize-pdf: images/map.pdf
    fonts: |
      EBGaramond-Regular.otf
      EBGaramond-Italic.otf
      EBGaramond-Bold.otf
      EBGaramond-BoldItalic.otf
    font-license: config/OFL-EBGaramond.txt
    stylesheet: config/ebook.css
    book-title: "The Ember Crown"
```

| Input           | Default            | Description                                                  |
|-----------------|--------------------|--------------------------------------------------------------|
| `main`          | —                  | Main document basename without `.tex`. Required.             |
| `config`        | `config/ebook.cfg` | tex4ht config (`--config`). Empty → omitted.                 |
| `build-file`    | `config/ebook.mk4` | make4ht build file (`--build-file`). Empty → omitted.        |
| `format`        | `epub3`            | tex4ebook output format.                                     |
| `images-dir`    | `images`           | Directory scanned for raster images (extractbb sidecars).    |
| `rasterize-pdf` | `""`               | PDF rasterized to a sibling PNG before the build.            |
| `rasterize-dpi` | `300`              | Rasterization resolution.                                    |
| `fonts`         | `""`               | Newline list of TeX Live OTF names staged via kpsewhich.     |
| `font-license`  | `""`               | License text bundled as `OFL.txt` next to the fonts.         |
| `fonts-dir`     | `fonts`            | Workspace staging directory for the fonts.                   |
| `stylesheet`    | `""`               | CSS injected under `OEBPS/` and declared in the manifest.    |
| `book-title`    | `""`               | Backfill for empty `<title>` elements (epubcheck RSC-005).   |

## `texlive/validate-epub`

Validate an EPUB with a pinned epubcheck release (installing a headless JRE),
then strip build by-products from the workspace via `git clean -fdx` while
preserving the build outputs. Cleanup only runs after a successful validation,
so failures leave the workspace intact for log collection (e.g. via
`texlive/upload-build-logs`).

```yaml
- uses: stklug84/actions/texlive/validate-epub@v1
  with:
    main: book
    filter-file: config/epubcheck-filter.txt
```

| Input               | Default   | Description                                                            |
|---------------------|-----------|------------------------------------------------------------------------|
| `main`              | —         | Main document basename without `.epub`. Required.                      |
| `epubcheck-version` | `"5.1.0"` | epubcheck release to install.                                          |
| `filter-file`       | `""`      | Optional `--customMessages` file (applied when it exists).             |
| `clean`             | `"true"`  | Clean the workspace after successful validation.                       |
| `keep`              | `""`      | Newline list of files preserved. Empty → `<main>.epub` + `<main>.pdf`. |

## `texlive/upload-build-logs`

Upload matching log files as a workflow artifact. Intended for `if: failure()`
steps so log archives are produced only on failed runs. Missing files are
silently skipped.

```yaml
- name: Upload build logs on failure
  if: failure()
  uses: stklug84/actions/texlive/upload-build-logs@v1
  with:
    artifact-name: build-logs
    paths: |
      *.log
      *.blg
```

| Input           | Default | Description                                       |
|-----------------|---------|---------------------------------------------------|
| `artifact-name` | —       | Name of the artifact to upload. Required.         |
| `paths`         | —       | Newline-separated glob list of files. Required.   |

## Linting

Pull requests against `main` run the `Lint` workflow
(`.github/workflows/lint.yml`):

- **actionlint** — validates `.github/workflows/*` (including shellcheck on
  workflow `run:` steps).
- **shellcheck** — checks the bash `run:` blocks inside the composite
  `action.yml` files via `scripts/shellcheck-actions.sh` (actionlint does not
  cover composite actions). Rules: `.shellcheckrc`.
- **yamllint** — lints all YAML files. Rules: `.yamllint.yml`.
- **markdownlint** — lints all Markdown files. Rules: `.markdownlint.yaml`.

Run locally (requires `shellcheck`, `yq`, `yamllint`, `actionlint`, `npx`):

```bash
actionlint
scripts/shellcheck-actions.sh
yamllint --strict .
npx markdownlint-cli2 --config .markdownlint.yaml '**/*.md'
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repository
conventions, and how to run the lint checks locally.

## Versioning

Releases are tagged `vX.Y.Z` with a moving major alias (`vX`). Pin to the major
alias (`@v1`) for automatic patch/minor updates, or to an exact tag for
immutability.
