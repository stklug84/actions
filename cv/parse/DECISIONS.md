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

### Web emitter note

The web `cv.yml` is emitted with a small Jinja2 template too (not
`yaml.safe_dump`) so the field **order** and block-scalar/list styling
match skcloud's hand-authored `_data/cv.yml` exactly and stay stable
under review. Values are YAML-escaped via a dedicated `yamlstr` filter.
