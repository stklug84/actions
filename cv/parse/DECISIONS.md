# cv/parse — design decisions

## Jinja2 vs stdlib for the emitters

**Decision: use Jinja2** (pinned `Jinja2==3.1.5`) for both the LaTeX
per-section emitters and the web `cv.yml` emitter.

### Evaluation criteria

| Criterion | stdlib (`string.Template`/f-strings) | Jinja2 |
| --------- | ------------------------------------ | ------ |
| Per-section files | Manual string concatenation per section; brittle. | One template file per section; clean separation. |
| `\href{url}{name}` reconstruction | Inline `if`/concatenation scattered through Python. | `{% if url %}…{% endif %}` directly in the template. |
| LaTeX escape as explicit filter | A bare function call wrapped around every value — easy to forget one. | Registered as a named filter (`\| latex`); applied uniformly and visibly per substitution site. |
| Conditional blocks (optional `logo`, empty `subentries`) | Nested Python `if`s build fragments; the template logic leaks into code. | Native `{% if %}` / `{% for %}` blocks colocated with the output shape. |
| Loops (bullets, subentries, rows) | Manual `"".join(...)` with separators; indentation handling is painful. | `{% for %}` with `loop`/whitespace control built in. |
| Reviewability of output shape | Output structure is implicit in Python. | Output structure is literally the template; diffs against goldens are readable. |

### Rationale

The LaTeX templates are non-trivial: nested `itemize`, optional
`subentries`, optional `logo` (omit when null), `\href` reconstruction,
two distinct styles (`plain` longtable row bodies vs. `sidebar`
public-API calls), and a LaTeX escaper that must run on every field.
The spec's bias ("Jinja2 if templates get non-trivial") is met. Keeping
the output shape in `.j2` files makes the emitters auditable against the
goldens and keeps `parse.py` focused on schema modelling, validation,
and view-model construction.

### Configuration

- `jinja2.Environment(autoescape=select_autoescape(...))` — LaTeX/YAML are
  **not** HTML, so HTML autoescaping would corrupt output; escaping is done
  explicitly via the `latex`/`yamlstr` filters. We use `select_autoescape`
  (which resolves to *off* for `.tex`/`.yml` and *on* for any future
  `.html`/`.xml`) rather than a constant `autoescape=False`, so CodeQL's
  `py/jinja2/autoescape-false` rule is satisfied without weakening any
  future HTML template.
- Custom `latex` filter implementing the spec's escaper: escapes
  `& % $ # _ { } ~ ^ \`, **preserves** `---` and `--` dashes, and
  rebuilds `\href{url}{name}` so URLs survive intact.
- `trim_blocks=True`, `lstrip_blocks=True`, `keep_trailing_newline=True`
  for predictable whitespace in the generated `.tex`/`.yml`.
- Templates loaded from `scripts/templates/` via `FileSystemLoader`.
- Example-CV styles (`pw`, `dh`, `vs`, `fs`, `tagged`) are selectable via
  `--style`. They share the `sidebar` public macro API, so `pw`/`dh`/`vs`
  alias the `sidebar` templates through `STYLE_TEMPLATE_DIRS` (no
  duplication); the single-column `fs`/`tagged` keep their own
  `templates/{fs,tagged}/` directories so they can diverge later. The
  `_template_dir(style)` helper resolves the directory; the per-style
  goldens (`test/golden/{pw-de,dh-de,vs-en,fs-en,tagged-de}`) lock both the
  alias identity and the dedicated templates.

### The `tagged` style and its extra fields

`tagged` drives `cv-tagged-ia.sty`, the only style whose public API extends
beyond `\cvskillgroup` to per-item skill bars
(`\cvskillgroupheading{group}` + `\cvskillitembar{name}{frac}`),
`\cvskillbubbles{l/w, ...}`, `\cvtechstack{a / b / c}` and
`\cvinterest{icon}{text}`. To feed those, the `tagged` emitter consumes
fields the other styles render only partially:

- `skills[].items[]` — each item is a `{name, size}` mapping. `size` is a
  0..1 fraction rendered as that item's inline proficiency bar via
  `\cvskillitembar` (preceded once per group by `\cvskillgroupheading`).
  The non-tagged styles (`plain`, `sidebar`, `fs`) and the web emitter use
  only `name`, ignoring `size`. A group-level `skills[].size` is no longer
  used (it was the old per-group bar fraction); it is tolerated but ignored
  when present.
- `interests[].icon` — an **optional** FontAwesome control-sequence name
  (without the leading backslash, e.g. `faBicycle`) used by the `tagged`
  style as the interest's list bullet via `\cvinterest`. Absent ⇒ the style
  falls back to its default square bullet; the other styles ignore `icon`
  and render the label text alone.
- `concepts[]` — an **optional** top-level section of `{text, size}` pairs,
  rendered as a trailing `\cvskillbubbles` row in `cv-skills.tex`. `size`
  is the bubble weight, left unbounded so sources tune it for the macro's
  radius formula (`0.06 + 0.045*weight`).
- `experience[].tags` — emitted as a `\cvtechstack` line directly below the
  corresponding `\cventry`.
- `conferences[].lat` / `conferences[].lon` — **optional** geographic
  coordinates (decimal degrees, lat in -90..90, lon in -180..180). When
  present they must be supplied **together**. Geolocated conferences are
  aggregated by rounded coordinate into weighted points (visit count =
  "heat") and emitted as a leading `\cvheatmap{lon/lat/weight, ...}` line in
  `cv-conferences.tex`, ahead of the year-grouped `\cventry` list.
  Conferences without coordinates still render in the textual list but do not
  appear on the map.

Independently of style, `\_personal_info` splits `meta.display_name` into
`\cvfirstname` (all-but-last whitespace token) and `\cvlastname` (last
token) so the tagged style's two-line `\cvname{first}{last}` can stack the
name; single-token names put the whole string in `\cvfirstname` with an
empty `\cvlastname`.

### Style-dependent schema profiles

**Decision: validate against a per-style schema profile** instead of one
shared, lowest-common-denominator `validate()`. `--style` (default `plain`)
selects the profile via `STYLE_PROFILES` / `_schema_profile()`; web mode
always validates against `tagged` because the web emitter consumes — and is
only ever built from — the tagged shape.

The two profiles diverge exactly where the emitters do:

| Field | `plain` profile (plain/sidebar/pw/dh/vs/fs) | `tagged` profile |
| ----- | ------------------------------------------- | ---------------- |
| `skills[].items[]` | plain strings | `{name, size}` mappings |
| `certifications[]` | bilingual `{text: {de, en}}` | structured `{code, name, issuer?}` |
| `concepts[]` | **rejected** (tagged-only) | optional `{text, size}` list |
| `interests[].icon` | **rejected** (tagged-only) | optional FontAwesome name |
| `conferences[].lat`/`lon` | **rejected** (tagged-only) | optional, jointly required |

The profiles are **strict**: the plain profile actively rejects the
tagged-only fields (rather than ignoring them) so a source authored for the
wrong style fails fast at `--check` time with a pinpointed message
(`concepts: not allowed for the 'plain' style (tagged-only field)`). This
replaces the earlier behavior where the tagged-only fields were merely
"validated only when present", which let a plain source silently carry
shapes its templates could never render.

The plain emitter normalizes each plain-string skill item to an internal
`{name, size: None}` view-model so the plain/sidebar/fs templates
(`map(attribute='name')`) need no change.

### `meta.pdf_title` (shared core)

`meta.pdf_title` is **optional and accepted under BOTH profiles** —
validated in `_validate_core()` (`_check_pdf_title`), not in either profile
branch. It may be a non-empty scalar (one PDF title for every language) or a
`{de, en}` mapping. `_personal_info` reads it style-agnostically and
defaults to `"Lebenslauf"` when absent, so it sets only the PDF metadata
`\cvtitle` and never the on-page role line. The golden fixtures exercise
this: `test/cv-plain.yml` carries `pdf_title: {de: Lebenslauf, en:
Curriculum Vitae}`, so the English non-tagged goldens emit
`\cvtitle{Curriculum Vitae}` while the German ones stay `Lebenslauf`.

### Web emitter note

The web `cv.yml` is emitted with a small Jinja2 template too (not
`yaml.safe_dump`) so the field **order** and block-scalar/list styling
match skcloud's hand-authored `_data/cv.yml` exactly and stay stable
under review. Values are YAML-escaped via a dedicated `yamlstr` filter.
