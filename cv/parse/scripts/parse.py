#!/usr/bin/env python3
"""Parse a canonical bilingual ``cv.yml`` and emit consumer outputs.

Two output modes:

* ``latex`` — per-section ``.tex`` files for a selected ``--style``
  (``plain`` | ``sidebar``) and ``--lang`` (``de`` | ``en``), filtered to
  entries whose ``targets`` contains ``latex``.
* ``web`` — a single ``cv.yml`` in skcloud's exact schema (English,
  filtered to entries whose ``targets`` contains ``web``).

A ``--check`` mode validates the schema against the shared contract and
writes nothing, exiting nonzero with a clear message on the first
violation.

The emitters render Jinja2 templates from ``templates/`` with
``autoescape=False`` and an explicit ``latex`` escape filter (see
``DECISIONS.md``). YAML is loaded with ``yaml.safe_load`` only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import Environment, FileSystemLoader, select_autoescape

TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

REQUIRED_TOP_LEVEL = [
    "meta",
    "contact",
    "experience",
    "education",
    "conferences",
    "skills",
    "languages",
    "certifications",
    "interests",
]

VALID_TARGETS = {"latex", "web"}
VALID_KINDS = {"work", "study", "cert"}
DEFAULT_TARGETS = ["latex", "web"]

# Section -> output filename for the LaTeX mode.
LATEX_SECTION_FILES = {
    "personal-info": "personal-info.tex",
    "experience": "cv-experience.tex",
    "education": "cv-education.tex",
    "conferences": "cv-conferences.tex",
    "skills": "cv-skills.tex",
    "languages": "cv-languages.tex",
    "interests": "cv-interests.tex",
    "certifications": "cv-certifications.tex",
}

# Selectable ``--style`` values. ``plain`` and ``sidebar`` are the original
# layouts; ``pw``/``dh``/``vs``/``fs``/``tagged`` reproduce the example CVs in
# the curriculum-vitae repo (styles/cv-{sidebar-pw,sidebar-dh,sidebar-vs,
# banking-fs,tagged-ia}.sty). ``tagged`` drives cv-tagged-ia.sty's extended
# macro API (\cvskillbar / \cvskillbubbles / \cvtechstack), so it consumes
# extra YAML fields (skills[].size, concepts[], experience[].tags) that the
# other styles ignore.
LATEX_STYLES = ["plain", "sidebar", "pw", "dh", "vs", "fs", "tagged"]

# Style -> template subdirectory. Several example-CV styles share the
# ``sidebar`` macro API (\cventry/\cvsection/\cvskillgroup/...), so they reuse
# its templates instead of duplicating them. Styles with a distinct macro
# surface (single-column ``fs``/``tagged``) get their own template directory.
# A style absent from this map renders from its own ``<style>/`` directory.
STYLE_TEMPLATE_DIRS = {
    "pw": "sidebar",
    "dh": "sidebar",
    "vs": "sidebar",
}


def _template_dir(style: str) -> str:
    """Resolve the template subdirectory for a ``--style`` value."""
    return STYLE_TEMPLATE_DIRS.get(style, style)


class CheckError(Exception):
    """A schema validation failure with a human-readable message."""


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------
def load_cv(path: Path) -> dict[str, Any]:
    """Load the canonical cv.yml with ``yaml.safe_load`` only."""
    if not path.is_file():
        raise CheckError(f"source not found: {path}")
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if not isinstance(data, dict):
        raise CheckError(f"{path}: top-level YAML must be a mapping")
    return data


# --------------------------------------------------------------------------
# Validation (--check)
# --------------------------------------------------------------------------
def _targets_of(entry: dict[str, Any], where: str) -> list[str]:
    """Return the validated ``targets`` of an entry (absent -> default)."""
    targets = entry.get("targets")
    if targets is None:
        return list(DEFAULT_TARGETS)
    if not isinstance(targets, list) or not all(isinstance(t, str) for t in targets):
        raise CheckError(f"{where}: targets must be a list of strings")
    invalid = [t for t in targets if t not in VALID_TARGETS]
    if invalid:
        raise CheckError(
            f"{where}: invalid target(s) {invalid}; allowed: {sorted(VALID_TARGETS)}"
        )
    return targets


def _check_bilingual(value: Any, where: str) -> None:
    """A bilingual field must be a mapping with non-empty de and en."""
    if not isinstance(value, dict):
        raise CheckError(f"{where}: must be a mapping with 'de' and 'en'")
    for lang in ("de", "en"):
        if lang not in value:
            raise CheckError(f"{where}: missing required '{lang}'")
        text = value[lang]
        if not isinstance(text, str) or not text.strip():
            raise CheckError(f"{where}: '{lang}' must be a non-empty string")


def _check_int(value: Any, where: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise CheckError(f"{where}: must be an integer")
    return value


def _check_unit(value: Any, where: str) -> float:
    """Validate a unit-interval number (0..1), used for skill-bar fractions."""
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise CheckError(f"{where}: must be a number")
    if not 0 <= value <= 1:
        raise CheckError(f"{where}: must be a number in 0..1")
    return float(value)


def _check_coord(value: Any, where: str, bound: float) -> float:
    """Validate a geographic coordinate in [-bound, bound] (90 lat / 180 lon)."""
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise CheckError(f"{where}: must be a number")
    if not -bound <= value <= bound:
        raise CheckError(f"{where}: must be a number in -{bound:g}..{bound:g}")
    return float(value)


def validate(data: dict[str, Any]) -> None:
    """Validate ``data`` against the shared schema contract.

    Raises :class:`CheckError` on the first violation found.
    """
    # Rule 1: required top-level keys present.
    for key in REQUIRED_TOP_LEVEL:
        if key not in data:
            raise CheckError(f"missing required top-level key: {key}")

    # Rule 2: meta.title/location/summary have both de and en.
    meta = data["meta"]
    if not isinstance(meta, dict):
        raise CheckError("meta: must be a mapping")
    for field in ("title", "location", "summary"):
        if field not in meta:
            raise CheckError(f"meta.{field}: missing")
        _check_bilingual(meta[field], f"meta.{field}")

    # Rule 6: contact.address is OPTIONAL; when present it must be a list of
    # 1-3 non-empty strings. (birthdate, birthplace, location_signature,
    # photo_path and signature_path are likewise optional and emitted empty
    # when absent — see _personal_info.)
    contact = data["contact"]
    if not isinstance(contact, dict):
        raise CheckError("contact: must be a mapping")
    if "address" in contact:
        address = contact["address"]
        if not isinstance(address, list) or not (1 <= len(address) <= 3):
            raise CheckError("contact.address: must be a list of 1-3 strings")
        if not all(isinstance(line, str) and line.strip() for line in address):
            raise CheckError("contact.address: every entry must be a non-empty string")

    # Optional contact profile links: linkedin / github / website.
    # Each, IF PRESENT, must be a mapping {url: <non-empty str>,
    # label: <optional str>}. Absence of all three remains valid.
    for link_key in ("linkedin", "github", "website"):
        if link_key not in contact:
            continue
        link = contact[link_key]
        if not isinstance(link, dict):
            raise CheckError(f"contact.{link_key}: must be a mapping")
        url = link.get("url")
        if not isinstance(url, str) or not url.strip():
            raise CheckError(f"contact.{link_key}.url: must be a non-empty string")
        label = link.get("label")
        if label is not None and not isinstance(label, str):
            raise CheckError(f"contact.{link_key}.label: must be a string")

    # experience[]
    exp_ids: list[str] = []
    for index, entry in enumerate(data["experience"]):
        where = f"experience[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)  # Rule 3.
        eid = entry.get("id")
        if not isinstance(eid, str) or not eid.strip():
            raise CheckError(f"{where}.id: must be a non-empty string")
        exp_ids.append(eid)
        # Rule 5: kind in {work, study, cert}; year integer.
        if entry.get("kind") not in VALID_KINDS:
            raise CheckError(f"{where}.kind: must be one of {sorted(VALID_KINDS)}")
        _check_int(entry.get("year"), f"{where}.year")
        # Rule 4: bilingual fields non-empty de + en.
        for field in ("period", "role", "location", "summary"):
            _check_bilingual(entry.get(field), f"{where}.{field}")
        for b_index, bullet in enumerate(entry.get("bullets", []) or []):
            _check_bilingual(bullet, f"{where}.bullets[{b_index}]")
        for s_index, sub in enumerate(entry.get("subentries", []) or []):
            sub_where = f"{where}.subentries[{s_index}]"
            if not isinstance(sub, dict):
                raise CheckError(f"{sub_where}: must be a mapping")
            _check_bilingual(sub.get("title"), f"{sub_where}.title")
            for sb_index, sbullet in enumerate(sub.get("bullets", []) or []):
                _check_bilingual(sbullet, f"{sub_where}.bullets[{sb_index}]")

    # education[]
    edu_ids: list[str] = []
    for index, entry in enumerate(data["education"]):
        where = f"education[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)
        eid = entry.get("id")
        if not isinstance(eid, str) or not eid.strip():
            raise CheckError(f"{where}.id: must be a non-empty string")
        edu_ids.append(eid)
        for field in ("degree", "institution"):
            _check_bilingual(entry.get(field), f"{where}.{field}")
        for d_index, detail in enumerate(entry.get("details", []) or []):
            _check_bilingual(detail, f"{where}.details[{d_index}]")

    # Rule 7: id values unique within experience and education.
    for ids, label in ((exp_ids, "experience"), (edu_ids, "education")):
        dupes = {i for i in ids if ids.count(i) > 1}
        if dupes:
            raise CheckError(f"{label}: duplicate id(s): {sorted(dupes)}")

    # conferences[]
    for index, entry in enumerate(data["conferences"]):
        where = f"conferences[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)
        _check_int(entry.get("year"), f"{where}.year")
        if not isinstance(entry.get("name"), str) or not entry["name"].strip():
            raise CheckError(f"{where}.name: must be a non-empty string")
        # lat/lon are optional (consumed only by the tagged style's
        # \cvheatmap). When present, both must be supplied together as
        # numbers within geographic bounds.
        has_lat = "lat" in entry
        has_lon = "lon" in entry
        if has_lat != has_lon:
            raise CheckError(f"{where}: lat and lon must be supplied together")
        if has_lat:
            _check_coord(entry["lat"], f"{where}.lat", 90.0)
            _check_coord(entry["lon"], f"{where}.lon", 180.0)

    # skills[]
    for index, entry in enumerate(data["skills"]):
        where = f"skills[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)
        _check_bilingual(entry.get("group"), f"{where}.group")
        items = entry.get("items")
        if not isinstance(items, list) or not items:
            raise CheckError(f"{where}.items: must be a non-empty list")
        # ``size`` is optional (consumed only by the ``tagged`` style's
        # \cvskillbar). When present it must be a number in 0..1.
        if "size" in entry:
            _check_unit(entry["size"], f"{where}.size")

    # concepts[] — OPTIONAL section (consumed only by the ``tagged`` style's
    # \cvskillbubbles). Absent => valid. When present it must be a list of
    # {text: non-empty str, size: number}. ``size`` is the bubble weight and
    # is left unbounded here: the tagged style scales it via its radius
    # formula, and sources tune it freely (see data/cv-databricks.yml).
    if "concepts" in data:
        concepts = data["concepts"]
        if not isinstance(concepts, list):
            raise CheckError("concepts: must be a list")
        for index, entry in enumerate(concepts):
            where = f"concepts[{index}]"
            if not isinstance(entry, dict):
                raise CheckError(f"{where}: must be a mapping")
            _targets_of(entry, where)
            text = entry.get("text")
            if not isinstance(text, str) or not text.strip():
                raise CheckError(f"{where}.text: must be a non-empty string")
            size = entry.get("size")
            if not isinstance(size, (int, float)) or isinstance(size, bool):
                raise CheckError(f"{where}.size: must be a number")

    # languages[]
    for index, entry in enumerate(data["languages"]):
        where = f"languages[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)
        _check_bilingual(entry.get("name"), f"{where}.name")
        _check_bilingual(entry.get("level_label"), f"{where}.level_label")
        level = _check_int(entry.get("level"), f"{where}.level")
        if not 1 <= level <= 5:  # Rule 5: level in 1..5.
            raise CheckError(f"{where}.level: must be an integer in 1..5")

    # certifications[]
    for index, entry in enumerate(data["certifications"]):
        where = f"certifications[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)
        _check_bilingual(entry.get("text"), f"{where}.text")

    # interests[]
    for index, entry in enumerate(data["interests"]):
        where = f"interests[{index}]"
        if not isinstance(entry, dict):
            raise CheckError(f"{where}: must be a mapping")
        _targets_of(entry, where)
        _check_bilingual(entry, where)


# --------------------------------------------------------------------------
# Jinja2 environment + filters
# --------------------------------------------------------------------------
# Matches \href{url}{name} so we can escape name but leave url intact.
_HREF_RE = re.compile(r"\\href\{([^}]*)\}\{([^}]*)\}")

# LaTeX special characters that need escaping (handled per-char below).
_LATEX_SPECIALS = {
    "&": r"\&",
    "%": r"\%",
    "$": r"\$",
    "#": r"\#",
    "_": r"\_",
    "{": r"\{",
    "}": r"\}",
    "~": r"\textasciitilde{}",
    "^": r"\textasciicircum{}",
    "\\": r"\textbackslash{}",
}

# Placeholders that survive escaping so dashes are preserved verbatim.
# (NUL-delimited sentinels; not secrets — bandit B105 is a false positive.)
_EMDASH_TOKEN = "\x00EMDASH\x00"  # nosec B105
_ENDASH_TOKEN = "\x00ENDASH\x00"  # nosec B105


def _escape_plain(text: str) -> str:
    """Escape LaTeX specials, preserving ``---`` and ``--`` dashes."""
    # Protect dashes first (longest match wins).
    protected = text.replace("---", _EMDASH_TOKEN).replace("--", _ENDASH_TOKEN)
    out: list[str] = []
    for char in protected:
        out.append(_LATEX_SPECIALS.get(char, char))
    escaped = "".join(out)
    return escaped.replace(_EMDASH_TOKEN, "---").replace(_ENDASH_TOKEN, "--")


def latex_escape(value: Any) -> str:
    r"""Escape a value for LaTeX, rebuilding ``\href{url}{name}``.

    Escapes ``& % $ # _ { } ~ ^ \``; preserves ``---`` and ``--``; and
    reconstructs any ``\href{url}{name}`` so the URL is emitted verbatim
    while the visible name is escaped.
    """
    text = "" if value is None else str(value)
    pieces: list[str] = []
    last = 0
    for match in _HREF_RE.finditer(text):
        pieces.append(_escape_plain(text[last : match.start()]))
        url, name = match.group(1), match.group(2)
        pieces.append(f"\\href{{{url}}}{{{_escape_plain(name)}}}")
        last = match.end()
    pieces.append(_escape_plain(text[last:]))
    return "".join(pieces)


def web_normalize(text: str) -> str:
    """Normalize LaTeX-style typography to Unicode for the web view.

    The canonical cv.yml may carry LaTeX dash conventions (``---`` em
    dash, ``--`` en dash) so the LaTeX emitter can pass them through
    verbatim. The web view is HTML, so convert them to the real Unicode
    characters instead of leaking literal ``---`` into the page. Order
    matters: replace the longer token first.
    """
    return text.replace("---", "\u2014").replace("--", "\u2013")


def yaml_str(value: Any) -> str:
    """Render a scalar as a safe single-line double-quoted YAML string.

    Applies web typography normalization (LaTeX dashes -> Unicode) since
    this filter is only used by the web (YAML) emitter.
    """
    text = "" if value is None else str(value)
    text = web_normalize(text)
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


# Autoescape policy shared by every Jinja2 environment.
#
# This emitter only ever renders LaTeX (``.tex``) and YAML (``.yml``)
# templates, where HTML autoescaping would corrupt the output (e.g. ``&``,
# ``<``, ``{`` in LaTeX). Output-specific escaping is performed explicitly
# via the ``latex`` and ``yamlstr`` filters instead.
#
# We use ``select_autoescape`` rather than a constant ``autoescape=False``
# so the decision is made per-template by extension: HTML/XML templates
# (should one ever be added) are escaped, while ``.tex``/``.yml`` are not.
# This keeps the current behavior while avoiding a blanket, always-off
# autoescape that disables protection for any future HTML template.
_AUTOESCAPE = select_autoescape(
    enabled_extensions=("html", "htm", "xml"),
    default_for_string=False,
    default=False,
)


def build_latex_env() -> Environment:
    """Jinja2 env with LaTeX-friendly delimiters (no ``{{`` / ``}}``).

    LaTeX uses ``{`` and ``}`` pervasively, so the default Jinja2
    delimiters would collide. Expressions use ``\\VAR{ ... }`` and
    statements use ``\\BLOCK{ ... }`` instead.
    """
    env = Environment(  # nosec B701  # uses select_autoescape
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        autoescape=_AUTOESCAPE,
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
        block_start_string=r"\BLOCK{",
        block_end_string="}",
        variable_start_string=r"\VAR{",
        variable_end_string="}",
        comment_start_string=r"\#{",
        comment_end_string="}",
    )
    env.filters["latex"] = latex_escape
    env.filters["yamlstr"] = yaml_str
    return env


def build_web_env() -> Environment:
    """Jinja2 env with default delimiters for the YAML web template."""
    env = Environment(  # nosec B701  # uses select_autoescape
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        autoescape=_AUTOESCAPE,
        trim_blocks=True,
        lstrip_blocks=True,
        keep_trailing_newline=True,
    )
    env.filters["latex"] = latex_escape
    env.filters["yamlstr"] = yaml_str
    return env


# --------------------------------------------------------------------------
# View-model helpers
# --------------------------------------------------------------------------
def _has_target(entry: dict[str, Any], target: str) -> bool:
    targets = entry.get("targets")
    if targets is None:
        targets = DEFAULT_TARGETS
    return target in targets


def _pick(value: Any, lang: str) -> Any:
    """Pick the language variant of a bilingual mapping, else passthrough."""
    if isinstance(value, dict) and "de" in value and "en" in value:
        return value[lang]
    return value


# --------------------------------------------------------------------------
# LaTeX emission
# --------------------------------------------------------------------------
def _latex_experience(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    rows = []
    for entry in data["experience"]:
        if not _has_target(entry, "latex"):
            continue
        rows.append(
            {
                "period": _pick(entry["period"], lang),
                "role": _pick(entry["role"], lang),
                "org": entry["org"],
                "location": _pick(entry["location"], lang),
                "summary": _pick(entry["summary"], lang),
                "tags": list(entry.get("tags", []) or []),
                "bullets": [_pick(b, lang) for b in entry.get("bullets", []) or []],
                "subentries": [
                    {
                        "date": sub.get("date", ""),
                        "title": _pick(sub["title"], lang),
                        "bullets": [
                            _pick(b, lang) for b in sub.get("bullets", []) or []
                        ],
                    }
                    for sub in entry.get("subentries", []) or []
                ],
            }
        )
    return rows


def _latex_education(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    rows = []
    for entry in data["education"]:
        if not _has_target(entry, "latex"):
            continue
        rows.append(
            {
                "period": entry.get("period", ""),
                "degree": _pick(entry["degree"], lang),
                "institution": _pick(entry["institution"], lang),
                "grade": entry.get("grade"),
                "details": [_pick(d, lang) for d in entry.get("details", []) or []],
            }
        )
    return rows


def _latex_conferences(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    # Group conferences by year (descending) for the longtable layout.
    by_year: dict[int, list[dict[str, Any]]] = {}
    for entry in data["conferences"]:
        if not _has_target(entry, "latex"):
            continue
        by_year.setdefault(entry["year"], []).append(
            {
                "name": entry["name"],
                "location": entry.get("location", ""),
                "date": entry.get("date", ""),
                "url": entry.get("url"),
            }
        )
    return [
        {"year": year, "entries": by_year[year]}
        for year in sorted(by_year, reverse=True)
    ]


def _latex_conf_heatmap(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    """Aggregate geolocated conferences into weighted map points.

    Entries carrying lat/lon are bucketed by their (rounded) coordinate; the
    bucket's count becomes the dot weight ("heat") consumed by the tagged
    style's \\cvheatmap. Entries without coordinates contribute to the
    textual list (\\_latex_conferences) but not the map. Returned sorted by
    descending weight then longitude for a stable emit order.
    """
    buckets: dict[tuple[float, float], dict[str, Any]] = {}
    for entry in data["conferences"]:
        if not _has_target(entry, "latex"):
            continue
        if "lat" not in entry or "lon" not in entry:
            continue
        lat = round(float(entry["lat"]), 2)
        lon = round(float(entry["lon"]), 2)
        bucket = buckets.setdefault(
            (lat, lon),
            {"lat": lat, "lon": lon, "label": entry.get("location", ""), "weight": 0},
        )
        bucket["weight"] += 1
    return sorted(
        buckets.values(),
        key=lambda point: (-point["weight"], point["lon"]),
    )


def _latex_skills(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    rows = []
    for entry in data["skills"]:
        if not _has_target(entry, "latex"):
            continue
        rows.append(
            {
                "group": _pick(entry["group"], lang),
                "items": list(entry["items"]),
                "size": entry.get("size"),
            }
        )
    return rows


def _latex_concepts(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    """View-model for the optional ``concepts`` section.

    Each concept is a ``{text, size}`` pair feeding the ``tagged`` style's
    ``\\cvskillbubbles`` macro. ``concepts`` is optional: sources without it
    yield an empty list (and the template emits nothing). Entries are
    filtered by ``targets`` like every other section.
    """
    rows = []
    for entry in data.get("concepts", []) or []:
        if not _has_target(entry, "latex"):
            continue
        rows.append(
            {
                "text": entry.get("text", ""),
                "size": entry.get("size"),
            }
        )
    return rows


def _latex_languages(data: dict[str, Any], lang: str) -> list[dict[str, Any]]:
    rows = []
    for entry in data["languages"]:
        if not _has_target(entry, "latex"):
            continue
        rows.append(
            {
                "name": _pick(entry["name"], lang),
                "level_label": _pick(entry["level_label"], lang),
                "level": entry["level"],
            }
        )
    return rows


def _latex_interests(data: dict[str, Any], lang: str) -> list[str]:
    return [
        _pick(entry, lang) for entry in data["interests"] if _has_target(entry, "latex")
    ]


def _latex_certifications(data: dict[str, Any], lang: str) -> list[str]:
    return [
        _pick(entry["text"], lang)
        for entry in data["certifications"]
        if _has_target(entry, "latex")
    ]


def _derive_link_label(url: str) -> str:
    """Derive a display label from ``url``.

    Strips the ``https://`` / ``http://`` scheme and any trailing slash.
    """
    label = url.strip()
    for scheme in ("https://", "http://"):
        if label.lower().startswith(scheme):
            label = label[len(scheme) :]
            break
    return label.rstrip("/")


def _personal_info(data: dict[str, Any], lang: str) -> dict[str, Any]:
    meta = data["meta"]
    contact = data["contact"]
    # Optional contact fields are emitted empty when absent (the templates
    # define the macros unconditionally; consuming styles guard \includegraphics
    # on the empty photo/signature paths). address is optional too.
    address = [*list(contact.get("address") or []), "", "", ""]
    # meta.location (bilingual) is the geographic location shown in the
    # header. When contact.address is omitted, it backs the map-marker
    # contact chip (\cvaddresstwo) so the location is never blank; a present
    # contact.address always wins. \cvlocation stays bound to
    # contact.location_signature, which the plain style's signature block
    # consumes (\cvlocation, \today).
    meta_location = _pick(meta["location"], lang)
    if not (contact.get("address") or []):
        address[1] = meta_location
    # Split display_name into first/last for the tagged style's two-line
    # \cvname (all-but-last token -> firstname, last token -> lastname).
    # Single-token names degrade gracefully: firstname holds the whole name
    # and lastname is empty.
    _name_parts = meta["display_name"].split()
    if len(_name_parts) > 1:
        firstname = " ".join(_name_parts[:-1])
        lastname = _name_parts[-1]
    else:
        firstname = meta["display_name"]
        lastname = ""
    info: dict[str, Any] = {
        "author": meta["author"],
        "pdf_author": meta["pdf_author"],
        "title": "Lebenslauf",
        "subject": meta.get("subject", ""),
        "display_name": meta["display_name"],
        "firstname": firstname,
        "lastname": lastname,
        "roleline": _pick(meta["title"], lang),
        "profile": _pick(meta["summary"], lang),
        "birthdate": contact.get("birthdate", ""),
        "birthplace": contact.get("birthplace", ""),
        "address_one": address[0],
        "address_two": address[1],
        "address_three": address[2],
        "phone": contact["phone"],
        "email": contact["email"],
        "location": contact.get("location_signature", ""),
        "photo_path": contact.get("photo_path", ""),
        "signature": contact.get("signature_path", ""),
    }

    # Always emit a mailto link derived from the existing email.
    info["email_url"] = f"mailto:{contact['email']}"

    # Optional profile links. When present, forward <key>_url and
    # <key>_label (label derived from the URL when not supplied).
    # When absent, both are empty strings.
    for link_key in ("linkedin", "github", "website"):
        link = contact.get(link_key)
        if isinstance(link, dict):
            url = link["url"]
            label = link.get("label")
            if not (isinstance(label, str) and label.strip()):
                label = _derive_link_label(url)
            info[f"{link_key}_url"] = url
            info[f"{link_key}_label"] = label
        else:
            info[f"{link_key}_url"] = ""
            info[f"{link_key}_label"] = ""

    return info


def emit_latex(data: dict[str, Any], style: str, lang: str, out_dir: Path) -> list[str]:
    env = build_latex_env()
    out_dir.mkdir(parents=True, exist_ok=True)

    # Several example-CV styles share another style's templates (see
    # STYLE_TEMPLATE_DIRS); resolve the directory once here.
    tdir = _template_dir(style)

    sections: dict[str, tuple[str, dict[str, Any]]] = {
        "personal-info": (
            "personal-info.tex.j2",
            {
                "info": _personal_info(data, lang),
            },
        ),
        "experience": (
            f"{tdir}/experience.tex.j2",
            {
                "rows": _latex_experience(data, lang),
            },
        ),
        "education": (
            f"{tdir}/education.tex.j2",
            {
                "rows": _latex_education(data, lang),
            },
        ),
        "conferences": (
            f"{tdir}/conferences.tex.j2",
            {
                "groups": _latex_conferences(data, lang),
                "heatmap": _latex_conf_heatmap(data, lang),
            },
        ),
        "skills": (
            f"{tdir}/skills.tex.j2",
            {
                "rows": _latex_skills(data, lang),
                "concepts": _latex_concepts(data, lang),
            },
        ),
        "languages": (
            f"{tdir}/languages.tex.j2",
            {
                "rows": _latex_languages(data, lang),
            },
        ),
        "interests": (
            f"{tdir}/interests.tex.j2",
            {
                "items": _latex_interests(data, lang),
            },
        ),
        "certifications": (
            f"{tdir}/certifications.tex.j2",
            {
                "items": _latex_certifications(data, lang),
            },
        ),
    }

    written: list[str] = []
    for section, (template_name, context) in sections.items():
        # personal-info is style-agnostic.
        if section == "personal-info":
            template = env.get_template("personal-info.tex.j2")
        else:
            template = env.get_template(template_name)
        rendered = template.render(**context, lang=lang, style=style)
        target = out_dir / LATEX_SECTION_FILES[section]
        target.write_text(rendered, encoding="utf-8")
        written.append(target.name)
    return written


# --------------------------------------------------------------------------
# Web emission
# --------------------------------------------------------------------------
def emit_web(data: dict[str, Any], out_dir: Path) -> list[str]:
    env = build_web_env()
    out_dir.mkdir(parents=True, exist_ok=True)
    meta = data["meta"]

    roles = []
    for entry in data["experience"]:
        if not _has_target(entry, "web"):
            continue
        role = {
            "period": entry["period"]["en"],
            "year": entry["year"],
            "role": entry["role"]["en"],
            "org": entry["org"],
            "location": entry["location"]["en"],
            "kind": entry["kind"],
            "monogram": entry["monogram"],
            "bg": entry.get("bg"),
            "summary": entry["summary"]["en"],
            "tags": list(entry.get("tags", []) or []),
            "bullets": [b["en"] for b in entry.get("bullets", []) or []],
        }
        logo = entry.get("logo")
        if logo:  # Omit when null/absent.
            role["logo"] = logo
        roles.append(role)

    skills = [
        {"group": entry["group"]["en"], "items": list(entry["items"])}
        for entry in data["skills"]
        if _has_target(entry, "web")
    ]

    certifications = [
        entry["text"]["en"]
        for entry in data["certifications"]
        if _has_target(entry, "web")
    ]

    context = {
        "name": meta["display_name"],
        "title": meta["title"]["en"],
        "location": meta["location"]["en"],
        "summary": meta["summary"]["en"],
        "roles": roles,
        "skills": skills,
        "certifications": certifications,
    }

    template = env.get_template("web/cv.yml.j2")
    rendered = template.render(**context)
    target = out_dir / "cv.yml"
    target.write_text(rendered, encoding="utf-8")
    return [target.name]


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="data/cv.yml", type=Path)
    parser.add_argument("--mode", choices=["latex", "web"], default="latex")
    parser.add_argument("--style", choices=LATEX_STYLES, default="plain")
    parser.add_argument("--lang", choices=["de", "en"], default="de")
    parser.add_argument("--out-dir", dest="out_dir", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    try:
        data = load_cv(args.source)
        validate(data)
    except CheckError as exc:
        print(f"::error::cv/parse: {exc}", file=sys.stderr)
        return 1

    if args.check:
        print(f"cv/parse: {args.source} is valid.")
        return 0

    if args.out_dir is None:
        print("::error::cv/parse: --out-dir is required", file=sys.stderr)
        return 1

    try:
        if args.mode == "latex":
            written = emit_latex(data, args.style, args.lang, args.out_dir)
            print(
                f"cv/parse: wrote {len(written)} LaTeX file(s) "
                f"(style={args.style} lang={args.lang}) to {args.out_dir}: "
                f"{', '.join(written)}"
            )
        else:
            written = emit_web(data, args.out_dir)
            print(f"cv/parse: wrote {written[0]} to {args.out_dir}")
    except CheckError as exc:
        print(f"::error::cv/parse: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
