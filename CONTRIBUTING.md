# Contributing

Thanks for taking the time to contribute! This repository hosts central,
reusable **composite actions**, organized into subdirectories by domain
(e.g. `ruby/`, `jekyll/`, `texlive/`).

## Workflow

1. Create a feature branch from `main`.
2. Make your changes (see conventions below).
3. Run the linters locally (see [Linting](#linting)).
4. Open a pull request against `main`. The `Lint` workflow runs
   automatically and code owners (see `.github/CODEOWNERS`) are requested
   for review.

## Repository layout

Each composite action lives in its own directory:

```text
<domain>/<action-name>/action.yml
```

Examples: `ruby/setup-ruby-bundler`, `texlive/detect`. New actions should
follow this pattern and be documented in the [README](README.md) with a
usage snippet plus input/output tables.

## Conventions

### Composite actions (`action.yml`)

- Start the file with the YAML document start marker (`---`) followed by
  a comment header describing the action and a usage example.
- Use 2-space indentation; keep lines at 120 characters or less
  (`.yamllint.yml`).
- Declare `shell: bash` explicitly for every `run:` step.
- Never interpolate `${{ ... }}` expressions directly inside `run:`
  scripts. Pass them via `env:` and reference the environment variables
  instead (this keeps the scripts injection-safe and shellcheck-clean).
- Start every bash script with `set -euo pipefail`.

### Shell scripts (`scripts/`)

Standalone scripts follow this header convention:

```bash
#!/usr/bin/env bash
# @author:
#	Steffen Klug <45033201+stklug84@users.noreply.github.com>
# @dependencies:
#	find
#	yq (mikefarah)
# @description:
#	What the script does.
# @arguments:
#	[arg-or-none]
## Usage: scripts/<script-name>.sh
### Example: scripts/<script-name>.sh
```

Note: a comment line must not begin with the lowercase word
`shellcheck` — it would be parsed as a shellcheck directive. Use the
capitalized spelling `ShellCheck` in prose and dependency lists.

## Linting

Pull requests must pass the `Lint` workflow
(`.github/workflows/lint.yml`). Run the same checks locally before
pushing (requires `actionlint`, `shellcheck`, `yq`, `yamllint`, `npx`):

```bash
actionlint
scripts/shellcheck-actions.sh
yamllint --strict .
npx markdownlint-cli2 --config .markdownlint.yaml '**/*.md'
```

| Check        | Configuration        | Scope                                  |
|--------------|----------------------|----------------------------------------|
| actionlint   | built-in             | `.github/workflows/*`                  |
| shellcheck   | `.shellcheckrc`      | bash in composite actions and scripts  |
| yamllint     | `.yamllint.yml`      | all YAML files                         |
| markdownlint | `.markdownlint.yaml` | all Markdown files                     |

## Versioning and releases

Releases are tagged `vX.Y.Z` with a moving major alias (`vX`):

- **Patch/minor** changes (fixes, new optional inputs): bump the version
  and move the major alias forward.
- **Breaking** changes (removed/renamed inputs or outputs, changed
  defaults with behavioral impact): bump the major version and create a
  new alias.

Consumers pin to the major alias (`@v1`) or to an exact tag.
