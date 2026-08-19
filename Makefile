# SatL documentation site -- FreeBSD make(1) (bmake), mirroring SatL's own Makefile.
#
# Run `make` for the target list.

PYTHON?=	python3.12
MKDOCS?=	${PYTHON} -m mkdocs

# Where SatL's source lives. Read only: this repo never writes into it, and the
# generation pipeline is built the way it is precisely so it does not have to.
SATL_SRC?=	${HOME}/src/satl

# The binaries the reference is harvested from. They default to a build this
# repo owns, under .cache/, and NOT to /usr/local/bin -- an installed satl is
# whatever was last installed, which is how a reference silently loses three
# verbs. `make gen-fresh` builds this pair; `make check-drift` proves it current.
CACHE_TARGET?=	${.CURDIR}/.cache/target
SATL_BIN?=	${CACHE_TARGET}/release/satl
SATLD_BIN?=	${CACHE_TARGET}/release/satld

# Where the built site is published. The release directory and the `current`
# symlink live under DEPLOY_ROOT, owned by the deploying user, so publishing --
# the frequent operation -- needs no privilege escalation at all.
DEPLOY_HOST?=	fralix@obsd0.fredalix.com
DEPLOY_ROOT?=	/var/www/htdocs/docs.satl.cc
DEPLOY_KEEP?=	3

CARGO?=		cargo
OVERLAY?=	${.CURDIR}/overlay/cli.yml
CLI_OUT?=	${.CURDIR}/docs/reference/cli
CONFIG_PAGE?=	${.CURDIR}/docs/reference/satld-toml.md
SAMPLE?=	${.CURDIR}/docs/reference/satld.toml.sample

# `make gen ALLOW_STALE=1` generates from a binary that failed the drift check,
# stamping a loud banner on every page. It exists for the case where you need
# the site to build at all; it is never how a published reference is made.
#
# Note `defined() && !empty()` rather than `${ALLOW_STALE:D...}`: a `?=` default
# leaves the variable *defined and empty*, which `:D` treats as set. That is how
# an escape hatch ends up switched on permanently and unnoticed.
.if defined(ALLOW_STALE) && !empty(ALLOW_STALE)
STALE_GEN=	--stale
STALE_DRIFT=	--allow-stale
.else
STALE_GEN=
STALE_DRIFT=
.endif

# `make deploy ALLOW_DIRTY=1` publishes a tree with uncommitted changes. Page
# dates come from git, so publishing uncommitted work dates every page by a
# commit that does not contain it -- the site would claim a freshness it cannot
# show. Note the same `defined() && !empty()` as above, and for the same reason.
.if defined(ALLOW_DIRTY) && !empty(ALLOW_DIRTY)
DIRTY_OK=	true
.else
DIRTY_OK=	false
.endif

.PHONY: help install-deps gen gen-fresh serve build check-gen check-drift \
	check-config check-nav check check-clean-tree deploy clean

help:
	@echo 'SatL documentation site.'
	@echo ''
	@echo '  make install-deps   install mkdocs, the theme and the plugins (needs root)'
	@echo '  make serve          preview at http://127.0.0.1:8000 (live reload)'
	@echo '  make build          build into site/ with --strict'
	@echo '  make check          build strictly, then run every consistency check'
	@echo ''
	@echo '  make gen            regenerate docs/reference/cli/ from the satl binaries'
	@echo '  make gen-fresh      rebuild those binaries from ${SATL_SRC}, then gen'
	@echo ''
	@echo '  make check-gen      fail if the committed generated pages are stale'
	@echo '  make check-drift    fail if the satl binary does not match its source'
	@echo '  make check-config   fail if satld.toml.md and struct ConfigFile differ'
	@echo '  make check-nav      fail if mkdocs.yml nav and docs/ disagree'
	@echo '  make deploy         build, check, then publish site/ to ${DEPLOY_HOST}'
	@echo '  make clean          remove site/ and generator caches'
	@echo ''
	@echo 'Variables: SATL_SRC=${SATL_SRC}'
	@echo '           SATL_BIN=${SATL_BIN}'
	@echo '           DEPLOY_HOST=${DEPLOY_HOST}'

install-deps:
	pkg install -y py312-mkdocs py312-mkdocs-material \
	    py312-mkdocs-git-revision-date-localized-plugin py312-yaml

# --------------------------------------------------------------------------- #
# generation
# --------------------------------------------------------------------------- #

# The drift check runs FIRST and is not advisory: generating from a stale binary
# produces a reference that looks complete and is not.
gen:
	@if [ ! -x ${SATL_BIN} ]; then \
	    echo 'make gen: no satl binary at ${SATL_BIN}.' >&2; \
	    echo '' >&2; \
	    echo 'The generated pages under docs/reference/cli/ are committed, so' >&2; \
	    echo '`make serve` and `make build` work without one. Regenerating does' >&2; \
	    echo 'not. Build the pair with:' >&2; \
	    echo '    make gen-fresh' >&2; \
	    echo 'or point at an existing build:' >&2; \
	    echo '    make gen SATL_BIN=/path/to/satl SATLD_BIN=/path/to/satld' >&2; \
	    exit 1; \
	fi
	${PYTHON} tools/check_drift.py --satl ${SATL_BIN} --satl-src ${SATL_SRC} \
	    ${STALE_DRIFT}
	${PYTHON} tools/gen_cli.py --satl ${SATL_BIN} --satld ${SATLD_BIN} \
	    --out ${CLI_OUT} --overlay ${OVERLAY} ${STALE_GEN}
	@if [ -f ${SATL_SRC}/etc/satld.toml.sample ]; then \
	    cp ${SATL_SRC}/etc/satld.toml.sample ${SAMPLE}; \
	    echo "gen: copied satld.toml.sample from ${SATL_SRC}"; \
	else \
	    echo "gen: WARNING no ${SATL_SRC}/etc/satld.toml.sample to copy" >&2; \
	fi

# --locked is deliberately absent: SatL's Cargo.lock is currently dirty on the
# development tree, and a docs build has no business failing over that. This
# builds into .cache/target, never into SatL's own target/, so it cannot
# disturb a build in progress next door.
gen-fresh:
	${CARGO} build --release --manifest-path ${SATL_SRC}/Cargo.toml \
	    --target-dir ${CACHE_TARGET} -p satl-cli -p satld
	@${MAKE} gen

# --------------------------------------------------------------------------- #
# building
# --------------------------------------------------------------------------- #

# GIT_DATES: see the git-revision-date-localized block in mkdocs.yml. An empty
# repository has no git log to read, the plugin warns once per page, and
# --strict turns that into a failure -- so the very first build of a fresh
# checkout would fail for a reason that has nothing to do with the docs.
GIT_DATES_SH=	git -C ${.CURDIR} rev-parse --verify -q HEAD >/dev/null 2>&1 \
		&& echo true || echo false

serve:
	@dates=`${GIT_DATES_SH}`; \
	    [ "$$dates" = true ] || echo 'note: no commits yet, page dates disabled'; \
	    GIT_DATES=$$dates ${MKDOCS} serve

build:
	@dates=`${GIT_DATES_SH}`; \
	    [ "$$dates" = true ] || echo 'note: no commits yet, page dates disabled'; \
	    GIT_DATES=$$dates ${MKDOCS} build --strict

# --------------------------------------------------------------------------- #
# checks
# --------------------------------------------------------------------------- #

# Regenerate into a scratch directory and diff. This is what makes "generated
# but committed" safe: the pages in git are provably the pages the binary
# produces, so a reader without a SatL checkout still gets the truth.
#
# One shell for the whole target on purpose: bmake runs each recipe line in its
# own shell, so an early `exit 0` in the skip branch would only end that line
# and the regeneration below would run anyway, against a binary that is not
# there.
check-gen:
	@if [ ! -x ${SATL_BIN} ]; then \
	    echo '' >&2; \
	    echo '  ****  check-gen SKIPPED  ****' >&2; \
	    echo '  No satl binary at ${SATL_BIN}.' >&2; \
	    echo '  The committed CLI reference is NOT being verified.' >&2; \
	    echo '  Run `make gen-fresh` to enable this check.' >&2; \
	    echo '' >&2; \
	    exit 0; \
	fi; \
	rm -rf ${.CURDIR}/.cache/check-gen; \
	mkdir -p ${.CURDIR}/.cache/check-gen; \
	${PYTHON} tools/gen_cli.py --satl ${SATL_BIN} --satld ${SATLD_BIN} \
	    --out ${.CURDIR}/.cache/check-gen --overlay ${OVERLAY} >/dev/null || exit 1; \
	if ! diff -ru ${CLI_OUT} ${.CURDIR}/.cache/check-gen; then \
	    echo '' >&2; \
	    echo 'check-gen: docs/reference/cli/ is not what the generator produces.' >&2; \
	    echo 'Either the pages were hand-edited (they say not to) or the binary' >&2; \
	    echo 'moved on. Run `make gen` and commit the result.' >&2; \
	    exit 1; \
	fi; \
	if [ -f ${SATL_SRC}/etc/satld.toml.sample ] && \
	    ! diff -u ${SAMPLE} ${SATL_SRC}/etc/satld.toml.sample >/dev/null; then \
	    echo 'check-gen: docs/reference/satld.toml.sample differs from ${SATL_SRC}.' >&2; \
	    echo 'Run `make gen` and commit the result.' >&2; \
	    exit 1; \
	fi; \
	echo 'check-gen: OK -- committed pages match the generator'

check-drift:
	@if [ ! -x ${SATL_BIN} ]; then \
	    echo '' >&2; \
	    echo '  ****  check-drift SKIPPED  ****' >&2; \
	    echo '  No satl binary at ${SATL_BIN}; nothing to compare against' >&2; \
	    echo '  ${SATL_SRC}. Run `make gen-fresh` to enable this check.' >&2; \
	    echo '' >&2; \
	else \
	    ${PYTHON} tools/check_drift.py --satl ${SATL_BIN} --satl-src ${SATL_SRC}; \
	fi

check-config:
	@${PYTHON} tools/check_config_keys.py --satl-src ${SATL_SRC} \
	    --page ${CONFIG_PAGE}

check-nav:
	@${PYTHON} tools/check_nav.py --config ${.CURDIR}/mkdocs.yml \
	    --docs ${.CURDIR}/docs --require reference/cli

check: build check-nav check-config check-drift check-gen
	@echo ''
	@echo 'make check: all checks passed.'

# --------------------------------------------------------------------------- #
# deployment
# --------------------------------------------------------------------------- #

# `check` already depends on `build`, so the site is built and verified exactly
# once before anything leaves the machine. Note that on a host with no SatL
# binaries -- which is any host but the FreeBSD one -- check-drift and check-gen
# announce themselves as skipped, and the gate is then only build --strict,
# check-nav and check-config. Read the notices; they are the difference between
# a verified publish and a plausible one.
# First, not last: being told to commit is worth knowing before a full strict
# build, not after it. bmake walks prerequisites left to right.
check-clean-tree:
	@if [ ${DIRTY_OK} = false ] && \
	    [ -n "`git -C ${.CURDIR} status --porcelain`" ]; then \
	    echo '' >&2; \
	    echo 'deploy: the working tree has uncommitted changes.' >&2; \
	    echo '' >&2; \
	    echo 'Page dates are read from git, so publishing now would date every' >&2; \
	    echo 'page by a commit that does not contain what is being published.' >&2; \
	    echo 'Commit first, or `make deploy ALLOW_DIRTY=1` if you mean it.' >&2; \
	    echo '' >&2; \
	    git -C ${.CURDIR} status --short >&2; \
	    exit 1; \
	fi

deploy: check-clean-tree check
	@DEPLOY_HOST=${DEPLOY_HOST} DEPLOY_ROOT=${DEPLOY_ROOT} \
	    DEPLOY_KEEP=${DEPLOY_KEEP} SITE=${.CURDIR}/site \
	    sh ${.CURDIR}/tools/deploy.sh

clean:
	rm -rf ${.CURDIR}/site ${.CURDIR}/.cache/check-gen
	find ${.CURDIR}/tools -name '__pycache__' -type d -exec rm -rf {} +
