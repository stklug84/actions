#!/usr/bin/env python3
"""Manifest-driven CV variant generator (cv/generate composite action).

Reads a build matrix manifest and, for every ``cvs.<yaml>`` entry's
``{style, lang}`` leaf, creates

    <cvs-root>/<yaml>-<lang>/<style>/<main>.tex   (+ .engine + bodies)

The leaf main is rendered from ``<templates-dir>/<style>.tex.j2`` (Jinja2),
parameterised entirely from the manifest -- no style/lang/yaml mapping is
hardcoded, so any (yaml x style x lang) combination declared in the
manifest is generated correctly.

Section bodies (cv-*.tex) and personal-info.tex are produced by the
cv/parse emitter (``--parse-py``). When it is not given, the generator
falls back to copying committed bodies from an existing leaf so the tree
still builds offline.

Usage:
    render_variants.py --manifest PATH --templates-dir PATH
                       --cvs-root PATH --data-dir PATH
                       [--main-name NAME] [--parse-py PATH] [--check]
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess  # nosec B404 - only fixed argv lists, never shell=True
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML is required (pip install pyyaml)")

try:
    from jinja2 import (
        Environment,
        FileSystemLoader,
        StrictUndefined,
        select_autoescape,
    )
except ImportError:
    sys.exit("error: Jinja2 is required (pip install jinja2)")

# We use ``select_autoescape`` rather than a constant ``autoescape=False``
# so the decision is made per-template by extension: HTML/XML templates
# (should one ever be added) are escaped, while ``.tex`` mains are not.
# This keeps the LaTeX-output behavior while avoiding a blanket, always-off
# autoescape that disables protection for any future HTML template. Mirrors
# cv/parse/scripts/parse.py.
_AUTOESCAPE = select_autoescape(
    enabled_extensions=("html", "htm", "xml"),
    default_for_string=False,
    default=False,
)

# Type aliases kept loose: the manifest is user YAML, the render context is
# a flat str->str mapping consumed by Jinja2.
Manifest = dict[str, Any]
Context = dict[str, str]

SECTION_FILES: list[str] = [
    "personal-info.tex",
    "cv-experience.tex",
    "cv-education.tex",
    "cv-conferences.tex",
    "cv-skills.tex",
    "cv-languages.tex",
    "cv-interests.tex",
    "cv-certifications.tex",
]


def load_manifest(path: Path) -> Manifest:
    with path.open(encoding="utf-8") as fh:
        data: Manifest = yaml.safe_load(fh)
    for key in ("styles", "langs", "cvs"):
        if key not in data:
            sys.exit(f"error: manifest missing required key: {key!r}")
    return data


def expand_matrix(manifest: Manifest) -> Iterator[Context]:
    styles = manifest["styles"]
    langs = manifest["langs"]
    for yaml_name, entries in manifest["cvs"].items():
        for entry in entries:
            style = entry["style"]
            lang = entry["lang"]
            if style not in styles:
                sys.exit(
                    f"error: {yaml_name}: unknown style {style!r} "
                    f"(add it to manifest 'styles')"
                )
            if lang not in langs:
                sys.exit(
                    f"error: {yaml_name}: unknown lang {lang!r} "
                    f"(add it to manifest 'langs')"
                )
            sreg = styles[style]
            lreg = dict(langs[lang])
            ctx: Context = {
                "yaml_name": str(yaml_name),
                "style": str(style),
                "lang": str(lang),
                "engine": str(sreg["engine"]),
                "parse_style": str(sreg["parse_style"]),
                "babel": str(lreg.get("babel", "")),
                "polyglossia": str(lreg.get("polyglossia", "")),
            }
            for label_key, label_value in lreg.items():
                if str(label_key).startswith("label_"):
                    ctx[str(label_key)] = str(label_value)
            yield ctx


def render_main(env: Environment, ctx: Context, dest: Path) -> None:
    template = env.get_template(f"{ctx['style']}.tex.j2")
    dest.write_text(template.render(**ctx) + "\n", encoding="utf-8")


_DONOR_CACHE: list[Path] = []


def find_body_donor(cvs_root: Path) -> Path | None:
    if _DONOR_CACHE:
        return _DONOR_CACHE[0]
    if not cvs_root.is_dir():
        return None
    for path in sorted(cvs_root.rglob("cv-experience.tex")):
        _DONOR_CACHE.append(path.parent)
        return path.parent
    return None


def emit_bodies(
    ctx: Context,
    leaf: Path,
    data_dir: Path,
    cvs_root: Path,
    parse_py: str | None,
) -> None:
    source = data_dir / f"{ctx['yaml_name']}.yml"
    if parse_py:
        subprocess.run(  # nosec B603 - args are program-controlled
            [
                sys.executable,
                parse_py,
                "--source",
                str(source),
                "--mode",
                "latex",
                "--style",
                ctx["parse_style"],
                "--lang",
                ctx["lang"],
                "--out-dir",
                str(leaf),
            ],
            check=True,
        )
        return
    donor = find_body_donor(cvs_root)
    if donor is None:
        print(
            f"warning: no cv/parse emitter and no committed bodies found; "
            f"leaf {leaf} has no section bodies",
            file=sys.stderr,
        )
        return
    for name in SECTION_FILES:
        src = donor / name
        if src.exists():
            shutil.copyfile(src, leaf / name)


def run_check(manifest: Manifest, data_dir: Path, parse_py: str | None) -> int:
    if not parse_py:
        sys.exit("error: --check requires the cv/parse emitter (--parse-py)")
    rc = 0
    for yaml_name in manifest["cvs"]:
        source = data_dir / f"{yaml_name}.yml"
        print(f"Checking {source} against the cv/parse schema")
        result = subprocess.run(  # nosec B603 - args are program-controlled
            [sys.executable, parse_py, "--source", str(source), "--check"]
        )
        rc = rc or result.returncode
    return rc


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--templates-dir", required=True)
    parser.add_argument("--cvs-root", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--main-name", default="sklug-cv")
    parser.add_argument("--parse-py")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest)
    templates_dir = Path(args.templates_dir)
    cvs_root = Path(args.cvs_root)
    data_dir = Path(args.data_dir)
    parse_py: str | None = args.parse_py or os.environ.get("PARSE_PY")
    if parse_py and not Path(parse_py).is_file():
        sys.exit(f"error: cv/parse emitter not found at: {parse_py}")

    manifest = load_manifest(manifest_path)

    if args.check:
        return run_check(manifest, data_dir, parse_py)

    env = Environment(  # nosec B701  # uses select_autoescape
        loader=FileSystemLoader(str(templates_dir)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        autoescape=_AUTOESCAPE,
    )

    main_file = f"{args.main_name}.tex"
    count = 0
    for ctx in expand_matrix(manifest):
        leaf = cvs_root / f"{ctx['yaml_name']}-{ctx['lang']}" / ctx["style"]
        leaf.mkdir(parents=True, exist_ok=True)
        (leaf / ".engine").write_text(ctx["engine"] + "\n", encoding="utf-8")
        render_main(env, ctx, leaf / main_file)
        emit_bodies(ctx, leaf, data_dir, cvs_root, parse_py)
        print(f"Generated {ctx['style']} (lang={ctx['lang']}) into {leaf}/")
        count += 1

    print(f"Done. {count} variant(s) generated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
