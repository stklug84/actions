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

## Versioning

Releases are tagged `vX.Y.Z` with a moving major alias (`vX`). Pin to the major
alias (`@v1`) for automatic patch/minor updates, or to an exact tag for
immutability.
