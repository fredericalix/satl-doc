#!/usr/bin/env python3.12
"""Cap sentence length and paragraph size in the hand-written pages.

Four rules on this site are borrowed from ASD-STE100 Simplified Technical
English, the controlled-language standard used for maintenance documentation.
Two of them are countable, so they are checked here rather than remembered:

  * a sentence stays under a word cap (STE says 25 for descriptive text, 20 for
    an instruction; this repo ratchets down towards that)
  * a paragraph carries one topic and at most six sentences

The rest of STE is not adopted and the site claims no conformance: its
dictionary of ~900 approved words would erase the distinctions these pages
exist to draw, and the dictionary is ASD's property and cannot be vendored into
a public repository to check against anyway.

The tokenizer is the house style: one sentence per line. That makes a sentence
a line and costs nothing to measure, and it is why a hard-wrapped paragraph
left over from before that rule can hide a long sentence from this tool. It
hides it from `git diff` too, which is the older argument for the same style.

Skipped, and each for its own reason: fenced blocks are verbatim output,
`docs/reference/cli/` is generated from clap's `--help` (the fix for a long
sentence there is in SatL), headings and table cells are not prose, and the
admonition and tab markers are furniture.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FENCE = re.compile(r"^\s*```")
INLINE_CODE = re.compile(r"`[^`]*`")
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
AUTOLINK = re.compile(r"<https?://[^>]*>")
HTML_ONLY = re.compile(r"^<(!--.*|/?\w[^>]*)>?$")
LIST_MARKER = re.compile(r"^([-*+]|\d+\.)\s+")
EMPHASIS = re.compile(r"(\*\*|__|\*|_)")
# A sentence ends at ., ! or ? followed by space and something that starts a
# new one. Inline code is already CODE by then, so a sentence opening on a
# command still looks like a capital.
SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z(\"])")

# Furniture: a line that is a marker rather than a sentence.
FURNITURE = (
    "#",
    "|",
    "!!!",
    "???",
    "===",
    "--8<--",
    ">>>",
    "$ ",
    "---",
    ":::",
)


def is_prose(line: str) -> bool:
    """True for a line a reader reads as a sentence."""
    stripped = line.strip()
    if not stripped:
        return False
    if stripped.startswith(FURNITURE):
        return False
    if HTML_ONLY.match(stripped):
        return False
    return True


def words(line: str) -> list[str]:
    """The words of a prose line, with the markup that is not words removed."""
    text = line.strip()
    text = text.lstrip("> ").strip()
    text = LIST_MARKER.sub("", text)
    text = INLINE_CODE.sub("CODE", text)
    text = LINK.sub(r"\1", text)
    text = AUTOLINK.sub("CODE", text)
    text = EMPHASIS.sub("", text)
    return text.split()


def sentences(paragraph: str) -> int:
    """How many sentences a joined paragraph holds."""
    return len([s for s in SENTENCE_END.split(paragraph) if s.strip()])


def scan(path: str, text: str, max_words: int, max_sentences: int) -> list[str]:
    """Every violation in one file, as `path:line: message`."""
    found: list[str] = []
    in_fence = False
    # A paragraph is a run of prose lines. A blank line, a fence, a heading or
    # a new list item ends it: a six-item list is six paragraphs, not one.
    para: list[str] = []
    para_start = 0

    def close_paragraph() -> None:
        nonlocal para, para_start
        if para:
            count = sentences(" ".join(para))
            if count > max_sentences:
                found.append(
                    f"{path}:{para_start}: paragraph of {count} sentences "
                    f"(max {max_sentences}); split it or give the second half "
                    f"its own topic"
                )
        para = []

    for number, line in enumerate(text.splitlines(), start=1):
        if FENCE.match(line):
            in_fence = not in_fence
            close_paragraph()
            continue
        if in_fence:
            continue
        if not is_prose(line):
            close_paragraph()
            continue

        count = len(words(line))
        if count > max_words:
            found.append(
                f"{path}:{number}: sentence of {count} words (max {max_words}): "
                f"{' '.join(words(line))[:60]}..."
            )

        if LIST_MARKER.match(line.strip().lstrip("> ")):
            close_paragraph()
        if not para:
            para_start = number
        para.append(" ".join(words(line)))

    close_paragraph()
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docs", required=True, type=Path)
    parser.add_argument(
        "--max-words",
        type=int,
        default=45,
        help="word cap for one sentence (default: %(default)s, ratcheting "
        "down towards STE's 25)",
    )
    parser.add_argument(
        "--max-sentences",
        type=int,
        default=6,
        help="sentence cap for one paragraph (default: %(default)s)",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=["reference/cli"],
        help="a docs-relative directory to skip (repeatable; generated pages "
        "are skipped by default)",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="list violations and exit 0, for tightening the caps",
    )
    args = parser.parse_args()

    pages = sorted(
        p
        for p in args.docs.rglob("*.md")
        if not any(
            str(p.relative_to(args.docs)).startswith(f"{d}/") for d in args.exclude
        )
    )
    if not pages:
        print(f"check_prose: no pages under {args.docs}", file=sys.stderr)
        return 1

    problems: list[str] = []
    for page in pages:
        problems += scan(
            str(page), page.read_text(), args.max_words, args.max_sentences
        )

    if problems:
        stream = sys.stdout if args.report else sys.stderr
        print("\n".join(problems), file=stream)
        print(
            f"check_prose: {len(problems)} over the caps in {len(pages)} pages.",
            file=stream,
        )
        return 0 if args.report else 1

    print(
        f"check_prose: OK, {len(pages)} pages under "
        f"{args.max_words} words a sentence and "
        f"{args.max_sentences} sentences a paragraph"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
