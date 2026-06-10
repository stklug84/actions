# actions

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

| Input            | Default     | Description                                                        |
|------------------|-------------|--------------------------------------------------------------------|
| `engine`         | `""`        | LaTeX toolchain (`latexmk`, `pdflatex`, `latex-chain`). Empty → `default-engine`. |
| `default-engine` | `"latexmk"` | Engine used when `engine` is empty.                                |
| `local`          | `""`        | Local (gh act) mode. Empty → auto-detect via `ACT` env, else `false`. |
| `main-tex`       | `""`        | Main document basename without `.tex`. Empty → auto-detect via `\documentclass`. |

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

## Versioning

Releases are tagged `vX.Y.Z` with a moving major alias (`vX`). Pin to the major
alias (`@v1`) for automatic patch/minor updates, or to an exact tag for
immutability.
