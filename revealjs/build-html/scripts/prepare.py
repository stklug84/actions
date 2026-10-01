#!/usr/bin/env python3
"""Front-matter contract and build planning for the revealjs/build-html action.

Pure transformation, no subprocesses: the bash wrapper (run.sh) owns every
tool invocation (pandoc, mermaid-cli, npm). This module

* extracts and STRICTLY validates the YAML front matter of a deck
  (unknown keys, duplicate keys and wrong types are rejected with a
  pinpointed message);
* resolves ``theme: <name>`` against the consumer's ``themes/<name>/``
  directory (theme.yml + theme.css + fonts) or a built-in reveal.js theme;
* emits the pandoc defaults files for the two passes (Markdown -> JSON AST
  with the Lua filters, JSON AST -> self-contained reveal.js HTML), the
  merged mermaid-cli configuration and a shell-friendly plan;
* embeds the theme fonts into the rendered Mermaid SVGs so diagrams keep
  their measured font when displayed as (font-isolated) images;
* verifies the final HTML (no remote resources, at least one slide).

Subcommands: check | check-themes | plan | finalize | embed-fonts | verify-html
"""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import html
import json
import re
import shlex
import shutil
import sys
from collections.abc import Hashable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

SIZES: dict[str, tuple[int, int]] = {
    "16:9": (1280, 720),
    "16:10": (1280, 800),
    "4:3": (1024, 768),
}
TRANSITIONS = ("none", "fade", "slide", "convex", "concave", "zoom")
NAVIGATION = ("default", "linear", "grid")
MATH_METHODS = ("katex", "mathml", "none")
HIGHLIGHT_STYLES = (
    "pygments",
    "kate",
    "monochrome",
    "breezedark",
    "espresso",
    "zenburn",
    "haddock",
    "tango",
    "none",
)
FONT_SUFFIXES = (".woff2", ".woff", ".ttf", ".otf")
FONT_STYLES = ("normal", "italic")
# Themes shipped in reveal.js 6 dist/theme/ (without the .css suffix).
BUILTIN_THEMES = (
    "beige",
    "black",
    "black-contrast",
    "blood",
    "dracula",
    "league",
    "moon",
    "night",
    "serif",
    "simple",
    "sky",
    "solarized",
    "white",
    "white-contrast",
)
FONT_MARKER = "<!-- deck-fonts -->"
PANDOC_FROM = "markdown+emoji"
# `size` also accepts an explicit "<width>x<height>" in pixels.
SIZE_RE = re.compile(r"^(\d{3,5})x(\d{3,5})$")
COLOR_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
FRONT_MATTER_RE = re.compile(r"\A---[ \t]*\r?\n(.*?)\r?\n(?:---|\.\.\.)[ \t]*\r?(?:\n|\Z)", re.S)
# Attributes/functions that pull remote resources into a supposedly
# self-contained deck (links `<a href>` are content and therefore allowed).
REMOTE_RE = re.compile(
    r"""(?:\bsrc|\bdata-src|\bdata-background-image|<link[^>]*\bhref)=["']https?://"""
    r"""|url\(\s*["']?https?://""",
    re.I,
)
SECTION_RE = re.compile(r"<(/?)section\b[^>]*>", re.I)


class SchemaError(Exception):
    """A front-matter / theme.yml contract violation."""

    def __init__(self, where: str, message: str) -> None:
        super().__init__(f"{where}: {message}")
        self.where = where
        self.message = message


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate mapping keys (PyYAML keeps the last)."""

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict[Hashable, Any]:
        seen: set[Hashable] = set()
        for key_node, _ in node.value:
            # Mapping keys are scalars in every schema we accept; compare their
            # raw text (construct_object is untyped in types-PyYAML).
            key: Hashable = key_node.value if isinstance(key_node, yaml.ScalarNode) else id(key_node)
            if key in seen:
                raise yaml.constructor.ConstructorError(
                    None,
                    None,
                    f"duplicate key {key!r}",
                    key_node.start_mark,
                )
            seen.add(key)
        return super().construct_mapping(node, deep=deep)


def load_yaml(text: str, where: str) -> Any:
    """yaml.safe_load semantics (StrictLoader is a SafeLoader) plus duplicate-key rejection."""
    loader = StrictLoader(text)
    try:
        return loader.get_single_data()
    except yaml.YAMLError as exc:
        raise SchemaError(where, f"invalid YAML: {exc}") from exc
    finally:
        loader.dispose()  # type: ignore[no-untyped-call]


# ---------------------------------------------------------------------------
# small typed accessors
# ---------------------------------------------------------------------------


def expect_mapping(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SchemaError(where, f"expected a mapping, got {type(value).__name__}")
    for key in value:
        if not isinstance(key, str):
            raise SchemaError(where, f"mapping keys must be strings, got {key!r}")
    return dict(value)


def expect_str(value: Any, where: str) -> str:
    # YAML parses unquoted `date: 2026-09-24` as a date; scalars of any
    # non-bool kind are accepted and rendered with str().
    if isinstance(value, bool) or not isinstance(value, (str, int, float, datetime.date)):
        raise SchemaError(where, f"expected a string, got {type(value).__name__}")
    text = str(value).strip()
    if not text:
        raise SchemaError(where, "must not be empty")
    return text


def expect_bool(value: Any, where: str) -> bool:
    if not isinstance(value, bool):
        raise SchemaError(where, f"expected true/false, got {type(value).__name__}")
    return value


def expect_int(value: Any, where: str, minimum: int = 0) -> int:
    if isinstance(value, bool):
        raise SchemaError(where, f"expected an integer, got {type(value).__name__}")
    if not isinstance(value, int):
        raise SchemaError(where, f"expected an integer, got {type(value).__name__}")
    number: int = value
    if number < minimum:
        raise SchemaError(where, f"must be >= {minimum}, got {number}")
    return number


def expect_choice(value: Any, where: str, choices: Iterable[str]) -> str:
    text = expect_str(value, where)
    options = tuple(choices)
    if text not in options:
        raise SchemaError(where, f"must be one of {', '.join(options)}; got {text!r}")
    return text


def expect_str_list(value: Any, where: str) -> list[str]:
    if isinstance(value, (str, int, float)) and not isinstance(value, bool):
        return [expect_str(value, where)]
    if not isinstance(value, list):
        raise SchemaError(where, f"expected a string or a list of strings, got {type(value).__name__}")
    return [expect_str(item, f"{where}[{i}]") for i, item in enumerate(value)]


def expect_color(value: Any, where: str) -> str:
    text = expect_str(value, where)
    if not COLOR_RE.match(text):
        raise SchemaError(where, f"expected a hex colour like #703873, got {text!r}")
    return text


def reject_unknown(mapping: dict[str, Any], allowed: Iterable[str], where: str) -> None:
    unknown = sorted(set(mapping) - set(allowed))
    if unknown:
        raise SchemaError(
            where,
            f"unknown key(s) {', '.join(repr(k) for k in unknown)}; allowed: {', '.join(sorted(allowed))}",
        )


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


# ---------------------------------------------------------------------------
# path containment
# ---------------------------------------------------------------------------


def workspace_root() -> Path:
    return Path.cwd().resolve()


def ensure_within(path: Path, where: str, must_exist: bool = True) -> Path:
    """Resolve *path* (following symlinks) and require it inside the workspace."""
    root = workspace_root()
    resolved = path.resolve()
    if resolved != root and root not in resolved.parents:
        raise SchemaError(where, f"path {path} escapes the workspace {root}")
    if must_exist and not resolved.exists():
        raise SchemaError(where, f"file not found: {path}")
    return resolved


def rel(path: Path) -> str:
    """Workspace-relative POSIX path (pandoc runs with cwd = workspace)."""
    resolved = path.resolve()
    try:
        return resolved.relative_to(workspace_root()).as_posix()
    except ValueError:
        return resolved.as_posix()


# ---------------------------------------------------------------------------
# theme
# ---------------------------------------------------------------------------


@dataclass
class FontSpec:
    file: Path
    family: str
    weight: int
    style: str


@dataclass
class Theme:
    name: str
    base: str
    directory: Path | None = None
    css: list[Path] = field(default_factory=list)
    highlight: str = "kate"
    divider_background: str | None = None
    title_slide: dict[str, str] = field(default_factory=dict)
    logo: Path | None = None
    footer: str | None = None
    fonts: list[FontSpec] = field(default_factory=list)
    reveal: dict[str, Any] = field(default_factory=dict)
    mermaid: dict[str, Any] = field(default_factory=dict)


THEME_KEYS = (
    "name",
    "base",
    "css",
    "highlight",
    "divider-background",
    "title-slide",
    "logo",
    "footer",
    "fonts",
    "reveal",
    "mermaid",
)
TITLE_SLIDE_KEYS = ("class", "background")
FONT_KEYS = ("file", "family", "weight", "style")


def parse_title_slide(value: Any, where: str) -> dict[str, str]:
    mapping = expect_mapping(value, where)
    reject_unknown(mapping, TITLE_SLIDE_KEYS, where)
    result: dict[str, str] = {}
    if "class" in mapping:
        result["class"] = expect_str(mapping["class"], f"{where}.class")
    if "background" in mapping:
        result["data-background-color"] = expect_color(mapping["background"], f"{where}.background")
    return result


def parse_fonts(value: Any, theme_dir: Path, where: str) -> list[FontSpec]:
    if not isinstance(value, list):
        raise SchemaError(where, "expected a list of {file, family, weight, style} mappings")
    fonts: list[FontSpec] = []
    for i, item in enumerate(value):
        loc = f"{where}[{i}]"
        mapping = expect_mapping(item, loc)
        reject_unknown(mapping, FONT_KEYS, loc)
        if "file" not in mapping or "family" not in mapping:
            raise SchemaError(loc, "requires 'file' and 'family'")
        file = ensure_within(theme_dir / expect_str(mapping["file"], f"{loc}.file"), f"{loc}.file")
        if file.suffix.lower() not in FONT_SUFFIXES:
            raise SchemaError(f"{loc}.file", f"font files must be one of {', '.join(FONT_SUFFIXES)}")
        weight = expect_int(mapping.get("weight", 400), f"{loc}.weight", minimum=1)
        style = expect_choice(mapping.get("style", "normal"), f"{loc}.style", FONT_STYLES)
        fonts.append(FontSpec(file, expect_str(mapping["family"], f"{loc}.family"), weight, style))
    return fonts


def load_theme_dir(theme_dir: Path, name: str) -> Theme:
    where = rel(theme_dir / "theme.yml")
    theme_yml = theme_dir / "theme.yml"
    if not theme_yml.is_file():
        raise SchemaError(where, "theme directory has no theme.yml")
    data = load_yaml(theme_yml.read_text(encoding="utf-8"), where)
    mapping = expect_mapping(data if data is not None else {}, where)
    reject_unknown(mapping, THEME_KEYS, where)
    if "name" in mapping and expect_str(mapping["name"], f"{where}:name") != name:
        raise SchemaError(f"{where}:name", f"must match the directory name {name!r}")
    theme = Theme(name=name, base=expect_choice(mapping.get("base", "white"), f"{where}:base", BUILTIN_THEMES))
    theme.directory = theme_dir
    css_names = expect_str_list(mapping.get("css", ["theme.css"]), f"{where}:css")
    theme.css = [ensure_within(theme_dir / c, f"{where}:css") for c in css_names]
    theme.highlight = expect_choice(mapping.get("highlight", "kate"), f"{where}:highlight", HIGHLIGHT_STYLES)
    if mapping.get("divider-background") is not None:
        theme.divider_background = expect_color(mapping["divider-background"], f"{where}:divider-background")
    if "title-slide" in mapping:
        theme.title_slide = parse_title_slide(mapping["title-slide"], f"{where}:title-slide")
    if mapping.get("logo") is not None:
        theme.logo = ensure_within(theme_dir / expect_str(mapping["logo"], f"{where}:logo"), f"{where}:logo")
    if mapping.get("footer") is not None:
        theme.footer = expect_str(mapping["footer"], f"{where}:footer")
    if "fonts" in mapping:
        theme.fonts = parse_fonts(mapping["fonts"], theme_dir, f"{where}:fonts")
    if "reveal" in mapping:
        theme.reveal = expect_mapping(mapping["reveal"], f"{where}:reveal")
    if "mermaid" in mapping:
        theme.mermaid = expect_mapping(mapping["mermaid"], f"{where}:mermaid")
    return theme


def resolve_theme(name: str, themes_dir: Path, where: str) -> Theme:
    candidate = themes_dir / name
    if candidate.is_dir():
        ensure_within(candidate, where)
        return load_theme_dir(candidate, name)
    if name in BUILTIN_THEMES:
        return Theme(name=name, base=name)
    available = sorted(p.name for p in themes_dir.iterdir() if p.is_dir()) if themes_dir.is_dir() else []
    raise SchemaError(
        where,
        f"unknown theme {name!r}; available: "
        f"{', '.join(available) or '(none)'} in {themes_dir}/ plus the built-in reveal.js themes "
        f"{', '.join(BUILTIN_THEMES)}",
    )


# ---------------------------------------------------------------------------
# front matter
# ---------------------------------------------------------------------------

STANDARD_KEYS = ("title", "subtitle", "author", "date", "institute", "lang", "keywords")
DECK_KEYS = (
    "theme",
    "css",
    "size",
    "slide-level",
    "slide-number",
    "transition",
    "navigation",
    "center",
    "logo",
    "footer",
    "math",
    "highlight",
    "mermaid",
    "pdf",
    "reveal",
    "title-slide",
)
PDF_KEYS = ("size", "fragments", "pause", "load-pause")
DEFAULT_PDF_PAUSE_MS = 500
DEFAULT_PDF_LOAD_PAUSE_MS = 2000


@dataclass
class Deck:
    source: Path
    directory: Path
    front_matter: dict[str, Any]
    title: str
    theme: Theme
    width: int
    height: int
    pdf_width: int
    pdf_height: int
    pdf_fragments: bool
    pdf_pause: int
    pdf_load_pause: int
    css: list[Path]
    logo: Path | None
    footer: str | None
    math: str
    highlight: str
    slide_level: int | None
    reveal: dict[str, Any]
    mermaid: dict[str, Any]
    title_slide: dict[str, str]
    divider_background: str | None
    author: str


def split_front_matter(text: str, where: str) -> dict[str, Any]:
    match = FRONT_MATTER_RE.match(text)
    if not match:
        raise SchemaError(
            where, "the deck must start with a YAML front matter block (--- ... ---) carrying at least `title`"
        )
    data = load_yaml(match.group(1), where)
    return expect_mapping(data if data is not None else {}, where)


def parse_size(value: Any, where: str) -> tuple[int, int]:
    text = expect_str(value, where)
    if text in SIZES:
        return SIZES[text]
    match = SIZE_RE.match(text)
    if not match:
        raise SchemaError(where, f"expected one of {', '.join(SIZES)} or <width>x<height>, got {text!r}")
    return int(match.group(1)), int(match.group(2))


def parse_deck(source: Path, themes_dir: Path) -> Deck:
    where = rel(source)
    ensure_within(source, where)
    fm = split_front_matter(source.read_text(encoding="utf-8"), where)
    reject_unknown(fm, STANDARD_KEYS + DECK_KEYS, where)
    if "title" not in fm:
        raise SchemaError(where, "front matter requires `title`")
    title = expect_str(fm["title"], f"{where}:title")
    for key in ("subtitle", "lang"):
        if key in fm:
            expect_str(fm[key], f"{where}:{key}")
    authors = expect_str_list(fm["author"], f"{where}:author") if "author" in fm else []
    if "institute" in fm:
        expect_str_list(fm["institute"], f"{where}:institute")
    if "keywords" in fm:
        expect_str_list(fm["keywords"], f"{where}:keywords")
    if "date" in fm:
        expect_str(fm["date"], f"{where}:date")

    theme = resolve_theme(expect_str(fm.get("theme", "white"), f"{where}:theme"), themes_dir, f"{where}:theme")
    deck_dir = source.parent

    width, height = parse_size(fm.get("size", "16:9"), f"{where}:size")
    pdf_width, pdf_height = width, height
    pdf_fragments = False
    pdf_pause = DEFAULT_PDF_PAUSE_MS
    pdf_load_pause = DEFAULT_PDF_LOAD_PAUSE_MS
    if "pdf" in fm:
        pdf = expect_mapping(fm["pdf"], f"{where}:pdf")
        reject_unknown(pdf, PDF_KEYS, f"{where}:pdf")
        if "size" in pdf:
            pdf_width, pdf_height = parse_size(pdf["size"], f"{where}:pdf.size")
        if "fragments" in pdf:
            pdf_fragments = expect_bool(pdf["fragments"], f"{where}:pdf.fragments")
        if "pause" in pdf:
            pdf_pause = expect_int(pdf["pause"], f"{where}:pdf.pause")
        if "load-pause" in pdf:
            pdf_load_pause = expect_int(pdf["load-pause"], f"{where}:pdf.load-pause")

    css = list(theme.css)
    if "css" in fm:
        css.extend(ensure_within(deck_dir / c, f"{where}:css") for c in expect_str_list(fm["css"], f"{where}:css"))

    logo: Path | None = theme.logo
    if "logo" in fm:
        if fm["logo"] is False:
            logo = None
        else:
            logo = ensure_within(deck_dir / expect_str(fm["logo"], f"{where}:logo"), f"{where}:logo")
    footer: str | None = theme.footer
    if "footer" in fm:
        footer = None if fm["footer"] is False else expect_str(fm["footer"], f"{where}:footer")

    math = expect_choice(fm.get("math", "katex"), f"{where}:math", MATH_METHODS)
    highlight = expect_choice(fm.get("highlight", theme.highlight), f"{where}:highlight", HIGHLIGHT_STYLES)
    slide_level: int | None = None
    if "slide-level" in fm:
        slide_level = expect_int(fm["slide-level"], f"{where}:slide-level", minimum=1)
        if slide_level > 2:
            raise SchemaError(f"{where}:slide-level", "must be 1 or 2")

    # reveal.js configuration: defaults < theme.reveal < front-matter keys < reveal passthrough.
    reveal: dict[str, Any] = {
        "hash": True,
        "controls": True,
        "progress": True,
        "slideNumber": "c/t",
        "showSlideNumber": "all",
        "transition": "fade",
        "navigationMode": "default",
        "pdfSeparateFragments": False,
        "margin": 0.06,
    }
    reveal = deep_merge(reveal, theme.reveal)
    if "slide-number" in fm:
        value = fm["slide-number"]
        reveal["slideNumber"] = value if isinstance(value, bool) else expect_str(value, f"{where}:slide-number")
    if "transition" in fm:
        reveal["transition"] = expect_choice(fm["transition"], f"{where}:transition", TRANSITIONS)
    if "navigation" in fm:
        reveal["navigationMode"] = expect_choice(fm["navigation"], f"{where}:navigation", NAVIGATION)
    if "center" in fm:
        reveal["center"] = expect_bool(fm["center"], f"{where}:center")
    if "reveal" in fm:
        reveal = deep_merge(reveal, expect_mapping(fm["reveal"], f"{where}:reveal"))
    reveal["width"] = width
    reveal["height"] = height

    mermaid: dict[str, Any] = {"theme": "base", "htmlLabels": False, "flowchart": {"htmlLabels": False}}
    mermaid = deep_merge(mermaid, theme.mermaid)
    if "mermaid" in fm:
        mermaid = deep_merge(mermaid, expect_mapping(fm["mermaid"], f"{where}:mermaid"))

    title_slide = dict(theme.title_slide)
    if "title-slide" in fm:
        title_slide.update(parse_title_slide(fm["title-slide"], f"{where}:title-slide"))

    return Deck(
        source=source.resolve(),
        directory=deck_dir.resolve(),
        front_matter=fm,
        title=title,
        theme=theme,
        width=width,
        height=height,
        pdf_width=pdf_width,
        pdf_height=pdf_height,
        pdf_fragments=pdf_fragments,
        pdf_pause=pdf_pause,
        pdf_load_pause=pdf_load_pause,
        css=css,
        logo=logo,
        footer=footer,
        math=math,
        highlight=highlight,
        slide_level=slide_level,
        reveal=reveal,
        mermaid=mermaid,
        title_slide=title_slide,
        divider_background=theme.divider_background,
        author=", ".join(authors),
    )


# ---------------------------------------------------------------------------
# plan / finalize
# ---------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def mermaid_salt(deck: Deck, mermaid_image: str) -> str:
    """Cache identity of a rendered diagram: config + fonts + renderer."""
    digest = hashlib.sha256()
    digest.update(json.dumps(deck.mermaid, sort_keys=True).encode())
    for font in deck.theme.fonts:
        digest.update(f"{font.family}|{font.weight}|{font.style}|".encode())
        digest.update(sha256_file(font.file).encode())
    digest.update(mermaid_image.encode())
    digest.update(b"|deck-fonts-v1")
    return digest.hexdigest()


def json_for_script(value: Any) -> str:
    """JSON that is safe inside a <script> element (`<` never appears), pretty-printed."""
    return json.dumps(value, sort_keys=True, indent=2).replace("<", "\\u003c")


class IndentedDumper(yaml.SafeDumper):
    """SafeDumper that indents block sequences (yamllint's default expectation)."""

    def increase_indent(self, flow: bool = False, indentless: bool = False) -> None:
        super().increase_indent(flow, False)


class LiteralStr(str):
    """A string dumped as a YAML literal block scalar (keeps lines short for yamllint)."""


def _literal_representer(dumper: yaml.SafeDumper, data: LiteralStr) -> yaml.ScalarNode:
    return dumper.represent_scalar("tag:yaml.org,2002:str", str(data), style="|")


IndentedDumper.add_representer(LiteralStr, _literal_representer)


def write_yaml(path: Path, data: dict[str, Any]) -> None:
    body = yaml.dump(data, Dumper=IndentedDumper, sort_keys=False, allow_unicode=True, width=1000)
    path.write_text("---\n" + body, encoding="utf-8")


def write_env(path: Path, values: dict[str, str]) -> None:
    lines = [f"{key}={shlex.quote(value)}" for key, value in values.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_plan(args: argparse.Namespace) -> int:
    deck = parse_deck(Path(args.source), Path(args.themes_dir))
    build = Path(args.build_dir)
    for sub in ("mermaid", "fonts", "logs"):
        (build / sub).mkdir(parents=True, exist_ok=True)
    engine = build / "engine"
    out_html = Path(args.out_dir) / f"{args.name}.html"

    # Fonts: staged into one directory (mounted into the mermaid container
    # as system fonts) and embedded into the SVGs afterwards.
    fonts: list[dict[str, Any]] = []
    for font in deck.theme.fonts:
        target = build / "fonts" / font.file.name
        shutil.copy2(font.file, target)
        fonts.append({"file": rel(target), "family": font.family, "weight": font.weight, "style": font.style})

    salt = mermaid_salt(deck, args.mermaid_image)
    metadata: dict[str, Any] = {
        "mermaid-dir": rel(build / "mermaid"),
        "mermaid-salt": salt,
        "structure-file": rel(build / "structure.json"),
    }
    if deck.divider_background:
        metadata["divider-background"] = deck.divider_background
    if deck.title_slide:
        metadata["title-slide-attributes"] = deck.title_slide
    write_yaml(build / "metadata.yml", metadata)

    write_yaml(
        build / "pass1.yml",
        {
            "from": PANDOC_FROM,
            "to": "json",
            "input-file": rel(deck.source),
            "output-file": rel(build / "ast.json"),
            "metadata-files": [rel(build / "metadata.yml")],
            "filters": [rel(engine / "filters" / "mermaid.lua"), rel(engine / "filters" / "structure.lua")],
            "resource-path": [".", rel(deck.directory)],
        },
    )
    (build / "mermaid.json").write_text(json.dumps(deck.mermaid, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    plan: dict[str, Any] = {
        "name": args.name,
        "source": rel(deck.source),
        "deck_dir": rel(deck.directory),
        "build_dir": rel(build),
        "out_html": out_html.as_posix(),
        "title": deck.title,
        "author": deck.author,
        "theme": deck.theme.name,
        "theme_base": deck.theme.base,
        "css": [rel(c) for c in deck.css],
        "logo": rel(deck.logo) if deck.logo else None,
        "footer": deck.footer,
        "math": deck.math,
        "highlight": deck.highlight,
        "slide_level": deck.slide_level,
        "width": deck.width,
        "height": deck.height,
        "pdf": {
            "width": deck.pdf_width,
            "height": deck.pdf_height,
            "fragments": deck.pdf_fragments,
            "pause": deck.pdf_pause,
            "load_pause": deck.pdf_load_pause,
        },
        "reveal": deck.reveal,
        "mermaid": deck.mermaid,
        "mermaid_salt": salt,
        "fonts": fonts,
        "vendor_dir": rel(build / "vendor"),
        "engine_dir": rel(engine),
    }
    (build / "plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_env(
        build / "plan.env",
        {
            "DECK_NAME": args.name,
            "DECK_SOURCE": plan["source"],
            "DECK_DIR": plan["deck_dir"],
            "DECK_TITLE": deck.title,
            "DECK_AUTHOR": deck.author,
            "DECK_THEME": deck.theme.name,
            "OUT_HTML": plan["out_html"],
            "WIDTH": str(deck.width),
            "HEIGHT": str(deck.height),
            "PDF_WIDTH": str(deck.pdf_width),
            "PDF_HEIGHT": str(deck.pdf_height),
            "PDF_FRAGMENTS": "true" if deck.pdf_fragments else "false",
            "PDF_PAUSE": str(deck.pdf_pause),
            "PDF_LOAD_PAUSE": str(deck.pdf_load_pause),
            "FONTS_DIR": rel(build / "fonts"),
            "FONT_COUNT": str(len(fonts)),
            "MERMAID_DIR": rel(build / "mermaid"),
        },
    )
    print(
        f"planned deck '{args.name}': theme={deck.theme.name} (base {deck.theme.base}) size={deck.width}x{deck.height}"
    )
    return 0


def cmd_finalize(args: argparse.Namespace) -> int:
    build = Path(args.build_dir)
    plan = json.loads((build / "plan.json").read_text(encoding="utf-8"))
    structure = json.loads((build / "structure.json").read_text(encoding="utf-8"))
    slide_level = int(plan["slide_level"] or structure["slide_level"])
    if slide_level != int(structure["slide_level"]):
        raise SchemaError(rel(build / "structure.json"), "slide level disagrees with the structure filter")

    variables: dict[str, Any] = {
        "revealjs-url": f"{plan['vendor_dir']}/reveal.js",
        "deck-theme-base": plan["theme_base"],
        "deck-css": plan["css"],
        "reveal-config": LiteralStr(json_for_script(plan["reveal"])),
    }
    if plan["logo"]:
        variables["deck-logo"] = plan["logo"]
    if plan["footer"]:
        # Footer is plain text: escape it here, the template inserts it verbatim.
        variables["deck-footer"] = html.escape(str(plan["footer"]), quote=False)

    defaults: dict[str, Any] = {
        "from": "json",
        "to": "revealjs",
        "input-file": f"{plan['build_dir']}/ast.json",
        "output-file": plan["out_html"],
        "standalone": True,
        "embed-resources": True,
        "template": f"{plan['engine_dir']}/default.revealjs",
        "slide-level": slide_level,
        "resource-path": [".", plan["deck_dir"]],
        "variables": variables,
    }
    if plan["highlight"] == "none":
        defaults["syntax-highlighting"] = "none"
    else:
        defaults["syntax-highlighting"] = plan["highlight"]
    if plan["math"] == "katex":
        defaults["html-math-method"] = {"method": "katex", "url": f"{plan['vendor_dir']}/katex/dist/"}
    elif plan["math"] == "mathml":
        defaults["html-math-method"] = {"method": "mathml"}
    else:
        defaults["html-math-method"] = {"method": "plain"}
    write_yaml(build / "pass2.yml", defaults)
    print(f"finalized deck '{plan['name']}': slide-level={slide_level} headings={structure.get('headings')}")
    return 0


# ---------------------------------------------------------------------------
# embed-fonts / verify-html
# ---------------------------------------------------------------------------


def font_face_css(fonts: list[dict[str, Any]]) -> str:
    rules: list[str] = []
    for font in fonts:
        path = Path(str(font["file"]))
        suffix = path.suffix.lower().lstrip(".")
        fmt = {"ttf": "truetype", "otf": "opentype"}.get(suffix, suffix)
        data = base64.b64encode(path.read_bytes()).decode("ascii")
        mime = {"woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf"}[suffix]
        family = json.dumps(font["family"])
        rules.append(
            f"@font-face{{font-family:{family};font-weight:{int(font['weight'])};font-style:{font['style']};"
            f"src:url(data:{mime};base64,{data}) format({json.dumps(fmt)})}}"
        )
    return "".join(rules)


def mermaid_font_family(config: dict[str, Any]) -> str | None:
    variables = config.get("themeVariables")
    if not isinstance(variables, dict):
        return None
    family = variables.get("fontFamily")
    if not isinstance(family, str) or not family.strip():
        return None
    return family.split(",")[0].strip().strip("'\"")


def cmd_embed_fonts(args: argparse.Namespace) -> int:
    build = Path(args.build_dir)
    plan = json.loads((build / "plan.json").read_text(encoding="utf-8"))
    family = mermaid_font_family(plan["mermaid"])
    fonts = [f for f in plan["fonts"] if family and f["family"] == family]
    svgs = sorted((build / "mermaid").glob("*.svg"))
    if not svgs:
        print("embed-fonts: no diagrams")
        return 0
    if not fonts:
        print(f"embed-fonts: no theme font matches the mermaid fontFamily {family!r}; SVGs left untouched")
        return 0
    css = font_face_css(fonts)
    done = 0
    for svg in svgs:
        text = svg.read_text(encoding="utf-8")
        if FONT_MARKER in text:
            continue
        end = text.find(">", text.find("<svg"))
        if end < 0:
            raise SchemaError(rel(svg), "no <svg> element found")
        text = text[: end + 1] + FONT_MARKER + "<style>" + css + "</style>" + text[end + 1 :]
        svg.write_text(text, encoding="utf-8")
        done += 1
    print(f"embed-fonts: embedded {len(fonts)} font file(s) for {family!r} into {done} SVG(s)")
    return 0


def leaf_slide_count(text: str) -> int:
    """Count <section> elements without nested <section> children."""
    stack: list[bool] = []
    leaves = 0
    for match in SECTION_RE.finditer(text):
        if match.group(1) == "":
            if stack:
                stack[-1] = True
            stack.append(False)
        elif stack:
            has_children = stack.pop()
            if not has_children:
                leaves += 1
    return leaves


def cmd_verify_html(args: argparse.Namespace) -> int:
    path = Path(args.html)
    if not path.is_file() or path.stat().st_size == 0:
        raise SchemaError(str(path), "HTML output missing or empty")
    text = path.read_text(encoding="utf-8")
    remote = REMOTE_RE.findall(text)
    if remote:
        raise SchemaError(
            str(path),
            f"{len(remote)} remote resource reference(s) survived --embed-resources "
            f"(the deck must be self-contained); first: {remote[0]!r}",
        )
    if 'class="reveal"' not in text:
        raise SchemaError(str(path), "not a reveal.js document (no .reveal container)")
    slides = leaf_slide_count(text)
    if slides < 1:
        raise SchemaError(str(path), "no slides found")
    result = {"slides": slides, "bytes": path.stat().st_size}
    Path(args.build_dir, "html.json").write_text(json.dumps(result) + "\n", encoding="utf-8")
    print(f"slides={slides}")
    print(f"bytes={result['bytes']}")
    return 0


# ---------------------------------------------------------------------------
# check / check-themes
# ---------------------------------------------------------------------------


def cmd_check(args: argparse.Namespace) -> int:
    deck = parse_deck(Path(args.source), Path(args.themes_dir))
    print(f"ok: {rel(deck.source)} (title={deck.title!r}, theme={deck.theme.name}, size={deck.width}x{deck.height})")
    return 0


def cmd_check_themes(args: argparse.Namespace) -> int:
    themes_dir = Path(args.themes_dir)
    if not themes_dir.is_dir():
        raise SchemaError(str(themes_dir), "themes directory not found")
    names = sorted(p.name for p in themes_dir.iterdir() if p.is_dir())
    if not names:
        raise SchemaError(str(themes_dir), "no theme directories found")
    for name in names:
        ensure_within(themes_dir / name, str(themes_dir / name))
        theme = load_theme_dir(themes_dir / name, name)
        print(f"ok: theme {name} (base {theme.base}, {len(theme.css)} css, {len(theme.fonts)} fonts)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="validate a deck's front matter and theme")
    check.add_argument("--source", required=True)
    check.add_argument("--themes-dir", default="themes")
    check.set_defaults(func=cmd_check)

    themes = sub.add_parser("check-themes", help="validate every theme directory")
    themes.add_argument("--themes-dir", default="themes")
    themes.set_defaults(func=cmd_check_themes)

    plan = sub.add_parser("plan", help="write pass-1 defaults, metadata and the build plan")
    plan.add_argument("--source", required=True)
    plan.add_argument("--themes-dir", default="themes")
    plan.add_argument("--name", required=True)
    plan.add_argument("--build-dir", required=True)
    plan.add_argument("--out-dir", required=True)
    plan.add_argument("--mermaid-image", default="")
    plan.set_defaults(func=cmd_plan)

    finalize = sub.add_parser("finalize", help="write pass-2 defaults from the plan and the structure summary")
    finalize.add_argument("--build-dir", required=True)
    finalize.set_defaults(func=cmd_finalize)

    embed = sub.add_parser("embed-fonts", help="embed the theme fonts into the rendered Mermaid SVGs")
    embed.add_argument("--build-dir", required=True)
    embed.set_defaults(func=cmd_embed_fonts)

    verify = sub.add_parser("verify-html", help="verify the self-contained HTML deck")
    verify.add_argument("--html", required=True)
    verify.add_argument("--build-dir", required=True)
    verify.set_defaults(func=cmd_verify_html)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result: int = args.func(args)
    except SchemaError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return result


if __name__ == "__main__":
    sys.exit(main())
