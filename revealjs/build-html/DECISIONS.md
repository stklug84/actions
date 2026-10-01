# revealjs/build-html — design decisions

## Engine: pandoc + Lua filters (not reveal-md, Quarto, the reveal.js Markdown plugin or a custom generator)

**Decision: pandoc 3.x `-t revealjs` with an explicit `--slide-level`, our
own reveal.js 6 template and two small Lua filters; a thin Python planner
owns the front-matter contract.**

| Option | Verdict |
| ------ | ------- |
| pandoc | Native heading → slide mapping (`#` section divider + vertical stack, `##` slide, `###` in-slide heading, `---` extra slide), `::: notes`, `:::: columns`, `::: incremental`, `. . .`, heading attributes → `data-*`; deterministic HTML (golden-testable); one 34 MB binary with digest-pinned official images. |
| Quarto | Same heading semantics, but a ~150 MB install with its own Deno/Sass stack, SCSS-centric theming and no CLI PDF export (browser print or DeckTape anyway). |
| reveal-md | Repository archived (last release 2024-11); slides split on `---` separators, not headings. |
| reveal.js Markdown plugin | Client-side, separator-based; client-side Mermaid mis-measures under reveal's `transform: scale()`. |
| Custom markdown-it-py generator | Full control, but re-implements slide splitting, notes, columns, fragments and attributes. Kept as the escape hatch. |

### Slide level is never auto-detected

pandoc's default slide level is "the highest heading level followed
immediately by content": a `#` followed by a paragraph silently makes
level 1 the slide level and merges every `##` into one slide. The
`structure.lua` filter therefore fixes the rule as: front-matter
`slide-level` if present, else **2 when the deck has any `##`**, else 1;
`prepare.py finalize` passes the same value to pass 2 and fails if the two
disagree.

## Two pandoc passes, one plan

Pass 1 (`markdown+emoji` → JSON AST) runs the Lua filters:

- `mermaid.lua` writes every ```` ```mermaid ```` block to
  `<build>/mermaid/<sha1(salt + source)>.mmd` and replaces it with an
  `Image` pointing at the `.svg` that mermaid-cli renders afterwards (the
  block's own attributes, e.g. `width="70%"`, survive on the image; the
  image carries the `mermaid` class for theming).
- `structure.lua` applies the slide-level rule, tags level-1 headings as
  `divider` (adding the theme's `divider-background` unless the heading
  has a background of its own), converts GitHub alerts (`> [!NOTE]`) to
  `callout callout-<kind>` divs, strips the deck-only front-matter keys
  from the metadata and writes the structure summary.

Pass 2 (JSON AST → `revealjs`) renders with the template, `--embed-resources`
and the vendored assets. Splitting at the AST means pandoc parses the
Markdown exactly once, the diagrams are rendered by a separate container
between the passes, and both passes are driven by defaults files the
planner writes — nothing is interpolated into a command line.

### Why the AST, not a Markdown regex, finds the Mermaid blocks

Fenced blocks inside lists, nested fences and indented code would all fool
a regex; pandoc's parser is the single source of truth for what a code
block is.

## Python planner (`prepare.py`), pure and typed

`prepare.py` never runs a subprocess. It validates the front matter and the
theme (`check`), writes the pass-1 defaults, metadata, mermaid config and
`plan.env` (`plan`), writes the pass-2 defaults (`finalize`), embeds fonts
into SVGs (`embed-fonts`) and verifies the HTML (`verify-html`). The bash
wrapper owns docker/npm/pandoc. Same split as `cv/parse`: schema and view
model in typed Python with golden tests, tool orchestration in
shellcheck-clean bash.

### Strict schema

Unknown keys are rejected with the list of allowed keys; duplicate YAML keys
are rejected (PyYAML would silently keep the last one); every path
(`css`, `logo`, theme files, fonts) must resolve — symlinks followed —
inside the workspace; enumerations (`transition`, `navigation`, `math`,
`highlight`, `size`, theme `base`) are closed. `reveal:` is the escape hatch
for raw reveal.js options and is merged last.

### Template variables never collide with front matter

pandoc exposes the document metadata to the template. A deck's `css:` or
`math:` key would shadow the HTML writer's own `css` / `math` variables,
so the planner (a) strips every deck-only key in `structure.lua` and (b)
uses distinct variable names in the template (`deck-theme-base`,
`deck-css`, `deck-logo`, `deck-footer`, `reveal-config`).

### One JSON blob for `Reveal.initialize()`

pandoc's stock template interpolates each option separately and emits
strings unquoted (`showNotes: separate-page` is a JavaScript
`ReferenceError`). The planner builds the whole configuration
(defaults < theme `reveal:` < front-matter keys < `reveal:` passthrough)
and serialises it once, with `<` escaped as `\u003c` so a literal
`</script>` in a value cannot terminate the script element. The footer is
plain text and HTML-escaped by the planner.

## Mermaid: build-time SVG with fonts installed *and* embedded

Client-side Mermaid inside reveal.js is unreliable (hidden slides,
`transform: scale()` measurement, decktape#328), so diagrams are rendered
by the pinned mermaid-cli image. Two font facts shape the implementation:

1. mermaid-cli's `--cssFile` is applied *after* layout, so it cannot make
   the layout use the deck font. The theme's font files are therefore
   mounted into the container as system fonts (`/usr/share/fonts/deck`,
   fontconfig accepts woff2/woff/ttf/otf), so text is *measured* with the
   real font.
2. pandoc embeds SVG images as `data:` URIs (`<img>`), which are
   font-isolated documents that do not inherit the page's `@font-face`.
   `embed-fonts` injects the matching theme fonts as `@font-face` data URIs
   into every SVG, so the diagram is *displayed* with the same font it was
   measured with — in the HTML and in the PDF, on any machine.

Keeping the SVGs as `<img>` (rather than `.inline-svg`) also sidesteps id
and `<style>` collisions between diagrams; each SVG still gets a unique id
(`-I m-<hash>`).

### Cache key

`<sha1(salt + source)>` where `salt = sha256(mermaid config, font files,
mermaid image reference)`: a changed palette, font or renderer can never
reuse a stale SVG, while unchanged diagrams are reused across runs of the
same build directory.

## Vendored reveal.js 6 + KaTeX via a lockfile

reveal.js 6 moved its plugins to `dist/plugin/<name>.js`; pandoc's stock
template still targets reveal.js 5 paths, hence the own template. reveal.js
and KaTeX are pinned in `package.json` / `package-lock.json` (integrity
hashes; Dependabot npm ecosystem) and installed with
`npm ci --ignore-scripts` into `$RUNNER_TEMP` (cached by lockfile hash),
never fetched from a CDN. With `--network none` on every container, the
final HTML is guaranteed self-contained; `verify-html` additionally
rejects any `src`/`href`/`url()` pointing at `http(s)://`.

## Containers via `docker run`, not job-level `container:`

The three tools live in three upstream images; no single image ships
pandoc + Chromium + mermaid-cli. Running each via `docker run -u
<workspace owner> --network none -v $WORKSPACE:/data -w /data` inside the
composite action keeps the action self-contained, works identically on
hosted runners and under `gh act --bind` (the sibling containers see the
same host path), and lets the consumer pin all three digests in ONE
pin-only multi-stage Dockerfile (Dependabot bumps every `FROM`). Files
created by a root shell (act) are handed back to the workspace owner.

## Pinned runtime dependencies

- PyYAML `6.0.2` (wrapper installs on demand; same pin as `cv/parse`).
- reveal.js `6.0.2`, KaTeX `0.18.9` (package-lock.json).
- Images (test pins in `revealjs/test/docker/Dockerfile`, consumers keep
  their own): `pandoc/core:3.11.0.0-alpine`, `minlag/mermaid-cli:11.17.0`,
  `ghcr.io/astefanutti/decktape:3.16.1`.
- `revealjs/build-pdf`: pypdf `6.19.0` for page count / page size checks.
