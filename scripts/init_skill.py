#!/usr/bin/env python3
"""Scaffold a new Agent Skill bundle.

The "official" skill layout used by Anthropic Claude skills, OpenAI Codex and
other harnesses is a directory bundle:

    <skill-name>/
    |- SKILL.md            (required: YAML frontmatter + instructions)
    |- agents/
    |  `- openai.yaml      (optional: product-specific UI metadata)
    |- references/         (optional: docs loaded on demand)
    |- scripts/            (optional: executable helpers)
    `- assets/             (optional: icons / templates / static files)

Usage:
    python scripts/init_skill.py <skill-name> [--path DIR] [--resources ...]

Examples:
    python scripts/init_skill.py fetch-picture-word --path skill
    python scripts/init_skill.py pdf-tools --path skill --resources scripts assets
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_NAME = 64
MAX_DESC = 1024

RESOURCE_DIRS = ("references", "scripts", "assets", "examples")

SKILL_TEMPLATE = """---
name: {name}
description: {description}
---

# {title}

One or two sentences on what this skill does and when to use it.

## When to use

- Trigger 1
- Trigger 2

## Workflow

1. Step one.
2. Step two.

## Notes

- Keep the body short; put long material in `references/` and load it on demand.
"""

OPENAI_YAML_TEMPLATE = """interface:
  display_name: "{display_name}"
  short_description: "{short_description}"
  default_prompt: "Use ${name} to {prompt_tail}."

policy:
  allow_implicit_invocation: true
"""


def titleize(name: str) -> str:
    return " ".join(word.capitalize() for word in name.split("-"))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="init_skill.py",
        description="Create a new skill bundle (SKILL.md + agents/openai.yaml).",
    )
    parser.add_argument("name", help="skill name in kebab-case, e.g. fetch-picture-word")
    parser.add_argument(
        "--path",
        default=".",
        help="parent directory that will contain the skill folder (default: .)",
    )
    parser.add_argument(
        "--resources",
        nargs="*",
        default=[],
        choices=list(RESOURCE_DIRS),
        help="optional extra directories to create inside the bundle",
    )
    parser.add_argument(
        "--description",
        default=None,
        help="frontmatter description (default: a generated placeholder)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="write into an existing skill directory instead of failing",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    if not NAME_RE.match(args.name) or len(args.name) > MAX_NAME:
        print(
            f"error: invalid skill name {args.name!r}: use kebab-case "
            f"(lowercase letters, digits, single hyphens), max {MAX_NAME} chars",
            file=sys.stderr,
        )
        return 2

    skill_dir = Path(args.path).expanduser().resolve() / args.name
    skill_md = skill_dir / "SKILL.md"
    if skill_md.exists() and not args.force:
        print(f"error: {skill_md} already exists (use --force to overwrite)", file=sys.stderr)
        return 2

    title = titleize(args.name)
    description = args.description or (
        f"{title.replace(' ', ' ')}: describe what this skill does and when to use it."
    )
    if len(description) > MAX_DESC:
        print(f"error: description longer than {MAX_DESC} chars", file=sys.stderr)
        return 2

    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "agents").mkdir(exist_ok=True)

    skill_md.write_text(
        SKILL_TEMPLATE.format(name=args.name, description=description, title=title),
        encoding="utf-8",
    )
    (skill_dir / "agents" / "openai.yaml").write_text(
        OPENAI_YAML_TEMPLATE.format(
            display_name=title,
            short_description=f"{title} for agent workflows",
            prompt_tail=title.lower(),
            name=args.name,
        ),
        encoding="utf-8",
    )
    for resource in args.resources:
        (skill_dir / resource).mkdir(exist_ok=True)

    print(f"created skill bundle: {skill_dir}")
    for path in sorted(skill_dir.rglob("*")):
        print(f"  {'d' if path.is_dir() else 'f'} {path.relative_to(skill_dir)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
