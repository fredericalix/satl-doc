# SatL documentation

The source of <https://docs.satl.cc>

This repository builds **the documentation site**, not SatL. SatL itself lives
in a separate checkout, is never modified from here, and is only ever read.

## Requirements

FreeBSD packages, all Python 3.12:

```sh
make install-deps      # needs root
```

That installs `py312-mkdocs`, `py312-mkdocs-material`,
`py312-mkdocs-git-revision-date-localized-plugin` and `py312-yaml`.

There is **no `python3` symlink and no guaranteed `mkdocs` binary** on this
system, which is why every tool here is invoked as `python3.12` and MkDocs as
`python3.12 -m mkdocs`. Override with `PYTHON=` if your setup differs.

## Building

```sh
make serve       # preview on http://127.0.0.1:8000, live reload
make build       # build into site/ with --strict
make check       # build strictly, then every consistency check
make             # the full target list
```

`strict: false` is set in `mkdocs.yml` and `--strict` is passed by the
Makefile's `build` target. That is on purpose: a strict `mkdocs serve` dies the
moment you type half a link, so strictness belongs at the point of publishing,
not at the point of writing.

## Two variables

| Variable | Default | What it points at |
| --- | --- | --- |
| `SATL_SRC` | `${HOME}/src/satl` | the SatL source checkout, read-only |
| `SATL_BIN` | `.cache/target/release/satl` | the binary the CLI reference is harvested from |

`SATLD_BIN` mirrors `SATL_BIN` for the daemon. Neither defaults to
`/usr/local/bin`: an installed `satl` is whatever was installed last, and a
reference harvested from a stale one is missing whole commands while looking
perfectly complete. That has already happened once here — the installed binary
was three verbs behind — which is why `make gen` refuses to run before
`tools/check_drift.py` agrees.

## The generated CLI reference

`docs/reference/cli/` (28 pages) and `docs/reference/satld.toml.sample` are
**generated and committed**. Committed, because the site must build with no
SatL checkout, no Rust toolchain and no FreeBSD. Safe to commit, because
`make check-gen` regenerates into a scratch directory and diffs — a hand-edit
or a moved-on binary fails the build.

**Do not edit those files.** To change what they say:

* wording of a flag, a new subcommand → change it in **SatL**, rebuild,
  `make gen`
* how flags are *grouped, paired or explained* → change **`overlay/cli.yml`**,
  `make gen`

`overlay/cli.yml` holds the small amount of knowledge `--help` cannot carry:
that the twelve `--update-*`/`--rollback-*` flags are one shared
`#[command(flatten)]` struct, that `satl service create --constraint` is the
same idea as `satl service update --constraint-add`, and which flags must never
be documented at all. Facts are generated; judgement is written down there.

```sh
make gen           # regenerate (drift check first — it will refuse if stale)
make gen-fresh     # rebuild satl/satld from SATL_SRC into .cache/, then gen
```

Pages carry no timestamp, deliberately: a timestamp would churn every diff and
make `check-gen` useless. The "last updated" date comes from git instead, via
the `git-revision-date-localized` plugin, which cannot claim a page is fresher
than its last commit.

### When `make gen` refuses

```
check_drift: the `satl` binary does not match the SatL source.
  binary : /usr/local/bin/satl (17 verbs)
  source : /home/fralix/src/satl/crates/satl-cli/src/cli.rs (20 verbs)
  in the source but NOT in the binary: ca, secret, config
```

The binary you pointed at was built from an older tree. It is not a
documentation problem and there is nothing to fix in this repo:

```sh
make gen-fresh                          # rebuild the pair from SATL_SRC
make gen SATL_BIN=/path/to/satl         # or point at a build you trust
make gen ALLOW_STALE=1                  # last resort: generate anyway
```

`ALLOW_STALE=1` stamps a red banner on every page saying the source was stale.
It exists so a broken toolchain cannot block a build entirely. It is never how
a published reference is made.

## The checks

| Target | What it refuses to let through |
| --- | --- |
| `make check-drift` | a `satl` binary whose verbs disagree with `enum Command` in the source |
| `make check-gen` | committed generated pages that differ from what the generator emits |
| `make check-config` | a `satld.toml` key the daemon accepts and `docs/reference/satld-toml.md` omits — **or** a key documented here that `deny_unknown_fields` would reject |
| `make check-nav` | a page under `docs/reference/cli/` missing from the nav, or a nav entry with no file |
| `make build` | broken links **and broken anchors** (`validation.links.anchors: warn` plus `--strict`) |

`check-config` is not hypothetical: SatL's own `etc/satld.toml.sample`
documents 11 of the daemon's 13 configuration keys — `cert_validity` and
`overlay_blackhole` are absent from it. Nothing in a Rust build can catch that.

`check-drift`, `check-gen` and `check-config` **skip with a loud notice** when
`SATL_SRC` or the binaries are missing, so the site still builds on a machine
that has never seen SatL. `make build` and `make serve` never need either.

## Layout

```
docs/           the site content
  reference/cli/    GENERATED — see above
overlay/cli.yml the judgement the generator cannot derive
tools/          the generator and the four checks
.cache/         gitignored: locally built satl/satld, scratch space
```

## Deployment TODO

The site is not served from a host yet, but the URLs it will be served from are
now set: `site_url: https://satl.cc/`, with `repo_url` and `edit_uri` pointing
at this repository so every page carries a working edit link. What is left:

1. Publish the built `site/` at <https://satl.cc/>, and
   `satl-freebsd.pkg` at <https://satl.cc/download/> — the install page and the
   home page both hand readers that URL.
2. Enable `mkdocs-minify-plugin` for HTML/CSS/JS.
3. Adopt [`mike`](https://github.com/jimporter/mike) for versioned docs, once
   SatL has more than one release worth documenting. The generated reference is
   version-stamped per page (`<!-- Source: satl 0.1.0 -->`), so the split is
   already meaningful.
4. Drop the `GIT_DATES` shim in `mkdocs.yml` and the Makefile — it exists only
   so a zero-commit checkout can build under `--strict`, which this repository
   has not been since its first commit.

## Licence

The documentation in this repository is licensed **CC BY 4.0** — see
[`LICENSE`](LICENSE).

**This covers the documentation only.** SatL itself is **BSD-2-Clause**, the
same terms as FreeBSD, with an SPDX header on every source file. The two
licences are separate on purpose: keep them separate on the site too, which
[`docs/about/status.md`](docs/about/status.md#licensing) does in one sentence.
