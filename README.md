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
    reasoner: hermit               # optional
    catalog: catalog-v001.xml      # optional import mapping
```

| Input           | Default    | Description                                                      |
|-----------------|------------|-------------------------------------------------------------------|
| `files`         | —          | Space-separated ontology files to reason over. Required.         |
| `reasoner`      | `"hermit"` | `hermit`, `elk`, `whelk`, `jfact`, or `structural`.              |
| `catalog`       | `""`       | Optional OASIS XML catalog for `robot --catalog`, mapping `owl:imports` IRIs (e.g. `urn:`) to local files. Empty disables the flag. |
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

## `mtg/fetch-comprehensive-rules`

Download a pinned edition of the Magic: The Gathering Comprehensive Rules
text from Wizards of the Coast. The text is **not redistributable**, so it
can never be committed — every consumer has to fetch it at run time. This
action single-sources the edition date and the URL shape, and caches the
download (the edition is immutable, so a cache hit is always valid).

The file is written as `MagicCompRules-<cr-date>.txt` inside `dest`, which
is the name the rules engine discovers. The URL year is derived from
`cr-date`, so only one value ever needs updating.

```yaml
- uses: actions/checkout@v7
- uses: stklug84/actions/mtg/fetch-comprehensive-rules@v2
  with:
    cr-date: "20260619"
    dest: "."          # optional; directory to write into
```

| Input     | Default  | Description                                                          |
|-----------|----------|-----------------------------------------------------------------------|
| `cr-date` | —        | Edition, as the `YYYYMMDD` date Wizards publishes under. Required.   |
| `dest`    | `"."`    | Directory the text is written into; created when missing.            |
| `cache`   | `"true"` | Restore/save the download via `actions/cache`.                       |

| Output | Description                        |
|--------|------------------------------------|
| `path` | Path of the downloaded rules text. |

## `revealjs/resolve-images`

Extract the digest-pinned **pandoc**, **mermaid-cli** and **DeckTape** image
references from a pin-only, multi-stage Dockerfile — one named stage per
tool, never built. The file exists so Dependabot's docker ecosystem keeps
all three digests current and hadolint lints a single file (the same
mechanism as the TeX Live pin consumed by `latex-build-cv`). The resolver
is strict: every stage must appear exactly once, every reference must be
digest-pinned, and only `FROM … AS …` lines (plus comments) are allowed.
Requires the repository to be checked out first (`actions/checkout`).

```dockerfile
# .github/docker/revealjs/Dockerfile
FROM pandoc/core:3.11.0.0-alpine@sha256:…          AS pandoc
FROM minlag/mermaid-cli:11.17.0@sha256:…           AS mermaid
FROM ghcr.io/astefanutti/decktape:3.16.1@sha256:…  AS decktape
```

```yaml
- uses: actions/checkout@v7
- id: images
  uses: stklug84/actions/revealjs/resolve-images@v2
  with:
    dockerfile: .github/docker/revealjs/Dockerfile
```

| Input        | Default                              | Description                                        |
|--------------|--------------------------------------|----------------------------------------------------|
| `dockerfile` | `.github/docker/revealjs/Dockerfile` | Pin-only multi-stage Dockerfile in the workspace.  |
| `stages`     | `pandoc mermaid decktape`            | Space-separated stage names that must be present.  |

| Output           | Description                                       |
|------------------|---------------------------------------------------|
| `pandoc-image`   | Digest-pinned pandoc reference (stage `pandoc`).  |
| `mermaid-image`  | Digest-pinned mermaid-cli reference (`mermaid`).  |
| `decktape-image` | Digest-pinned DeckTape reference (`decktape`).    |

## `revealjs/discover-decks`

Scan a root directory recursively for Markdown slide decks — every
directory holding a `slides.md` (configurable) is a deck — and emit a JSON
`{"include":[...]}` matrix for `strategy.matrix` via `fromJson()`. The deck
`name` is the directory path relative to `root` with `/` replaced by `-`
(unique for nested layouts, basename for direct children), restricted to
`[A-Za-z0-9._-]` because it becomes the artifact and output file name. An
empty root yields an empty matrix. The Markdown counterpart to
`texlive/discover-variants`. Requires a checked-out repository.

```yaml
- uses: actions/checkout@v7
- id: scan
  uses: stklug84/actions/revealjs/discover-decks@v2
  with:
    root: decks
    main: slides.md
```

| Input  | Default     | Description                                   |
|--------|-------------|-----------------------------------------------|
| `root` | `decks`     | Directory scanned recursively for decks.      |
| `main` | `slides.md` | File name that marks a deck directory.        |

| Output   | Description                                                                 |
|----------|-----------------------------------------------------------------------------|
| `matrix` | `{"include":[...]}` JSON; entries carry `name`, `dir` and `source`.         |
| `count`  | Number of decks discovered.                                                 |

## `revealjs/build-html`

Build **one Markdown file into a self-contained reveal.js HTML deck**. The
deck's YAML front matter picks the theme and the parameters; the slide
structure comes from the Markdown itself. Engine: pandoc 3.x
(`-t revealjs`, explicit slide level) with an own reveal.js 6 template and
two Lua filters; ```` ```mermaid ```` blocks are rendered to SVG at build
time by mermaid-cli (theme fonts installed for measuring *and* embedded
into the SVGs); math is rendered by vendored KaTeX; code is highlighted by
pandoc. reveal.js and KaTeX come from this action's `package-lock.json`
(`npm ci --ignore-scripts`), pandoc and mermaid-cli from digest-pinned
images passed as inputs (see `revealjs/resolve-images`). Every container
runs with `--network none`, so the HTML is guaranteed self-contained.
With `check: "true"` only the front matter and the theme are validated
(no docker, no npm) — the lint-time contract check. See
`revealjs/build-html/DECISIONS.md` for the design.

```yaml
- uses: actions/checkout@v7
- id: images
  uses: stklug84/actions/revealjs/resolve-images@v2
- id: html
  uses: stklug84/actions/revealjs/build-html@v2
  with:
    source: decks/showcase/slides.md
    name: showcase
    pandoc-image: ${{ steps.images.outputs.pandoc-image }}
    mermaid-image: ${{ steps.images.outputs.mermaid-image }}
```

| Input           | Default   | Description                                                                 |
|-----------------|-----------|-----------------------------------------------------------------------------|
| `source`        | —         | Deck Markdown file (workspace-relative). Required.                          |
| `name`          | —         | Deck name → `<out-dir>/<name>.html`, `<build-root>/<name>/`. Required.      |
| `out-dir`       | `dist`    | Output directory.                                                           |
| `build-root`    | `build`   | Root of the per-deck build directories (intermediates, `logs/`).            |
| `themes-dir`    | `themes`  | Consumer themes (`<themes-dir>/<name>/theme.yml`); else built-in themes.   |
| `pandoc-image`  | `""`      | Digest-pinned pandoc image. Required unless `check`.                        |
| `mermaid-image` | `""`      | Digest-pinned mermaid-cli image; required only when the deck has Mermaid.   |
| `check`         | `"false"` | `true` → validate front matter + theme only, write nothing.                 |

| Output           | Description                                                     |
|------------------|-----------------------------------------------------------------|
| `html`           | Path of the HTML deck.                                          |
| `slides`         | Number of slides (leaf sections).                               |
| `title`, `author`, `theme`, `size` | Deck metadata from the front matter / theme.  |
| `pdf-size`, `pdf-fragments`, `pdf-pause`, `pdf-load-pause` | Inputs for `revealjs/build-pdf`. |
| `build-dir`      | The deck's build directory.                                     |

**Markdown → slides** (pandoc semantics with a fixed rule set):

| Markdown | Result |
|---|---|
| YAML front matter (`title`, `subtitle`, `author`, `date`, …) | Title slide + deck settings |
| `# Heading` | Section divider (`.divider`, theme `divider-background`), opens a vertical stack |
| `## Heading` | A slide; `###` and deeper are headings inside the slide |
| `---` | Forces a new slide without heading |
| `::: notes` | Speaker notes; `:::: columns` / `::: {.column width="40%"}` columns |
| `::: incremental`, `. . .`, `::: {.fragment}` | Step-by-step reveal |
| `## Title {.compact background-color="#000"}` | Per-slide class / background |
| ```` ```mermaid ```` | Diagram rendered to SVG at build time (`img.mermaid`) |
| `$…$`, `$$…$$` | Math (KaTeX, MathML or none via `math:`) |
| `> [!NOTE]` … | `callout callout-note` div (also `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`) |

Slide level: front-matter `slide-level`, else **2 when the deck has any
`##`**, else 1 (pandoc's auto-detection is never used).

**Front matter** (unknown keys are rejected; `reveal:` passes raw reveal.js
options through):

```yaml
---
title: My Deck                # required
subtitle: …                   # optional: author (string or list), date, institute, lang, keywords
theme: curveball              # themes/<name>/ or a built-in reveal.js theme (white, black, …)
css: [extra.css]              # extra stylesheets, relative to the deck
size: "16:9"                  # 16:9 | 4:3 | 16:10 | <w>x<h>
slide-level: 2                # optional override
slide-number: c/t             # reveal.js slideNumber (string or boolean)
transition: fade              # none | fade | slide | convex | concave | zoom
navigation: linear            # default | linear | grid
center: false
logo: images/logo.png         # or false; the theme may provide a default
footer: "Plain text"          # or false
math: katex                   # katex | mathml | none
highlight: kate               # pandoc highlight style (default from the theme)
mermaid: {themeVariables: {…}}  # merged over the theme's Mermaid config
pdf: {size: "16:9", fragments: false, pause: 500, load-pause: 2000}
reveal: {hash: true}          # raw reveal.js options, applied last
title-slide: {class: title, background: "#FBF3D9"}
---
```

**Themes** live in `<themes-dir>/<name>/` and declare themselves in
`theme.yml`: `base` (built-in reveal.js theme layered underneath), `css`
(default `theme.css`), `highlight`, `divider-background`, `title-slide`
(`class`, `background`), `logo`, `footer`, `fonts` (list of
`{file, family, weight, style}` — installed for Mermaid measuring and
embedded into the SVGs), `reveal` (default options) and `mermaid` (mermaid
config incl. `themeVariables`). Themes style the shared component classes
`divider`, `callout`, `caveat`, `cards`/`card`, `kpis`/`kpi` (`num`,
`label`), `lead`, `compact`, `kicker`, `deck-logo`, `deck-footer` so decks
can switch themes by changing one line.

## `revealjs/build-pdf`

Export a self-contained reveal.js HTML deck to PDF with the digest-pinned
**DeckTape** image (bundled Chromium, `--no-sandbox`, vector text with
consolidated fonts; one page per slide, or per fragment step) and verify
the result with pypdf: magic bytes, page count == slide count (when
given), page size == deck size. Runs with `--network none` and reads the
deck via `file://`. Pair with `revealjs/build-html`, whose outputs feed
every input.

```yaml
- uses: stklug84/actions/revealjs/build-pdf@v2
  with:
    html: ${{ steps.html.outputs.html }}
    decktape-image: ${{ steps.images.outputs.decktape-image }}
    size: ${{ steps.html.outputs.pdf-size }}
    fragments: ${{ steps.html.outputs.pdf-fragments }}
    pause: ${{ steps.html.outputs.pdf-pause }}
    load-pause: ${{ steps.html.outputs.pdf-load-pause }}
    title: ${{ steps.html.outputs.title }}
    author: ${{ steps.html.outputs.author }}
    expected-pages: ${{ steps.html.outputs.slides }}
```

| Input            | Default    | Description                                                     |
|------------------|------------|-----------------------------------------------------------------|
| `html`           | —          | Workspace-relative HTML deck. Required.                         |
| `pdf`            | `""`       | Output path. Empty → next to the HTML with `.pdf`.              |
| `decktape-image` | —          | Digest-pinned DeckTape image. Required.                         |
| `size`           | `1280x720` | Viewport/page size in px; must match the deck's size.           |
| `fragments`      | `"false"`  | `true` → one page per fragment step.                            |
| `pause`          | `500`      | Per-slide pause (ms).                                           |
| `load-pause`     | `2000`     | Initial load pause (ms).                                        |
| `title`, `author`| `""`       | PDF metadata.                                                   |
| `expected-pages` | `0`        | Expected page count; `0` only requires ≥ 1 page.                |

| Output  | Description                 |
|---------|-----------------------------|
| `pdf`   | Path of the exported PDF.   |
| `pages` | Number of pages.            |

## `release/publish-dated`

Publish build artifacts as the dated, run-numbered release
`v<YYYY.MM.DD>-r<run-number>` (title `<title-prefix> <date> (<short-sha>)`,
notes with the commit subject and the asset list) and, with `keep > 0`,
prune older releases of the same scheme together with their tags and
sweep orphaned tags. Manually created releases or tags in other formats
are never touched. Extracted from the `latex-build-cv` reusable workflow,
with two fixes: a **re-run** reuses the release already tagged
`-r<run-number>` (assets replaced with `--clobber`) instead of failing,
and pruning is **fail-safe** — both the release and the tag inventory
must succeed before anything is deleted, so a failed `gh release list`
can never delete the tags of live releases. `dry-run: "true"` prints
every mutation instead of executing it (no token needed), which lets
pull-request builds exercise the release path. The calling job must grant
`contents: write`.

```yaml
- uses: stklug84/actions/release/publish-dated@v2
  with:
    files: "dist/*.pdf"
    title-prefix: "Slides"
    list-heading: "Decks:"
    keep: "10"
    dry-run: ${{ github.event_name != 'push' }}
```

| Input          | Default               | Description                                                     |
|----------------|-----------------------|-----------------------------------------------------------------|
| `files`        | —                     | Whitespace/newline-separated glob list; each must match ≥ 1 non-empty file. Required. |
| `title-prefix` | `Release`             | Title prefix → `<prefix> <YYYY-MM-DD> (<short-sha>)`.           |
| `list-heading` | `Files:`              | Heading above the asset list in the notes.                      |
| `keep`         | `0`                   | Keep the N newest matching releases; `0` disables pruning.      |
| `token`        | `${{ github.token }}` | Token with `contents: write`.                                   |
| `dry-run`      | `"false"`             | `true` → print mutations instead of executing them.             |

| Output  | Description                        |
|---------|------------------------------------|
| `tag`   | The release tag (created/reused).  |
| `title` | The release title.                 |

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
- **revealjs-python-lint** — the same trio via this repository's own
  `python/*` actions on `revealjs/build-html` and `revealjs/build-pdf`,
  plus the planner's golden tests (`revealjs/build-html/test/run-tests.sh`).
- **release-tests** — `release/publish-dated` against a mocked `gh`
  (`release/publish-dated/test/run-tests.sh`); asserts that a failed
  inventory never deletes anything.
- **revealjs-render** — docker integration test of the `revealjs/*`
  actions on the fixture deck (`revealjs/test/run-tests.sh`), toolchain
  digests pinned in `revealjs/test/docker/Dockerfile`.

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
