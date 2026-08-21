# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

The MkDocs source of the SatL documentation site. **It builds the docs, not
SatL.** SatL itself lives in a separate checkout (`SATL_SRC`, default
`${HOME}/src/satl`), is only ever read, and is never modified from here. When a
fact about SatL is wrong on the site, the fix is usually in SatL or in
`overlay/cli.yml`, not in `docs/`.

## Commands

`make` in the README and Makefile means **FreeBSD make (bmake)**. GNU make dies
at `Makefile:33` (`.if defined(...)`) with "missing separator", so on macOS use
`bmake` for every target below. `PYTHON` defaults to `python3.12` and MkDocs is
invoked as `python3.12 -m mkdocs`: there is no guaranteed `mkdocs` binary on
the FreeBSD target; override `PYTHON=` if needed.

```sh
bmake serve        # preview on 127.0.0.1:8000, live reload, non-strict
bmake build        # build into site/ with --strict
bmake check        # build + check-nav + check-config + check-drift + check-gen
bmake help         # target list and the resolved SATL_SRC / SATL_BIN
bmake clean        # remove site/ and .cache/check-gen
```

There are no unit tests; `bmake check` is the test suite. To run one check,
the equivalent of a single test, invoke the target (`bmake check-nav`,
`check-config`, `check-drift`, `check-gen`) or the tool directly, e.g.
`python3.12 tools/check_nav.py --config mkdocs.yml --docs docs --require reference/cli`.

The SatL checkout on this machine is at `/Users/frederic/fax/src/satl`, not the
Makefile's `${HOME}/src/satl` default, so pass it explicitly to make the
source-comparing checks actually run:
`bmake check-config SATL_SRC=/Users/frederic/fax/src/satl` (16 keys, passing).
`check-drift` and `check-gen` additionally need built binaries; `bmake gen-fresh`
would produce them, and that needs FreeBSD.

Regenerating the CLI reference needs a SatL checkout and a Rust toolchain:

```sh
bmake gen          # regenerate from ${SATL_BIN}; drift check runs first and can refuse
bmake gen-fresh    # cargo build satl-cli+satld from SATL_SRC into .cache/, then gen
bmake gen ALLOW_STALE=1   # generate from a binary that failed drift, stamping a red banner
```

`SATL_BIN`/`SATLD_BIN` default to `.cache/target/release/` and deliberately
**not** `/usr/local/bin`: an installed `satl` was once three verbs behind the
source, producing a reference that looked complete and was not.

`check-drift`, `check-gen` and `check-config` **skip with a loud stderr notice**
when `SATL_SRC` or the binaries are absent (the usual state on a non-FreeBSD
machine), so `serve`, `build` and `check` all still succeed there. A silent pass
is never what happened; read the notices.

## Architecture

Three layers, and the boundaries between them are what the tooling protects.

**Generated and committed.** `docs/reference/cli/*.md` (28 pages: one per
top-level verb, plus `index.md` and `satld.md`) and
`docs/reference/satld.toml.sample`. `tools/gen_cli.py` walks
`satl <path...> --help` recursively and parses clap's output *by indent*, not by
blank lines (clap emits whitespace-only lines inside an entry; `--host` is
exactly that shape). Committed because the site must build with no SatL
checkout, no Rust toolchain and no FreeBSD; safe to commit because `check-gen`
regenerates into `.cache/check-gen` and diffs. Generated pages carry **no
timestamp** on purpose: a timestamp would churn every diff and make `check-gen`
useless; per-page dates come from git via `git-revision-date-localized`.

**Judgement.** `overlay/cli.yml` holds only what `--help` cannot carry:
`globals:` (flags lifted out of every per-command table and rendered once),
`groups:` (that the twelve `--update-*`/`--rollback-*` flags are one shared
`#[command(flatten)] PolicyArgs`), `diff:`/`pairs:` (that `service create
--constraint` is `service update --constraint-add`'s wholesale form), and
`deny_flags:` (a tripwire asserting no `--internal-*`/`--unsafe-*`/`--dev-*`
flag ever reaches a page). Facts are generated; judgement is written there.

**Prose.** Everything else under `docs/`. Narrative pages deep-link into
generated pages by anchor (`../reference/cli/network.md#satl-network`) instead
of restating flag tables, which is why `validation.links.anchors: warn` plus
`--strict` matters: those anchors move when SatL renames a subcommand.

### The four checks and what each protects

| Tool | Reads from SatL | Fails on |
| --- | --- | --- |
| `check_drift.py` | `crates/satl-cli/src/cli.rs` (`pub enum Command`, by regex) | binary verbs ≠ source verbs |
| `check-gen` (Makefile: `gen_cli.py` + `diff -ru`) | the binaries | committed pages ≠ generator output |
| `check_config_keys.py` | `crates/satld/src/config.rs` (`struct ConfigFile`) | a key documented but not accepted, or accepted but not documented |
| `check_nav.py` | nothing | a `docs/reference/cli/*.md` missing from nav, or a nav entry with no file |

The SatL-source parsers are deliberately regex, not Rust parsers: they read a
tree this repo does not own and only need variant/field names.

## Invariants when editing

- **Never hand-edit `docs/reference/cli/*.md` or `docs/reference/satld.toml.sample`.**
  Wording of a flag → change SatL, rebuild, `bmake gen`. How flags are grouped,
  paired or explained → change `overlay/cli.yml`, `bmake gen`.
- When `gen` adds a page (SatL gained a verb), add the `nav:` entry in
  `mkdocs.yml` yourself; `gen` cannot, and MkDocs reports an unreachable page
  as nothing at all.
- Every `satld.toml` key needs a ``### `key` `` heading in
  **`docs/reference/satld-toml.md`** (the key-by-key reference the checker
  reads). `docs/config/satld-toml.md` is the narrative companion and is not
  checked; keep the split: decisions in `config/`, exact types and defaults in
  `reference/`.
- `strict: false` lives in `mkdocs.yml` and `--strict` is passed by the
  Makefile's `build`. Don't "fix" that: a strict `serve` dies on half-typed
  links.
- Repeated operational warnings are snippets in `docs/snippets/`, included as
  `--8<-- "name.md"` (base path is `docs/snippets`, `check_paths: true`, and the
  directory is excluded from nav via `not_in_nav`). Reuse an existing snippet
  before writing the same admonition twice.
- The palette is a **custom** one: `primary: custom` / `accent: custom` in
  `mkdocs.yml` suppress Material's own colour rules so `extra.css` owns the
  pastel orange, including the contrast overrides a pastel primary needs (dark
  text on the header, a separate `--md-typeset-a-color` for links). Putting a
  palette name back in `mkdocs.yml` without deleting that CSS block gives you two
  half-applied palettes.
- `site_url`, `repo_url` and `edit_uri` are set (`https://satl.cc/`,
  `github.com/fredericalix/satl-doc`), so every page renders an edit link. The
  remaining deployment steps are in `README.md`.

## Editorial conventions

- Nothing is documented from intent. Everything on the site has been run on
  FreeBSD 15.1 amd64 (three-node cluster for anything multi-node); `console`
  blocks are verbatim output, including error text. If a claim has not been
  exercised, it belongs on `docs/about/status.md` as missing, not in prose.
- Behaviour that is accepted-and-ignored, or unimplemented, gets an explicit
  admonition rather than silence (see `socket_group` in
  `docs/reference/satld-toml.md`).
- Commit subjects are milestone-tagged, e.g. `M6: encrypted overlay networks
  (--opt encrypted) + regen`. Append `+ regen` when the commit includes
  regenerated pages, and keep prose and regen in one commit when they belong
  together.
- **No em dashes (`—`) anywhere a reader sees.** Not in prose, not in headings,
  not in table cells. Use a comma; a semicolon when the two halves are whole
  sentences, a colon for a label and its gloss or before a list, parentheses for
  an aside that already contains commas. The two exceptions are verbatim
  `console`/code blocks, which are output and never edited, and the literal
  character where the docs discuss it (`docs/trouble/reading-the-log.md`). The
  generated pages under `reference/cli/` still carry some: they come from clap's
  `--help` text, so the fix is in SatL, not here.
- One sentence per line in the Markdown source. Rendered output is unaffected
  (Python-Markdown folds single newlines into spaces), and diffs then point at
  the sentence that changed instead of at a reflowed paragraph. New prose should
  match; the generated pages under `reference/cli/` are exempt.
- **A sentence stays under `PROSE_MAX_WORDS` words and a paragraph under six
  sentences**, both enforced by `bmake check-prose`. The tokenizer is the rule
  above: a line is a sentence, which is what makes the check cost nothing. The
  cap in the Makefile is a ratchet, currently 45 on the way to ASD-STE100's 25:
  lower it once the tree is clean, never raise it to let one page through, and
  split the sentence rather than dropping a clause the reader needed.
- Four rules on this site come from **ASD-STE100 Simplified Technical English**:
  the two caps above, one instruction per step with the imperative verb first
  (`start/`, and the **Check** / **Fix** blocks in `trouble/`), and one term per
  concept (`docs/reference/glossary.md` is that list). Nothing else from STE is
  adopted and the site claims no conformance anywhere. Its ~900-word dictionary
  would collapse `accepted-and-ignored`, `refused` and `silently dropped` into
  one approved verb, and those distinctions are why most of these pages exist;
  the dictionary is also ASD's property, so a checker here could only ever
  approximate it, and an approximation flying the standard's name is exactly the
  claim-without-evidence this site refuses everywhere else.
- The documentation is CC BY 4.0 (`LICENSE`); SatL itself is BSD-2-Clause. Keep
  the two distinct; never write anything that lets a reader infer one licence
  from the other.
