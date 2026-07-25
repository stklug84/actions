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

| Input            | Default     | Description                                                                                  |
|------------------|-------------|----------------------------------------------------------------------------------------------|
| `engine`         | `""`        | LaTeX toolchain (`latexmk`, `pdflatex`, `xelatex`, `latex-chain`). Empty → `default-engine`. |
| `default-engine` | `"latexmk"` | Engine used when `engine` is empty.                                                          |
| `local`          | `""`        | Local (gh act) mode. Empty → auto-detect via `ACT` env, else `false`.                        |
| `main-tex`       | `""`        | Main document basename without `.tex`. Empty → auto-detect via `\documentclass`.             |

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

## `texlive/discover-variants`

Scan a root directory for per-variant LaTeX documents — one subdirectory per
variant, each containing exactly one `*.tex` with `\documentclass` plus an
optional `.engine` dotfile (`latexmk` | `pdflatex` | `xelatex` |
`latex-chain`) — and emit a JSON `{"include":[...]}` matrix for
`strategy.matrix` via `fromJson()`. Each entry carries the variant's
auxiliary-tool flags and feeds `texlive/build-pdf` directly. The
multi-variant counterpart to `texlive/detect` (single root document).
Requires the repository to be checked out first (`actions/checkout`).

```yaml
- uses: actions/checkout@v6
- id: scan
  uses: stklug84/actions/texlive/discover-variants@v1
  with:
    root: cvs
    default-engine: latexmk
```

| Input            | Default     | Description                                             |
|------------------|-------------|---------------------------------------------------------|
| `root`           | —           | Directory with one subdirectory per variant. Required.  |
| `default-engine` | `"latexmk"` | Engine used when a variant has no `.engine` dotfile.    |

| Output   | Description                                                                                        |
|----------|----------------------------------------------------------------------------------------------------|
| `matrix` | `{"include":[...]}` JSON; entries carry `name`, `dir`, `main`, `engine`, and `has_*` flags.        |

## `texlive/build-pdf`

Unified TeX Live PDF build with engine dispatch — `latexmk`, `pdflatex`,
`xelatex`, or `latex-chain` (`latex` → `dvips` → `ps2pdf`, the only engine
that supports psfrag) — with bibliography (bibtex/biber), index (makeindex),
and glossaries (makeglossaries) handling and built-in PDF verification.
Supports out-of-root documents via `working-directory` and kpathsea
search-path injection via `texinputs`. Replaced the former
`texlive/build-pdflatex` and `texlive/build-latex-chain` actions (removed
in `v2`; the frozen `v1` line still ships them). Requires a TeX Live
toolchain on PATH (e.g. the `texlive/texlive` container) and a checked-out
workspace. Pair with `texlive/detect` or `texlive/discover-variants`.

```yaml
- uses: stklug84/actions/texlive/build-pdf@v1
  with:
    main: lebenslauf-sidebar
    engine: xelatex
    working-directory: cvs/sidebar
    texinputs: ".:../..:../../styles:../../images:"
    has-bib:        ${{ matrix.has_bib }}
    has-biblatex:   ${{ matrix.has_biblatex }}
    has-index:      ${{ matrix.has_index }}
    has-glossaries: ${{ matrix.has_glossaries }}
    has-psfrag:     ${{ matrix.has_psfrag }}
```

| Input               | Default   | Description                                                          |
|---------------------|-----------|----------------------------------------------------------------------|
| `main`              | —         | Main document basename without `.tex`. Required.                     |
| `engine`            | —         | `latexmk`, `pdflatex`, `xelatex`, or `latex-chain`. Required.        |
| `working-directory` | `"."`     | Directory to build in, relative to the workspace.                    |
| `texinputs`         | `""`      | Optional `TEXINPUTS` search path. Empty → environment untouched.     |
| `eps-from-pdf`      | `""`      | Newline list of PDFs converted to `.eps` (latex-chain only).         |
| `has-bib`           | `"false"` | Run BibTeX.                                                          |
| `has-biblatex`      | `"false"` | Run biber (takes precedence over `has-bib`).                         |
| `has-index`         | `"false"` | Run makeindex when an `.idx` file is produced.                       |
| `has-glossaries`    | `"false"` | Run makeglossaries.                                                  |
| `has-psfrag`        | `"false"` | `true` → hard error for `pdflatex`/`xelatex` (need `latex-chain`).   |

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

## `cv/parse`

Parse a canonical, bilingual (`de`/`en`) `cv.yml` — the single source of
truth — and emit consumer-specific outputs. In **`latex`** mode it writes
one `.tex` file per section for a selected `style` (`plain` |
`sidebar`) and `lang` (`de` | `en`), filtered to entries whose `targets`
contains `latex` or the `target-style` manifest style name. In **`web`**
mode it writes a single `cv.yml` in skcloud's exact schema (English,
filtered to entries whose `targets` contains `web`). A `check` mode
validates the schema and writes nothing, exiting nonzero with a clear
message on the first violation. Validation is **style-dependent and per
entry**: `style` selects one of two schema profiles — `plain`
(plain/sidebar/pw/dh/vs/fs: bilingual `certifications[].text` and
plain-string `skills[].items`; tagged-only fields rejected) or `tagged`
(structured certifications, `{name, size}` skill items, and the optional
`concepts[]` / `interests[].icon` / `conferences[].lat`/`lon`) — applied
to the entries the selected target consumes.
`meta.pdf_title` is accepted by both; `web` mode always validates against
the `tagged` profile. Implemented in Python 3 (PyYAML + Jinja2, installed
by the wrapper at pinned versions); a thin bash step drives it. Requires
the repository to be checked out first (`actions/checkout`).

**Merged multi-style sources.** One source can feed several presentation
styles with per-entry selection: pass `valid-targets` (comma-separated
manifest style names, e.g. `cv-plain-style,cv-tagged-ia`) to register the
style names as accepted `targets` tokens, and `target-style` to select the
entries for the style being emitted/checked (matching entries name the
style or the generic `latex`). An optional top-level `overrides.<style>`
block carries per-style `meta`/`contact` deltas (deep-merged over the base
for that style), and a gitignored sibling `<source-stem>.local.yml`
overlay (e.g. `data/cv.local.yml`) is deep-merged over the source when
present — the designated home for local-only PII fields. `id` uniqueness
is scoped per selected style; `targets` tokens are validated on the
unfiltered document so typo'd style names fail loudly.

```yaml
# LaTeX: per-section .tex files (sidebar style, German).
- uses: actions/checkout@v6
- uses: stklug84/actions/cv/parse@v2
  with:
    source: data/cv.yml
    mode: latex
    style: sidebar
    lang: de
    out-dir: build/tex
```

```yaml
# Web: a single cv.yml in skcloud's schema (English).
- uses: actions/checkout@v6
- uses: stklug84/actions/cv/parse@v2
  with:
    source: data/cv.yml
    mode: web
    out-dir: _data
```

```yaml
# Validate only — write nothing, fail on the first schema violation.
# `style` selects the schema profile (default plain); pass the style the
# source is authored for (e.g. tagged for a tagged-shaped cv.yml).
- uses: actions/checkout@v6
- uses: stklug84/actions/cv/parse@v2
  with:
    source: data/cv.yml
    style: tagged
    check: "true"
    out-dir: build/tex   # required by the schema but unused for check
```

| Input     | Default        | Description                                                       |
|-----------|----------------|-------------------------------------------------------------------|
| `source`  | `data/cv.yml`  | Path to the canonical bilingual `cv.yml`.                         |
| `mode`    | `latex`        | Output mode — `latex` or `web`.                                   |
| `style`   | `plain`        | LaTeX style (latex mode only) — `plain`, `sidebar`, or an example-CV style `pw`/`dh`/`vs`/`fs`/`ia`. |
| `target-style` | `""`      | Manifest style name (e.g. `cv-tagged-ia`) selecting entries whose `targets` name this style (besides `latex`) and the matching `overrides.<style>` block. Empty → single-style behaviour. |
| `valid-targets` | `""`     | Comma-separated extra `targets` tokens to accept (typically every manifest style name). Empty → only `latex` and `web`. |
| `lang`    | `de`           | Language — `de` or `en` (latex mode; web is always English).      |
| `out-dir` | —              | Directory the generated files are written into. Required.         |
| `check`   | `"false"`      | `true` → validate the schema (under the `style` profile, scoped to the `target-style` selection) and write nothing (fails on error). |

Outputs are written as files into `out-dir` (the action sets no step
outputs):

- **`latex` mode** writes eight per-section files: `personal-info.tex`,
  `cv-experience.tex`, `cv-education.tex`, `cv-conferences.tex`,
  `cv-skills.tex`, `cv-languages.tex`, `cv-interests.tex`, and
  `cv-certifications.tex`.
- **`web` mode** writes a single `cv.yml`.

In `plain` style the section files emit `longtable` **row bodies** only
(the consuming document keeps `\subsection*` + `\begin{longtable}{...}`
and `\input{...}`s the section file). In `sidebar` style they emit calls
against the `cv-sidebar.sty` public API (`\cventry`, `\cvsubentry`,
`\cvskillgroup`, `\cvlanguage`, `\cvchip`, `\cvsidelist`).

The example-CV styles `pw`, `dh`, `vs`, `fs`, and `ia` reproduce the
visual language of the example résumés in the `curriculum-vitae` repo
(`styles/cv-{sidebar-pw,sidebar-dh,sidebar-vs,banking-fs,tagged-ia}.sty`).
They all share the same public macro API as `sidebar`, so `pw`/`dh`/`vs`
reuse the `sidebar` templates verbatim (see `STYLE_TEMPLATE_DIRS` in
`scripts/parse.py`); the single-column `fs` and `ia` render from their own
`templates/{fs,ia}/` directories to allow future divergence.

The `ia` (`tagged`) style consumes a richer schema than the others:
`{name, size}` skill items (proficiency bars), structured
`certifications[]` (`code`, `name`, optional `issuer`), and the optional
`concepts[]`, `interests[].icon` and `conferences[].lat`/`lon` fields. The
plain-profile styles instead expect plain-string `skills[].items` and
bilingual `certifications[].text`, and reject the tagged-only fields. The
emitter normalizes plain-string skill items internally, so authoring a
source under the wrong profile is caught by `check` rather than producing
malformed output. See `cv/parse/DECISIONS.md` for the full profile
contract.

## `python/lint`

Lint Python sources with a pinned [Ruff](https://docs.astral.sh/ruff/) release:
`ruff check` plus an optional `ruff format --check`. A Ruff configuration file
(ruff.toml or a pyproject.toml) may be passed explicitly; left empty, Ruff's
own configuration auto-discovery applies. Requires the repository to be
checked out first (`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/python/lint@v2
  with:
    paths: "src tests"       # optional; default "."
    config: pyproject.toml   # optional; empty → auto-discovery
```

| Input          | Default    | Description                                                    |
|----------------|------------|----------------------------------------------------------------|
| `paths`        | `"."`      | Space-separated files/directories to lint.                     |
| `ruff-version` | `"0.16.0"` | Ruff release to install (pinned).                              |
| `config`       | `""`       | Ruff config file (`--config`). Empty → auto-discovery.         |
| `check-format` | `"true"`   | Also run `ruff format --check`.                                |

## `python/typecheck`

Type-check Python sources with a pinned [mypy](https://mypy-lang.org/)
release, strict by default. When a configuration file governs the strictness
settings, set `strict: "false"` and pass the file via `config`. Third-party
imports and type stubs the checked code needs can be installed via
`extra-deps`. Requires the repository to be checked out first
(`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/python/typecheck@v2
  with:
    paths: "scripts/parse.py"          # optional; default "."
    extra-deps: "types-PyYAML Jinja2"  # optional stub/import deps
```

| Input          | Default    | Description                                                     |
|----------------|------------|------------------------------------------------------------------|
| `paths`        | `"."`      | Space-separated files/directories to type-check.                |
| `mypy-version` | `"1.19.0"` | mypy release to install (pinned).                               |
| `strict`       | `"true"`   | Pass `--strict`. Set `"false"` when a config file governs it.   |
| `config`       | `""`       | mypy config file (`--config-file`). Empty → auto-discovery.     |
| `extra-deps`   | `""`       | Space-separated pip packages (type stubs / imports).            |

## `python/security`

Scan Python sources recursively with a pinned
[Bandit](https://bandit.readthedocs.io/) release (`bandit -r`, installed with
the `toml` extra so `[tool.bandit]` tables in a pyproject.toml are read). The
default thresholds report every finding; raise `severity`/`confidence` to
`medium`/`high` to reduce noise. Requires the repository to be checked out
first (`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/python/security@v2
  with:
    paths: "scripts"         # optional; default "."
    config: pyproject.toml   # optional; passed via -c
```

| Input            | Default   | Description                                                    |
|------------------|-----------|----------------------------------------------------------------|
| `paths`          | `"."`     | Space-separated files/directories to scan.                     |
| `bandit-version` | `"1.8.0"` | Bandit release to install (pinned, `bandit[toml]`).            |
| `config`         | `""`      | Bandit config file (`-c`). Empty → flag omitted.               |
| `severity`       | `"low"`   | Minimum severity reported (`--severity-level`).                |
| `confidence`     | `"low"`   | Minimum confidence reported (`--confidence-level`).            |

## `rdf/validate-turtle`

Validate Turtle/RDF syntax with `riot --validate` from a pinned
[Apache Jena](https://jena.apache.org/) release (downloaded from Maven
Central, where version-pinned artifacts are hosted permanently). Every file
matching the glob pattern(s) is validated; `OK`/`FAIL` is printed per file
and the action fails when any file is invalid or no file matches. Requires
the repository to be checked out first (`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/rdf/validate-turtle@v2
  with:
    glob: "**/*.ttl"   # optional; space-separated patterns
```

| Input          | Default      | Description                                                       |
|----------------|--------------|--------------------------------------------------------------------|
| `glob`         | `"**/*.ttl"` | Space-separated find-style glob pattern(s) selecting the files.   |
| `jena-version` | `"5.4.0"`    | Apache Jena release to install (pinned).                          |
| `java-version` | `"21"`       | JDK version for `actions/setup-java`.                             |

## `rdf/validate-sparql`

Validate SPARQL query files by parsing them with
[rdflib](https://rdflib.readthedocs.io/)'s `prepareQuery`. Every file
matching the glob pattern(s) is parsed; `OK`/`FAIL` is printed per file and
the action fails when any file is invalid or no file matches. Covers the
SPARQL 1.1 *Query* grammar only (SELECT / CONSTRUCT / ASK / DESCRIBE);
*Update* requests are reported as syntax errors. Requires the repository to
be checked out first (`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/rdf/validate-sparql@v2
  with:
    glob: "**/*.rq"   # optional; space-separated patterns
```

| Input            | Default     | Description                                                      |
|------------------|-------------|-------------------------------------------------------------------|
| `glob`           | `"**/*.rq"` | Space-separated pathlib-style glob pattern(s) selecting files.   |
| `python-version` | `"3.12"`    | Python version for `actions/setup-python`.                       |
| `rdflib-version` | `">=7,<8"`  | PEP 440 specifier appended to `rdflib` for pip.                  |

## `rdf/reason-owl`

Check OWL ontologies for logical consistency and coherence (unsatisfiable
classes) with [ROBOT](https://robot.obolibrary.org/)'s `reason` command and a
pinned `robot.jar`. Each file is reasoned independently; `OK`/`FAIL` is
printed per file and the action fails when any file does not pass. Requires
the repository to be checked out first (`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/rdf/reason-owl@v2
  with:
    files: "ontology/core.owl ontology/ext.owl"
    reasoner: hermit   # optional
```

| Input           | Default    | Description                                                      |
|-----------------|------------|-------------------------------------------------------------------|
| `files`         | —          | Space-separated ontology files to reason over. Required.         |
| `reasoner`      | `"hermit"` | `hermit`, `elk`, `whelk`, `jfact`, or `structural`.              |
| `robot-version` | `"1.9.8"`  | ROBOT release to install (pinned `robot.jar`).                   |
| `java-version`  | `"21"`     | JDK version for `actions/setup-java`.                            |

## `rdf/generate-individuals`

Run a repository-local RDF instance-graph generation pipeline with pinned
Python + [rdflib](https://rdflib.readthedocs.io/) and a cached remote API
response directory (`actions/cache`, keyed on the generator's source
inventory). Drives the three generator stages `fetch` → `generate` →
`collection` via `python3 <generator> <stage>`; optional prepare/finalize
shell commands bracket the pipeline for repo-specific extract and
post-processing steps. Requires the repository to be checked out first
(`actions/checkout`).

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/rdf/generate-individuals@v2
  with:
    prepare-command: python3 scripts/build_vocab.py
    finalize-command: python3 scripts/update_imports.py
```

| Input              | Default                                | Description                                          |
|--------------------|----------------------------------------|------------------------------------------------------|
| `generator`        | `"scripts/generate_individuals.py"`    | Generator script, run as `python3 <generator> <stage>`. |
| `prepare-command`  | `""`                                   | Shell command before `fetch`; empty skips.           |
| `finalize-command` | `""`                                   | Shell command after `collection`; empty skips.       |
| `python-version`   | `"3.12"`                               | Python version for `actions/setup-python`.           |
| `rdflib-version`   | `">=7,<8"`                             | PEP 440 specifier for pip; empty skips the install.  |
| `cache-dir`        | `"/tmp/scryfall_cache"`                | API response cache directory (saved/restored).       |
| `cache-key`        | `"scryfall-cache"`                     | Cache key prefix.                                    |
| `cache-hash-files` | `"collection.csv"`                     | `hashFiles` pattern(s) mixed into the cache key.     |
| `run-fetch`        | `"true"`                               | Run the `fetch` stage.                               |
| `run-generate`     | `"true"`                               | Run the `generate` stage.                            |
| `run-collection`   | `"true"`                               | Run the `collection` stage.                          |

## Linting

Pull requests against `main` run the `Lint` workflow
(`.github/workflows/lint.yml`):

- **actionlint** — validates `.github/workflows/*` (including shellcheck on
  workflow `run:` steps).
- **shellcheck** — checks the bash `run:` blocks inside the composite
  `action.yml` files via `scripts/shellcheck-actions.sh` (actionlint does not
  cover composite actions). Rules: `.shellcheckrc`.
- **yamllint** — lints all YAML files. Rules: `.yamllint.yml`.
- **markdownlint** — lints all Markdown files. Rules: `.markdownlint.yml`.
- **python-lint** — `ruff` (lint + format check), `mypy` (strict type
  check), and `bandit` (security; confirms `yaml.safe_load`) on the
  `cv/parse` Python emitter, plus its golden tests. Config:
  `cv/parse/pyproject.toml`.

Run locally (requires `shellcheck`, `yq`, `yamllint`, `actionlint`, `npx`):

```bash
actionlint
scripts/shellcheck-actions.sh
yamllint --strict .
npx markdownlint-cli2 --config .markdownlint.yml '**/*.md'
```

For the `cv/parse` Python (requires `ruff`, `mypy`, `bandit`; install
with `pip install --user ruff==0.8.6 mypy==1.14.1 bandit==1.8.0
PyYAML==6.0.2 Jinja2==3.1.5 types-PyYAML==6.0.12.20241230`):

```bash
cd cv/parse
ruff check .
ruff format --check .
mypy scripts/parse.py
bandit -r scripts -q
bash test/run-tests.sh
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repository
conventions, and how to run the lint checks locally.

## Versioning

Releases are tagged `vX.Y.Z` with a moving major alias (`vX`). Pin to the major
alias (`@v2`) for automatic patch/minor updates, or to an exact tag for
immutability.

Current major: `v2` (removed the deprecated `texlive/build-pdflatex` and
`texlive/build-latex-chain` actions; use `texlive/build-pdf` with the
`engine` input instead). The `v1` alias is frozen at `v1.3.0` and still
ships the removed actions.
