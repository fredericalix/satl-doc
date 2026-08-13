#!/usr/bin/env python3.12
"""Refuse to generate the CLI reference from a binary that is not the source.

The failure this exists to prevent has already happened once: the system
``satl`` in ``/usr/local/bin`` was three verbs behind the tree it was built
from (17 against 20), and nothing about ``satl --help`` says so. A reference
harvested from it would have been silently, plausibly wrong — three whole
verbs missing, every page otherwise perfect.

So before any generation, the binary's top-level verb list is compared against
``enum Command`` in the SatL source. Reading the enum is deliberately crude:
a regex, not a Rust parser. It only has to see variant names, it runs against a
tree this repo does not own and must not modify, and a parser that understood
Rust would be a much larger thing to keep working.

Exit codes: 0 in agreement, 1 on drift, 2 when the comparison cannot be made
(missing source, missing binary) unless ``--allow-stale`` says to carry on.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

CLI_RS = "crates/satl-cli/src/cli.rs"
ENUM_RE = re.compile(r"pub enum Command\s*\{(.*?)\n\}", re.DOTALL)
# A variant is a CamelCase identifier at the enum's own indent, optionally
# followed by a tuple or struct body. Doc comments and attributes are skipped
# by requiring the line to start with an uppercase letter.
VARIANT_RE = re.compile(r"^\s{4}([A-Z][A-Za-z0-9]*)\s*[({,]", re.MULTILINE)
ALIAS_RE = re.compile(r'visible_alias\s*=\s*"([^"]+)"')


def kebab(variant: str) -> str:
    """``JoinToken`` -> ``join-token``, which is clap's own default renaming."""
    return re.sub(r"(?<!^)(?=[A-Z])", "-", variant).lower()


def source_verbs(satl_src: Path) -> tuple[list[str], set[str]]:
    text = (satl_src / CLI_RS).read_text()
    m = ENUM_RE.search(text)
    if not m:
        raise SystemExit(
            f"check_drift: no `pub enum Command` block in {satl_src / CLI_RS}.\n"
            f"The CLI was restructured; tools/check_drift.py needs updating."
        )
    body = m.group(1)
    return [kebab(v) for v in VARIANT_RE.findall(body)], set(ALIAS_RE.findall(body))


def binary_verbs(satl: Path) -> list[str]:
    proc = subprocess.run(
        [str(satl), "--help"], capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise SystemExit(f"check_drift: `{satl} --help` exited {proc.returncode}")
    verbs: list[str] = []
    in_commands = False
    for line in proc.stdout.splitlines():
        if line.rstrip() == "Commands:":
            in_commands = True
            continue
        if in_commands:
            if not line.strip():
                continue
            if not line.startswith("  "):
                break
            if not re.match(r"^ {2,6}\S", line):
                continue
            verbs.append(line.split()[0])
    return verbs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--satl", required=True, type=Path)
    parser.add_argument("--satl-src", required=True, type=Path)
    parser.add_argument(
        "--allow-stale",
        action="store_true",
        help="report the drift and exit 0 anyway (pages are then banner-marked)",
    )
    args = parser.parse_args()

    if not args.satl.is_file():
        return report(
            args.allow_stale,
            f"check_drift: no `satl` binary at {args.satl}.\n"
            f"  Build one with: make gen-fresh",
        )
    if not (args.satl_src / CLI_RS).is_file():
        return report(
            args.allow_stale,
            f"check_drift: no SatL source at {args.satl_src}.\n"
            f"  Point SATL_SRC at a SatL checkout, or pass --allow-stale to skip.",
        )

    expected, aliases = source_verbs(args.satl_src)
    actual = [v for v in binary_verbs(args.satl) if v not in aliases]

    missing = [v for v in expected if v not in actual]
    extra = [v for v in actual if v not in expected]

    if not missing and not extra:
        print(
            f"check_drift: OK — {len(expected)} verbs, "
            f"{args.satl} matches {args.satl_src / CLI_RS}"
        )
        return 0

    lines = [
        "check_drift: the `satl` binary does not match the SatL source.",
        f"  binary : {args.satl} ({len(actual)} verbs)",
        f"  source : {args.satl_src / CLI_RS} ({len(expected)} verbs)",
    ]
    if missing:
        lines.append(
            f"  in the source but NOT in the binary: {', '.join(missing)}"
        )
    if extra:
        lines.append(
            f"  in the binary but NOT in the source: {', '.join(extra)}"
        )
    lines += [
        "",
        "The binary is stale (or built from another tree). Rebuild it with:",
        "    make gen-fresh",
        "or point SATL_BIN at a current build:",
        "    make gen SATL_BIN=/path/to/target/release/satl",
        "Generating anyway would publish a reference that is missing whole",
        "commands and says nothing about it. If that is really what you want:",
        "    make gen ALLOW_STALE=1",
    ]
    return report(args.allow_stale, "\n".join(lines))


def report(allow_stale: bool, message: str) -> int:
    if allow_stale:
        print(f"{message}\n\n--allow-stale: generating anyway.", file=sys.stderr)
        return 0
    print(message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
