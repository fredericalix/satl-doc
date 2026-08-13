#!/usr/bin/env python3.12
"""Keep `mkdocs.yml`'s nav and the files on disk in agreement, both ways.

MkDocs is forgiving in exactly the wrong direction. A page that exists but is
not in the nav simply never appears — no error, no warning above INFO, and the
only symptom is that nobody can reach it. That matters most for the generated
CLI reference, where adding a verb to SatL adds a file here automatically and
the nav is the one thing `make gen` cannot update for you.

So:

  * every ``docs/reference/cli/*.md`` must appear in the nav
  * every nav entry must exist on disk

The second half catches the rename. The first half catches the new verb, which
is the one that will actually happen.

Nav is read with a YAML loader that tolerates MkDocs' ``!!python/name:`` tags —
Material's emoji configuration uses them, and ``yaml.safe_load`` refuses the
whole file over a tag it will never look at.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml


class MkDocsLoader(yaml.SafeLoader):
    """SafeLoader that ignores MkDocs' custom tags instead of dying on them."""


MkDocsLoader.add_multi_constructor(
    "tag:yaml.org,2002:python/name:", lambda loader, suffix, node: suffix
)
MkDocsLoader.add_multi_constructor("!", lambda loader, suffix, node: suffix)


def nav_paths(nav) -> list[str]:
    """Every document path in a nav tree, in order."""
    found: list[str] = []
    if isinstance(nav, str):
        found.append(nav)
    elif isinstance(nav, list):
        for item in nav:
            found += nav_paths(item)
    elif isinstance(nav, dict):
        for value in nav.values():
            found += nav_paths(value)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--docs", required=True, type=Path)
    parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="a docs-relative directory whose every .md must be in the nav "
        "(repeatable)",
    )
    args = parser.parse_args()

    config = yaml.load(args.config.read_text(), Loader=MkDocsLoader)
    entries = [p for p in nav_paths(config.get("nav") or []) if not p.startswith("http")]

    problems: list[str] = []

    dangling = [p for p in entries if not (args.docs / p).is_file()]
    if dangling:
        problems.append(
            "  In the nav but not on disk (mkdocs will emit a broken entry):\n"
            + "\n".join(f"    {p}" for p in dangling)
        )

    listed = set(entries)
    for required in args.require:
        directory = args.docs / required
        if not directory.is_dir():
            problems.append(f"  Required nav directory is missing: {directory}")
            continue
        orphans = sorted(
            str(p.relative_to(args.docs))
            for p in directory.glob("*.md")
            if str(p.relative_to(args.docs)) not in listed
        )
        if orphans:
            problems.append(
                f"  On disk under {required} but not in the nav (unreachable):\n"
                + "\n".join(f"    {p}" for p in orphans)
                + "\n    Generated pages appear when SatL gains a verb; add them to"
                "\n    the `nav:` block in mkdocs.yml."
            )

    if problems:
        print(
            "check_nav: nav and docs/ disagree.\n" + "\n".join(problems), file=sys.stderr
        )
        return 1

    print(f"check_nav: OK — {len(entries)} nav entries, all present, none orphaned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
