#!/usr/bin/env python3
"""Validate an Agent Skill bundle (SKILL.md frontmatter + optional agents/openai.yaml).

Usage:
    python scripts/quick_validate.py <skill-dir-or-SKILL.md> [more ...]
    python scripts/quick_validate.py skill/fetch-picture-word
    python scripts/quick_validate.py --scan skill

Checks (errors block a release, warnings do not):
  E  SKILL.md present and readable
  E  YAML frontmatter delimited by --- and parseable
  E  required keys `name` and `description`
  E  name matches the bundle directory, kebab-case, 1-64 chars
  E  description 1-1024 chars, single line
  E  agents/openai.yaml parseable, all top-level values quoted
  W  no extra frontmatter keys outside the known set
  W  unknown keys inside agents/openai.yaml
  W  body shorter than 40 characters or missing a heading
  W  stale placeholders ("TODO", "Trigger 1", "describe what this skill does")
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_NAME = 64
MAX_DESCRIPTION = 1024

KNOWN_FRONTMATTER_KEYS = {
    "name",
    "description",
    "whenToUse",
    "metadata",
    "disable-model-invocation",
    "user-invocable",
    "license",
    "allowed-tools",
}
KNOWN_OPENAI_KEYS = {"interface", "dependencies", "policy"}
KNOWN_INTERFACE_KEYS = {
    "display_name",
    "short_description",
    "icon_small",
    "icon_large",
    "brand_color",
    "default_prompt",
}
PLACEHOLDERS = ("describe what this skill does", "Trigger 1", "Step one.", "TODO", "FIXME")


class Report:
    def __init__(self, target: Path) -> None:
        self.target = target
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.notes: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)


def split_frontmatter(text: str) -> tuple[str | None, str, str | None]:
    """Return (frontmatter, body, error)."""
    if not text.startswith("---"):
        return None, text, "file does not start with a `---` frontmatter delimiter"
    lines = text.splitlines()
    closing = None
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            closing = index
            break
    if closing is None:
        return None, text, "frontmatter is not closed by a second `---` line"
    frontmatter = "\n".join(lines[1:closing])
    body = "\n".join(lines[closing + 1 :])
    return frontmatter, body, None


def check_quoted_strings(path: Path, data: object, report: Report, prefix: str = "") -> None:
    """agents/openai.yaml requires quoted string values."""
    if not isinstance(data, dict):
        return
    for key, value in data.items():
        here = f"{prefix}{key}"
        if isinstance(value, dict):
            check_quoted_strings(path, value, report, prefix=f"{here}.")
            continue
        if isinstance(value, bool):
            continue
        if isinstance(value, str):
            raw = path.read_text(encoding="utf-8")
            if f'{key}: "{value}"' not in raw and f"{key}: '{value}'" not in raw:
                report.warn(f"agents/openai.yaml: value of `{here}` should be quoted")


def validate_skill(target: Path) -> Report:
    report = Report(target)
    skill_md = target / "SKILL.md" if target.is_dir() else target
    if not skill_md.is_file():
        report.error(f"missing SKILL.md at {skill_md}")
        return report

    bundle = skill_md.parent
    text = skill_md.read_text(encoding="utf-8")
    frontmatter, body, error = split_frontmatter(text)
    if error:
        report.error(f"SKILL.md: {error}")
        return report

    try:
        data = yaml.safe_load(frontmatter)
    except yaml.YAMLError as exc:
        report.error(f"SKILL.md: frontmatter is not valid YAML: {exc}")
        return report
    if not isinstance(data, dict):
        report.error("SKILL.md: frontmatter must be a YAML mapping")
        return report

    name = data.get("name")
    if not isinstance(name, str) or not name.strip():
        report.error("SKILL.md: `name` is required and must be a string")
    else:
        name = name.strip()
        if not NAME_RE.match(name) or len(name) > MAX_NAME:
            report.error(
                f"SKILL.md: `name` {name!r} must be kebab-case "
                f"(lowercase letters, digits, single hyphens), max {MAX_NAME} chars"
            )
        if bundle.name != name:
            report.error(
                f"SKILL.md: `name` {name!r} does not match the bundle directory {bundle.name!r}"
            )

    description = data.get("description")
    if not isinstance(description, str) or not description.strip():
        report.error("SKILL.md: `description` is required and must be a string")
    else:
        description = description.strip()
        if len(description) > MAX_DESCRIPTION:
            report.error(
                f"SKILL.md: `description` is {len(description)} chars, "
                f"max {MAX_DESCRIPTION}"
            )
        if "\n" in description:
            report.error("SKILL.md: `description` must be a single line")

    for key in data:
        if key not in KNOWN_FRONTMATTER_KEYS:
            report.warn(f"SKILL.md: unknown frontmatter key `{key}`")

    for key in ("disable-model-invocation", "user-invocable"):
        if key in data and not isinstance(data[key], bool):
            report.error(f"SKILL.md: `{key}` must be a boolean")

    if len(body.strip()) < 40:
        report.warn("SKILL.md: body is very short (<40 chars)")
    elif not any(line.lstrip().startswith("#") for line in body.splitlines()):
        report.warn("SKILL.md: body has no markdown heading")

    for placeholder in PLACEHOLDERS:
        if placeholder in body or (isinstance(description, str) and placeholder in description):
            report.warn(f"SKILL.md: leftover scaffold placeholder {placeholder!r}")

    openai_yaml = bundle / "agents" / "openai.yaml"
    if openai_yaml.is_file():
        try:
            config = yaml.safe_load(openai_yaml.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            report.error(f"agents/openai.yaml: not valid YAML: {exc}")
            config = None
        if config is not None:
            if not isinstance(config, dict):
                report.error("agents/openai.yaml: top level must be a mapping")
            else:
                for key in config:
                    if key not in KNOWN_OPENAI_KEYS:
                        report.warn(f"agents/openai.yaml: unknown top-level key `{key}`")
                interface = config.get("interface")
                if isinstance(interface, dict):
                    for key in interface:
                        if key not in KNOWN_INTERFACE_KEYS:
                            report.warn(f"agents/openai.yaml: unknown interface key `{key}`")
                    short = interface.get("short_description")
                    if isinstance(short, str) and not 25 <= len(short) <= 64:
                        report.warn(
                            "agents/openai.yaml: `interface.short_description` should be "
                            f"25-64 chars (currently {len(short)})"
                        )
                    prompt = interface.get("default_prompt")
                    if isinstance(prompt, str) and isinstance(name, str) and name not in prompt:
                        report.warn(
                            "agents/openai.yaml: `interface.default_prompt` should mention "
                            f"the skill as ${name}"
                        )
                elif interface is None:
                    report.warn("agents/openai.yaml: no `interface` block")
                check_quoted_strings(openai_yaml, config, report)
    else:
        report.note("no agents/openai.yaml (optional)")

    if report.errors:
        return report

    report.note(f"name={name}")
    report.note(f"description={len(description)} chars")
    report.note(f"body={len(body.strip())} chars, {len(list(bundle.rglob('*')))} entries")
    return report


def discover(root: Path) -> list[Path]:
    found = []
    for skill_md in sorted(root.rglob("SKILL.md")):
        if any(part in {".git", "node_modules", ".venv"} for part in skill_md.parts):
            continue
        found.append(skill_md.parent)
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="quick_validate.py", description="Validate Agent Skill bundles."
    )
    parser.add_argument("targets", nargs="*", help="skill directories")
    parser.add_argument(
        "--scan", metavar="DIR", action="append", default=[],
        help="recursively validate every SKILL.md under DIR",
    )
    args = parser.parse_args(argv)

    targets = [Path(t).expanduser() for t in args.targets]
    for directory in args.scan:
        targets.extend(discover(Path(directory).expanduser()))
    if not targets:
        parser.error("provide at least one skill directory or --scan DIR")

    total_errors = 0
    total_warnings = 0
    for target in targets:
        report = validate_skill(target.resolve())
        label = report.target.name if report.target.is_dir() else report.target.parent.name
        status = "FAIL" if report.errors else ("WARN" if report.warnings else "OK")
        print(f"[{status}] {label}  ({report.target})")
        for note in report.notes:
            print(f"    - {note}")
        for warning in report.warnings:
            print(f"    ! {warning}")
        for error in report.errors:
            print(f"    x {error}")
        total_errors += len(report.errors)
        total_warnings += len(report.warnings)

    print(
        f"\n{len(targets)} skill(s): {total_errors} error(s), "
        f"{total_warnings} warning(s)"
    )
    return 1 if total_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
