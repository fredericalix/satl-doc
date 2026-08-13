#!/usr/bin/env python3.12
"""Assert that `docs/reference/satld-toml.md` documents exactly the keys satld accepts.

``struct ConfigFile`` in the SatL source is annotated
``#[serde(deny_unknown_fields)]``: a key it does not name is a startup error,
and a key it names that nobody documented is a feature nobody can find.

Both halves have already gone wrong once, in the direction that is hardest to
notice: the shipped ``etc/satld.toml.sample`` documents 11 of the 13 fields —
``cert_validity`` and ``overlay_blackhole`` are simply absent from it. A sample
file cannot be checked by a compiler, so nothing complained. This can, and does.

The check is bidirectional on purpose:

  * a struct field with no ``### `key` `` heading is undocumented configuration
  * a heading with no struct field is documentation for a key that makes satld
    refuse to start — worse than no documentation at all

Exit codes: 0 pass, 1 mismatch, 0 with a loud notice when the SatL source is
absent (the docs must still build on a machine that has no SatL checkout).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

CONFIG_RS = "crates/satld/src/config.rs"
STRUCT_RE = re.compile(r"struct ConfigFile\s*\{(.*?)\n\}", re.DOTALL)
FIELD_RE = re.compile(r"^\s{4}(?:pub\s+)?([a-z_][a-z0-9_]*)\s*:", re.MULTILINE)
HEADING_RE = re.compile(r"^###\s+`([a-z_][a-z0-9_]*)`\s*(?:\{.*\})?\s*$", re.MULTILINE)


def struct_keys(source: Path) -> list[str]:
    text = source.read_text()
    m = STRUCT_RE.search(text)
    if not m:
        raise SystemExit(
            f"check_config_keys: no `struct ConfigFile` in {source}.\n"
            f"The daemon config was restructured; this check needs updating."
        )
    return FIELD_RE.findall(m.group(1))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--satl-src", required=True, type=Path)
    parser.add_argument("--page", required=True, type=Path)
    args = parser.parse_args()

    source = args.satl_src / CONFIG_RS
    if not source.is_file():
        print(
            f"\n  ****  check_config_keys SKIPPED  ****\n"
            f"  No SatL source at {source}.\n"
            f"  The satld.toml reference is NOT being checked against the daemon.\n"
            f"  Set SATL_SRC to a SatL checkout to enable it.\n",
            file=sys.stderr,
        )
        return 0

    if not args.page.is_file():
        print(f"check_config_keys: missing page {args.page}", file=sys.stderr)
        return 1

    keys = struct_keys(source)
    documented = HEADING_RE.findall(args.page.read_text())

    missing = [k for k in keys if k not in documented]
    unknown = [k for k in documented if k not in keys]
    duplicates = sorted({k for k in documented if documented.count(k) > 1})

    if not missing and not unknown and not duplicates:
        print(f"check_config_keys: OK — {len(keys)} keys documented in {args.page}")
        return 0

    lines = [
        "check_config_keys: `satld.toml` reference does not match the daemon.",
        f"  struct : {source} ({len(keys)} keys)",
        f"  page   : {args.page} ({len(documented)} headings)",
    ]
    if missing:
        lines += [
            "",
            "  Accepted by satld but NOT documented:",
            *(f"    {k}" for k in missing),
            "  Add a `### `key`` heading for each.",
        ]
    if unknown:
        lines += [
            "",
            "  Documented but REJECTED by satld (deny_unknown_fields):",
            *(f"    {k}" for k in unknown),
            "  A reader copying these into satld.toml gets a daemon that will not start.",
        ]
    if duplicates:
        lines += ["", "  Documented more than once:", *(f"    {k}" for k in duplicates)]
    print("\n".join(lines), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
