#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# install-satl.sh -- prepare a FreeBSD host and install SatL on it.
#
# This is steps 1 to 8 of https://docs.satl.cc/start/install/ in one command,
# for ONE node. It deliberately does nothing cluster-shaped: no `swarm init`
# (a fresh satld self-initialises a cluster of one, so there is nothing to
# init), no join, no advertise_addr. Those are decisions about a fabric this
# script cannot see.
#
# Every step is idempotent and reports [ ok ] / [skip] / [warn], so a second
# run reads as a diff against the host rather than as an install.
#
# Four things here are not obvious from the documentation, and are the reason
# this file exists:
#
#   1. pf.ko is MANDATORY, not optional. satld brings up its bridge at
#      startup, and even in the default pf_mode = "check" that path runs
#      `pfctl -nf` to syntax-check the anchor -- and on FreeBSD 15 pfctl
#      speaks netlink to *parse*. Without the module loaded, satld refuses to
#      start. So the module is loaded unconditionally.
#
#   2. The package ships satld.toml.sample, never satld.toml, and the built-in
#      pf_mode default is "check": rules are generated, syntax-checked, and
#      never loaded. A published port is then allocated and printed by
#      `satl ps` exactly as if it worked, with no redirect and nothing logged
#      as an error. This script writes the config, with pf_mode = "enforce".
#
#   3. kern.racct.enable is a boot-time tunable. Until the host reboots,
#      --memory and --cpus are accepted and NOT enforced. The line goes into
#      loader.conf here; the reboot is offered at the very end.
#
#   4. /etc/pf.conf is the only pre-existing file this script edits. It is
#      backed up first, patched into a candidate, and the candidate is passed
#      through `pfctl -nf` BEFORE it is installed. A failed check leaves the
#      original untouched and the script refuses.
#
# Run it as root, in two steps, so you can see what you are about to run:
#
#     fetch https://docs.satl.cc/install-satl.sh
#     sh install-satl.sh --pkg https://satl.cc/download/satl-freebsd.pkg
#
# `sh install-satl.sh --help` for the flags.

set -e

# --------------------------------------------------------------------------- #
# paths
# --------------------------------------------------------------------------- #

PREFIX=/usr/local
CONF_DIR=$PREFIX/etc/satl
CONF=$CONF_DIR/satld.toml
SAMPLE=$CONF_DIR/satld.toml.sample
STATE_DIR=/var/db/satl
SOCKET=/var/run/satl.sock
PF_CONF=/etc/pf.conf
LOADER=/boot/loader.conf
REGISTRY_CONF_DIR=$PREFIX/etc/docker-registry
REGISTRY_CONF=$REGISTRY_CONF_DIR/config.yml
REGISTRY_ROOT=/var/db/satl-registry
SMOKE_IMAGE=docker.io/freebsd/freebsd-runtime:15.1

# --------------------------------------------------------------------------- #
# options
# --------------------------------------------------------------------------- #

PKG_SRC=
ZPOOL=
ASSUME_YES=0
REBOOT_CHOICE=ask
PF_MODE=enforce
WITH_LINUX=0
WITH_REGISTRY=0
SMOKE_TEST=0
VERIFY_ONLY=0

# Carried between steps.
WE_WROTE_PF_CONF=0
PF_CONF_BACKUP=
ZFS_ROOT=
WORK_DIR=
VERIFY_FAIL=0
VERIFY_WARN=0

usage() {
	cat <<'USAGE'
install-satl.sh -- prepare a FreeBSD host and install SatL. Run as root.

  --pkg PATH|URL      the package to install. Without it, a single
                      dist/satl-*.pkg under the current directory is used.
  --zpool NAME        ZFS pool to hold SatL's state (skips the prompt)
  -y, --yes           take the default answer to every prompt
  --reboot            reboot at the end if kern.racct.enable needs it
  --no-reboot         never reboot; say what is pending instead
  --pf-mode MODE      enforce (default), check, or disabled
  --with-linux        enable the linuxulator, for linux/* images
  --with-registry     install a loopback-only registry on 127.0.0.1:5000
  --smoke-test        pull and run a container at the end (needs egress)
  --verify-only       run the final checklist and exit, changing nothing
  -h, --help          this text

This script installs ONE node. It never touches cluster membership: a fresh
satld already is a cluster of one, and joining a real cluster is a decision
about addresses this script cannot make for you.
USAGE
}

while [ $# -gt 0 ]; do
	case $1 in
	--pkg)
		[ $# -ge 2 ] || { echo "--pkg needs a value" >&2; exit 2; }
		PKG_SRC=$2
		shift 2
		;;
	--pkg=*) PKG_SRC=${1#--pkg=}; shift ;;
	--zpool)
		[ $# -ge 2 ] || { echo "--zpool needs a value" >&2; exit 2; }
		ZPOOL=$2
		shift 2
		;;
	--zpool=*) ZPOOL=${1#--zpool=}; shift ;;
	-y|--yes) ASSUME_YES=1; shift ;;
	--reboot) REBOOT_CHOICE=yes; shift ;;
	--no-reboot) REBOOT_CHOICE=no; shift ;;
	--pf-mode)
		[ $# -ge 2 ] || { echo "--pf-mode needs a value" >&2; exit 2; }
		PF_MODE=$2
		shift 2
		;;
	--pf-mode=*) PF_MODE=${1#--pf-mode=}; shift ;;
	--with-linux) WITH_LINUX=1; shift ;;
	--with-registry) WITH_REGISTRY=1; shift ;;
	--smoke-test) SMOKE_TEST=1; shift ;;
	--verify-only) VERIFY_ONLY=1; shift ;;
	-h|--help) usage; exit 0 ;;
	*)
		echo "unknown option: $1" >&2
		echo "" >&2
		usage >&2
		exit 2
		;;
	esac
done

case $PF_MODE in
enforce|check|disabled) ;;
*)
	echo "--pf-mode must be enforce, check or disabled (got: $PF_MODE)" >&2
	exit 2
	;;
esac

# --------------------------------------------------------------------------- #
# output
# --------------------------------------------------------------------------- #
#
# Operator-facing text is ASCII only, on purpose: syslogd rewrites bytes in
# 0x80-0x9f irrecoverably, and anything this script prints tends to end up
# pasted into a bug report next to a log line.

hdr()  { printf '\n== %s\n' "$*"; }
ok()   { printf '[ ok ] %s\n' "$*"; }
skip() { printf '[skip] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*"; }
note() { printf '[note] %s\n' "$*"; }

die() {
	printf '[fail] %s\n' "$*" >&2
	exit 1
}

cleanup() {
	[ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
	return 0
}
trap cleanup EXIT HUP INT TERM

# confirm <default: y|n> <question>
#
# --yes takes the DEFAULT, not "yes": the one question whose default is No is
# the one that can drop your ssh session, and an unattended run must not walk
# into it.
confirm() {
	_def=$1
	shift
	if [ "$ASSUME_YES" = 1 ]; then
		[ "$_def" = y ]
		return $?
	fi
	if [ ! -t 0 ]; then
		die "$* -- no terminal to ask on. Re-run with --yes (and --zpool if the host has several pools)."
	fi
	if [ "$_def" = y ]; then
		printf '%s [Y/n] ' "$*"
	else
		printf '%s [y/N] ' "$*"
	fi
	read -r _answer || _answer=
	case $_answer in
	[Yy]|[Yy][Ee][Ss]) return 0 ;;
	[Nn]|[Nn][Oo]) return 1 ;;
	"") [ "$_def" = y ] ;;
	*) [ "$_def" = y ] ;;
	esac
}

# ask_value <default> <question>  -- echoes the answer on stdout.
ask_value() {
	_def=$1
	shift
	if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
		printf '%s\n' "$_def"
		return 0
	fi
	printf '%s [%s] ' "$*" "$_def" >&2
	read -r _answer || _answer=
	[ -n "$_answer" ] || _answer=$_def
	printf '%s\n' "$_answer"
}

# --------------------------------------------------------------------------- #
# 0. preflight
# --------------------------------------------------------------------------- #

step_preflight() {
	hdr "host"

	[ "$(id -u)" = 0 ] ||
		die "must run as root: satld installs a devfs ruleset, creates a ZFS dataset and loads pf. Re-run under sudo or doas."

	_os=$(uname -s)
	[ "$_os" = FreeBSD ] ||
		die "this is $_os. SatL is FreeBSD-only -- it drives jails, VNET, ZFS and pf."

	command -v pkg >/dev/null 2>&1 ||
		die "pkg(8) not found; nothing here can install anything."

	_arch=$(uname -p 2>/dev/null || uname -m)
	if [ "$_arch" != amd64 ] && [ "$_arch" != x86_64 ]; then
		warn "architecture is $_arch; amd64 is the only one SatL is built for. pkg will refuse the package if its ABI does not match."
	fi

	ok "FreeBSD $(uname -r) on $_arch"
}

# --------------------------------------------------------------------------- #
# 1. ocijail
# --------------------------------------------------------------------------- #
#
# Installed before the package rather than left to its dependency. The .pkg
# pins the exact ocijail version that was in the build host's repository at
# `make package` time, so a node whose repository offers a different one
# argues about the dependency instead of installing. Having it already
# present, from this host's own repository, is the case that works.

step_ocijail() {
	hdr "ocijail (the OCI runtime SatL drives; it never implements one)"

	if pkg info -e ocijail 2>/dev/null; then
		skip "ocijail $(pkg query %v ocijail 2>/dev/null) already installed"
		return 0
	fi

	env ASSUME_ALWAYS_YES=yes pkg install -y ocijail ||
		die "pkg install ocijail failed. Without it satld starts cleanly and every container fails at the create step."
	ok "installed ocijail $(pkg query %v ocijail 2>/dev/null)"
}

# --------------------------------------------------------------------------- #
# 2. the ZFS root dataset
# --------------------------------------------------------------------------- #
#
# The only hard refusal in satld's startup: no dataset, no daemon. ZFS is
# mandatory and there is no fallback storage driver.

step_zfs() {
	hdr "ZFS root dataset"

	_pools=$(zpool list -H -o name 2>/dev/null || true)
	[ -n "$_pools" ] ||
		die "no ZFS pool on this host. ZFS is mandatory for SatL -- satld refuses to start without its root dataset, and there is no fallback."

	_count=$(printf '%s\n' "$_pools" | wc -l | tr -d ' ')

	if [ -z "$ZPOOL" ]; then
		if [ "$_count" = 1 ]; then
			_default=$_pools
		elif printf '%s\n' "$_pools" | grep -qx zroot; then
			_default=zroot
		else
			_default=$(printf '%s\n' "$_pools" | head -1)
		fi
		if [ "$_count" != 1 ] && [ "$ASSUME_YES" = 1 ]; then
			die "this host has $_count pools ($(printf '%s' "$_pools" | tr '\n' ' ')) and --yes cannot pick one. Pass --zpool NAME."
		fi
		printf 'Pools available: %s\n' "$(printf '%s' "$_pools" | tr '\n' ' ')"
		ZPOOL=$(ask_value "$_default" "Use which pool for SatL state?")
	fi

	printf '%s\n' "$_pools" | grep -qx "$ZPOOL" ||
		die "no pool named '$ZPOOL' on this host. Available: $(printf '%s' "$_pools" | tr '\n' ' ')"

	ZFS_ROOT=$ZPOOL/satl

	if zfs list -H -o name "$ZFS_ROOT" >/dev/null 2>&1; then
		_mp=$(zfs get -H -o value mountpoint "$ZFS_ROOT" 2>/dev/null || echo -)
		case $_mp in
		none|legacy|-|"")
			# satld's second documented refusal: the dataset exists but has
			# nowhere to be.
			warn "$ZFS_ROOT has no usable mountpoint (mountpoint=$_mp); satld will refuse to start."
			if confirm y "Set mountpoint=$STATE_DIR on $ZFS_ROOT?"; then
				zfs set mountpoint="$STATE_DIR" "$ZFS_ROOT"
				ok "$ZFS_ROOT mountpoint set to $STATE_DIR"
			else
				die "cannot continue: satld needs $ZFS_ROOT mounted somewhere."
			fi
			;;
		*)
			skip "$ZFS_ROOT exists, mounted at $_mp"
			[ "$_mp" = "$STATE_DIR" ] ||
				note "its mountpoint is not $STATE_DIR; satld warns about that at startup. Set state_dir in satld.toml to match if you meant it."
			;;
		esac
	else
		zfs create -o mountpoint="$STATE_DIR" "$ZFS_ROOT" ||
			die "zfs create -o mountpoint=$STATE_DIR $ZFS_ROOT failed"
		ok "created $ZFS_ROOT at $STATE_DIR"
	fi

	note "satld creates the raft, images, layers, containers and volumes children itself on first start."
}

# --------------------------------------------------------------------------- #
# 3. IP forwarding
# --------------------------------------------------------------------------- #
#
# Skipping this produces SatL's most misleading symptom: inbound published
# ports answer and containers cannot reach anything. satld warns at startup,
# but the shape of the failure looks like a container problem.

step_forwarding() {
	hdr "IP forwarding"

	if [ "$(sysrc -n gateway_enable 2>/dev/null || echo NO)" = YES ]; then
		skip "gateway_enable=YES already in rc.conf"
	else
		sysrc gateway_enable=YES >/dev/null
		ok "gateway_enable=YES (persists across boots)"
	fi

	if [ "$(sysctl -n net.inet.ip.forwarding 2>/dev/null || echo 0)" = 1 ]; then
		skip "net.inet.ip.forwarding is already 1"
	else
		sysctl net.inet.ip.forwarding=1 >/dev/null
		ok "net.inet.ip.forwarding=1 (applies now)"
	fi
}

# --------------------------------------------------------------------------- #
# 4. pf
# --------------------------------------------------------------------------- #

PF_ANCHOR_RE='^[[:space:]]*(nat-anchor|rdr-anchor|anchor)[[:space:]]+"satl/\*"'

pf_anchor_count() {
	if [ -f "$PF_CONF" ]; then
		# grep -c prints 0 and exits 1 when it matches nothing, so the
		# status is swallowed rather than turned into a second line.
		grep -cE "$PF_ANCHOR_RE" "$PF_CONF" 2>/dev/null || true
	else
		echo 0
	fi
}

# Write the three anchors into a copy of $PF_CONF on stdout, dropping any
# satl anchor already there (which is how a partial state gets repaired).
#
# Two insertion points, because pfctl enforces section order -- options,
# normalization, queueing, translation, filtering -- and a filter anchor
# ahead of a nat rule is a syntax error. So the translation anchors go before
# the first translation-or-filter rule, and the filter anchor before the
# first filter rule. `scrub` is deliberately not in either list: it belongs
# above the translation section and must stay there.
pf_conf_candidate() {
	awk '
	BEGIN { trans = 0; filt = 0 }
	/^[ \t]*(nat-anchor|rdr-anchor|anchor)[ \t]+"satl\/\*"[ \t]*$/ { next }
	{
		if (!trans && $0 ~ /^[ \t]*(nat|rdr|binat|nat-anchor|rdr-anchor|binat-anchor|pass|block|match|antispoof|anchor|load)([ \t]|$)/) {
			print "nat-anchor \"satl/*\""
			print "rdr-anchor \"satl/*\""
			trans = 1
		}
		if (!filt && $0 ~ /^[ \t]*(pass|block|match|antispoof|anchor|load)([ \t]|$)/) {
			print "anchor     \"satl/*\""
			filt = 1
		}
		print
	}
	END {
		if (!trans) {
			print "nat-anchor \"satl/*\""
			print "rdr-anchor \"satl/*\""
		}
		if (!filt) print "anchor     \"satl/*\""
	}
	' "$PF_CONF"
}

pf_conf_fresh() {
	cat <<'PFCONF'
# /etc/pf.conf -- written by install-satl.sh.
#
# SatL owns the satl/* anchors and never writes a rule outside them.
# Translation anchors must be declared before any filter rule.
nat-anchor "satl/*"
rdr-anchor "satl/*"
anchor     "satl/*"

# A host with no firewall policy of its own needs exactly one line after them.
pass all
PFCONF
}

step_pf_module() {
	hdr "pf"

	# Unconditional: satld's startup brings up its bridge and syntax-checks
	# the nat anchor with `pfctl -nf` even in pf_mode = "check", and pfctl on
	# FreeBSD 15 needs netlink -- i.e. the module -- just to parse. No
	# module, no daemon.
	if kldstat -q -m pf 2>/dev/null; then
		skip "pf.ko already loaded"
	else
		kldload pf ||
			die "kldload pf failed. satld cannot start without it: it runs pfctl at startup even in pf_mode = \"check\"."
		ok "pf.ko loaded (satld needs it even in pf_mode = \"check\")"
	fi
}

step_pf_conf() {
	_have=$(pf_anchor_count)

	if [ "$_have" = 3 ]; then
		skip "$PF_CONF already declares the three satl/* anchors"
		return 0
	fi

	if [ ! -s "$PF_CONF" ]; then
		pf_conf_fresh >"$PF_CONF"
		WE_WROTE_PF_CONF=1
		ok "wrote $PF_CONF (three anchors, then a single pass all)"
		return 0
	fi

	# An existing ruleset. Build the candidate and let pfctl judge it BEFORE anything is backed up
	# or installed: a run that refuses should leave no trace at all, not a
	# backup of a file it never touched.
	WORK_DIR=${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/install-satl.XXXXXXXX")}
	_cand=$WORK_DIR/pf.conf.candidate
	pf_conf_candidate >"$_cand"

	if ! pfctl -nf "$_cand" 2>"$WORK_DIR/pfctl.err"; then
		printf '\n'
		sed 's/^/       /' "$WORK_DIR/pfctl.err" || true
		printf '\n'
		warn "the patched ruleset does not parse, so $PF_CONF was left exactly as it was."
		note "Add these three lines by hand, translation anchors before any filter rule:"
		printf '\n       nat-anchor "satl/*"\n       rdr-anchor "satl/*"\n       anchor     "satl/*"\n\n'
		die "refusing to install a pf.conf that pfctl rejects"
	fi

	PF_CONF_BACKUP=$PF_CONF.satl-$(date -u +%Y%m%d%H%M%S)
	cp -p "$PF_CONF" "$PF_CONF_BACKUP"
	ok "backed up $PF_CONF to $PF_CONF_BACKUP"
	cat "$_cand" >"$PF_CONF"
	ok "added the three satl/* anchors to $PF_CONF (pfctl -nf passed)"
	if [ "$_have" != 0 ]; then
		note "$_have of the three anchors were already there; all three were rewritten together so their order is right."
	fi
}

step_pf_enable() {
	if [ "$(sysrc -n pf_enable 2>/dev/null || echo NO)" = YES ]; then
		skip "pf_enable=YES already in rc.conf"
	else
		sysrc pf_enable=YES >/dev/null
		ok "pf_enable=YES (pf comes up at the next boot)"
	fi

	if pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
		pfctl -f "$PF_CONF" ||
			die "pfctl -f $PF_CONF failed on a ruleset that passed pfctl -nf; the backup is at $PF_CONF_BACKUP"
		ok "reloaded $PF_CONF into a running pf"
		return 0
	fi

	# pf is not enabled. Enabling it applies whatever policy is in pf.conf --
	# which is only safe to do unasked when that policy is the one we just
	# wrote.
	if [ "$WE_WROTE_PF_CONF" = 1 ]; then
		pfctl -f "$PF_CONF"
		pfctl -e 2>/dev/null || true
		ok "pf enabled with the ruleset this script wrote"
		return 0
	fi

	warn "pf is DISABLED and $PF_CONF is yours, not this script's."
	note "Enabling it now loads YOUR ruleset. If it blocks inbound ssh you lose this session."
	if confirm n "Enable pf now?"; then
		pfctl -f "$PF_CONF"
		pfctl -e 2>/dev/null || true
		ok "pf enabled"
	else
		note "left disabled. satld will still start; published ports (-p) stay dead until you run 'service pf start'."
	fi
}

# --------------------------------------------------------------------------- #
# 5. boot-time tunable
# --------------------------------------------------------------------------- #

step_loader() {
	hdr "boot-time tunables"

	# sysrc(8) refuses dotted names, so the line is appended directly. The
	# `| tee` form the documentation shows is for doas/sudo users, whose
	# shell would open a `>>` redirection as themselves; this script is
	# already root.
	if grep -qE '^[[:space:]]*kern\.racct\.enable=' "$LOADER" 2>/dev/null; then
		_val=$(grep -E '^[[:space:]]*kern\.racct\.enable=' "$LOADER" | tail -1 | sed 's/.*=//' | tr -d '"')
		if [ "$_val" = 1 ]; then
			skip "kern.racct.enable=1 already in $LOADER"
		else
			warn "$LOADER sets kern.racct.enable=$_val; resource limits will never be enforced. Fix that line by hand -- this script will not edit it."
		fi
	else
		printf 'kern.racct.enable=1\n' >>"$LOADER"
		ok "appended kern.racct.enable=1 to $LOADER"
	fi

	# if_vxlan_load is deliberately not written: overlay networks are a
	# cluster feature, out of scope here, and satld runs `kldload -n
	# if_vxlan` itself before it creates the first tunnel.
	if [ "$(sysctl -n kern.racct.enable 2>/dev/null || echo 0)" != 1 ]; then
		note "kern.racct.enable is 0 for this boot: --memory and --cpus will be ACCEPTED BUT NOT ENFORCED until a reboot."
	fi
}

# --------------------------------------------------------------------------- #
# 6. the package
# --------------------------------------------------------------------------- #

resolve_pkg() {
	if [ -z "$PKG_SRC" ]; then
		# One match is a decision; several is not.
		set -- ./dist/satl-*.pkg
		if [ -f "$1" ] && [ $# = 1 ]; then
			PKG_SRC=$1
		elif [ -f "$1" ]; then
			die "several packages under ./dist ($*). Name one with --pkg."
		else
			cat >&2 <<'NOPKG'
[fail] no package to install.

       Three ways to get one:
         --pkg ./satl-0.1.0.pkg              a file you already have
         --pkg https://.../satl-freebsd.pkg  fetched over https
         make package                        in a SatL checkout, then
                                             --pkg dist/satl-0.1.0.pkg
NOPKG
			exit 1
		fi
	fi

	case $PKG_SRC in
	*://*)
		WORK_DIR=${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/install-satl.XXXXXXXX")}
		_dest=$WORK_DIR/$(basename "$PKG_SRC")
		fetch -o "$_dest" "$PKG_SRC" || die "could not fetch $PKG_SRC"
		PKG_FILE=$_dest
		ok "fetched $(basename "$PKG_SRC")"
		;;
	*)
		[ -f "$PKG_SRC" ] || die "no such file: $PKG_SRC"
		PKG_FILE=$PKG_SRC
		verify_checksum "$PKG_FILE"
		;;
	esac
}

verify_checksum() {
	_file=$1
	_sums=$(dirname "$_file")/CHECKSUM.SHA512
	if [ ! -f "$_sums" ]; then
		return 0
	fi
	command -v sha512sum >/dev/null 2>&1 || return 0
	if (cd "$(dirname "$_file")" && grep -F "$(basename "$_file")" CHECKSUM.SHA512 | sha512sum -c --status -); then
		ok "checksum verified against $(basename "$_sums")"
	else
		die "$(basename "$_file") does not match $_sums"
	fi
}

step_package() {
	hdr "the package"

	resolve_pkg

	_new=$(pkg query -F "$PKG_FILE" %v 2>/dev/null || echo "?")

	if pkg info -e satl 2>/dev/null; then
		_old=$(pkg query %v satl 2>/dev/null || echo "?")
		# `pkg add -f` is the upgrade path SatL documents, precisely because
		# it goes through the package manager: `make install` writes files no
		# package knows about.
		pkg add -f "$PKG_FILE" || pkg_add_failed
		ok "satl $_old -> $_new (pkg add -f)"
		note "the four numbered prerequisites in the package's own message above are steps this script has just done."
		note "running containers are re-adopted at startup, not restarted; a 'satl ps' uptime that resets to seconds is a bug, not an upgrade cost."
	else
		pkg add "$PKG_FILE" || pkg_add_failed
		ok "installed satl $_new"
		note "the four numbered prerequisites in the package's own message above are steps this script has just done."
	fi
}

pkg_add_failed() {
	printf '\n'
	warn "pkg add failed."
	note "The most common cause is the ocijail dependency: the package pins the exact version that was in the BUILD host's repository, and this host's repository may offer another."
	note "Check with: pkg info -dF $PKG_FILE   and   pkg query %v ocijail"
	exit 1
}

# --------------------------------------------------------------------------- #
# 7. satld.toml
# --------------------------------------------------------------------------- #

step_config() {
	hdr "satld.toml"

	if [ -f "$CONF" ]; then
		skip "$CONF exists; not overwritten"
		if grep -qE '^[[:space:]]*pf_mode[[:space:]]*=' "$CONF"; then
			_mode=$(grep -E '^[[:space:]]*pf_mode[[:space:]]*=' "$CONF" | tail -1 | sed 's/.*=//' | tr -d ' "')
			if [ "$_mode" = enforce ]; then
				ok "its pf_mode is \"enforce\""
			else
				warn "its pf_mode is \"$_mode\": published ports are allocated and shown by 'satl ps', and no redirect is ever installed. Nothing is logged as an error."
			fi
		else
			warn "it sets no pf_mode, so the built-in default \"check\" applies: published ports will look allocated and never work."
		fi
		return 0
	fi

	[ -f "$SAMPLE" ] || die "no $SAMPLE -- did the package install?"

	cp "$SAMPLE" "$CONF"

	# The sample ships every key commented out, so a copy on its own changes
	# nothing: pf_mode is still "check". Uncomment what this host needs, then
	# ASSERT the result -- a sed that silently matched nothing would put back
	# the exact trap this script exists to remove.
	sed -i '' -e "s|^#pf_mode = \"check\"\$|pf_mode = \"$PF_MODE\"|" "$CONF"
	grep -qE '^pf_mode[[:space:]]*=' "$CONF" ||
		die "could not uncomment pf_mode in $CONF (the sample's shape changed). Set pf_mode = \"$PF_MODE\" by hand."
	ok "wrote $CONF with pf_mode = \"$PF_MODE\""

	if [ "$ZPOOL" != zroot ]; then
		sed -i '' -e "s|^#zfs_root = \"zroot/satl\"\$|zfs_root = \"$ZFS_ROOT\"|" "$CONF"
		grep -qE '^zfs_root[[:space:]]*=' "$CONF" ||
			die "could not uncomment zfs_root in $CONF. Set zfs_root = \"$ZFS_ROOT\" by hand, or satld will look for zroot/satl and refuse to start."
		ok "set zfs_root = \"$ZFS_ROOT\""
	fi

	note "every other key stays commented; the sample explains each one, and unknown keys are refused at startup."
}

# --------------------------------------------------------------------------- #
# 8. enable and start
# --------------------------------------------------------------------------- #

step_service() {
	hdr "the satld service"

	if [ "$(sysrc -n satld_enable 2>/dev/null || echo NO)" = YES ]; then
		skip "satld_enable=YES already in rc.conf"
	else
		sysrc satld_enable=YES >/dev/null
		ok "satld_enable=YES"
	fi

	if service satld status >/dev/null 2>&1; then
		service satld restart >/dev/null 2>&1 || die "service satld restart failed"
		ok "restarted satld"
	else
		service satld start >/dev/null 2>&1 || satld_start_failed
		ok "started satld"
	fi

	_waited=0
	while [ ! -S "$SOCKET" ] && [ "$_waited" -lt 15 ]; do
		sleep 1
		_waited=$((_waited + 1))
	done
	[ -S "$SOCKET" ] || satld_start_failed
	ok "$SOCKET is up (after ${_waited}s)"
}

satld_start_failed() {
	printf '\n'
	warn "satld did not come up. Its last 40 log lines:"
	printf '\n'
	# Always `grep -a`: one non-ASCII byte anywhere in /var/log/messages --
	# from any program on this host -- makes plain grep treat the whole file
	# as binary and print NOTHING, which looks exactly like "the daemon
	# logged nothing".
	grep -a satld /var/log/messages 2>/dev/null | tail -40 | sed 's/^/       /' ||
		note "nothing under the satld tag in /var/log/messages yet."
	printf '\n'
	exit 1
}

# --------------------------------------------------------------------------- #
# 9. optional extras
# --------------------------------------------------------------------------- #

step_linux() {
	hdr "linuxulator (--with-linux)"

	if [ "$(sysrc -n linux_enable 2>/dev/null || echo NO)" = YES ]; then
		skip "linux_enable=YES already in rc.conf"
	else
		sysrc linux_enable=YES >/dev/null
		ok "linux_enable=YES"
	fi

	service linux start >/dev/null 2>&1 || kldload -n linux linux64 >/dev/null 2>&1 || true

	_osrelease=$(sysctl -n compat.linux.osrelease 2>/dev/null || true)
	if [ -n "$_osrelease" ]; then
		ok "linuxulator available (compat.linux.osrelease=$_osrelease); linux/* images may be selected"
	else
		warn "compat.linux.osrelease is not readable; linux images will not be schedulable on this node."
	fi
	note "running a glibc or musl image also needs a Linux userland in the image itself -- the modules only make the syscalls work."
}

step_registry() {
	hdr "loopback registry (--with-registry)"

	_missing=
	for _p in docker-registry skopeo; do
		pkg info -e "$_p" 2>/dev/null || _missing="$_missing $_p"
	done
	if [ -n "$_missing" ]; then
		env ASSUME_ALWAYS_YES=yes pkg install -y $_missing ||
			die "pkg install$_missing failed"
		ok "installed$_missing"
	else
		skip "docker-registry and skopeo already installed"
	fi

	mkdir -p "$REGISTRY_ROOT"
	mkdir -p "$REGISTRY_CONF_DIR"

	# The package installs config.yml as a copy of config.yml.sample: htpasswd
	# auth on, listening on EVERY interface, storage under /var/lib/registry.
	# An unmodified copy is the package default, not a decision, so it is
	# replaced; a config.yml that differs from the sample is yours and is kept.
	_wrote_conf=0
	if [ -f "$REGISTRY_CONF" ] && ! cmp -s "$REGISTRY_CONF" "$REGISTRY_CONF.sample" 2>/dev/null; then
		skip "$REGISTRY_CONF differs from the package sample; not overwritten"
	else
		cat >"$REGISTRY_CONF" <<'REGCONF'
# Local base-image registry: loopback only, no auth, no TLS.
#
# 127.0.0.1:5000 because plain HTTP is the ONLY thing SatL will speak to a
# loopback address, and the only thing it will speak to nothing else: every
# other host is contacted over HTTPS, and there is no insecure-registry
# override. So an unauthenticated registry is a per-node, loopback thing by
# construction -- pushing here distributes an image to nobody.
#
# rootdirectory sits OUTSIDE zroot/satl on purpose: that dataset is satld's,
# and it gets destroyed on its own schedule.
version: 0.1
log:
  fields:
    service: satl-registry
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/db/satl-registry
  delete:
    enabled: true
http:
  addr: 127.0.0.1:5000
  headers:
    X-Content-Type-Options: [nosniff]
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
REGCONF
		ok "wrote $REGISTRY_CONF (loopback, no auth, delete enabled)"
		_wrote_conf=1
	fi

	if [ "$(sysrc -n docker_registry_enable 2>/dev/null || echo NO)" = YES ]; then
		skip "docker_registry_enable=YES already in rc.conf"
	else
		sysrc docker_registry_enable=YES >/dev/null
		ok "docker_registry_enable=YES"
	fi

	# The redirection is load-bearing over ssh: the rc.d script starts the
	# registry under daemon(8) without -f, so it holds the stdout/stderr it
	# was started with and an unredirected ssh session never returns.
	# A restart when the config was just rewritten, so a registry already
	# running on the package default picks the loopback config up.
	if [ "$_wrote_conf" = 1 ] && service docker_registry status >/dev/null 2>&1; then
		service docker_registry restart >/dev/null 2>&1 || true
	else
		service docker_registry start >/dev/null 2>&1 || true
	fi

	# daemon(8) returns before the registry has bound its socket -- measured
	# on a test VM, the log said "listening on 127.0.0.1:5000" two seconds
	# after `service ... start` returned. So poll rather than race it.
	_waited=0
	while ! curl -sf -m 2 http://127.0.0.1:5000/v2/ >/dev/null 2>&1 && [ "$_waited" -lt 10 ]; do
		sleep 1
		_waited=$((_waited + 1))
	done

	if curl -sf -m 2 http://127.0.0.1:5000/v2/ >/dev/null 2>&1; then
		ok "registry answering on http://127.0.0.1:5000/v2/ (after ${_waited}s)"
		note "it is empty. Seed a base image with: skopeo copy --all --dest-tls-verify=false docker://docker.io/freebsd/freebsd-runtime:15.1 docker://127.0.0.1:5000/satl-test/freebsd-runtime:15.1"
	else
		warn "the registry is not answering on 127.0.0.1:5000; see /var/log/docker-registry.log"
	fi
}

step_smoke() {
	hdr "smoke test (--smoke-test)"

	note "pulling $SMOKE_IMAGE from Docker Hub over https; this needs egress."
	if satl run --rm "$SMOKE_IMAGE" /bin/echo satl-ok; then
		ok "a container ran and exited: pull, ZFS clone, jail, VNET and teardown all work"
	else
		warn "the smoke test failed. The install itself is not necessarily broken -- check egress first, then: grep -a satld /var/log/messages | tail -40"
	fi
}

# --------------------------------------------------------------------------- #
# 10. verification
# --------------------------------------------------------------------------- #

row() {
	_label=$1
	_status=$2
	_detail=$3
	_dots='..........................................'
	_width=$((30 - ${#_label}))
	if [ "$_width" -gt 0 ]; then
		_pad=$(printf '%s' "$_dots" | cut -c1-"$_width")
	else
		_pad=..
	fi
	printf '  %s %s %-4s %s\n' "$_label" "$_pad" "$_status" "$_detail"
	case $_status in
	FAIL) VERIFY_FAIL=$((VERIFY_FAIL + 1)) ;;
	WARN) VERIFY_WARN=$((VERIFY_WARN + 1)) ;;
	esac
}

step_verify() {
	hdr "verification"

	_racct=$(sysctl -n kern.racct.enable 2>/dev/null || echo 0)
	if [ "$_racct" = 1 ]; then
		row kern.racct.enable PASS "(1) rctl limits are enforced"
	else
		row kern.racct.enable WARN "(0) --memory/--cpus accepted, NOT enforced until reboot"
	fi

	_fwd=$(sysctl -n net.inet.ip.forwarding 2>/dev/null || echo 0)
	if [ "$_fwd" = 1 ]; then
		row net.inet.ip.forwarding PASS "(1)"
	else
		row net.inet.ip.forwarding FAIL "(0) containers have no outbound connectivity"
	fi

	if ! kldstat -q -m pf 2>/dev/null; then
		row pf.ko FAIL "not loaded; satld cannot start"
	elif pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
		row pf PASS "Enabled"
	else
		row pf WARN "Disabled; published ports will not work"
	fi

	_anchors=$(pf_anchor_count)
	if [ "$_anchors" = 3 ]; then
		row "pf.conf satl anchors" PASS "3/3"
	else
		row "pf.conf satl anchors" FAIL "$_anchors/3; SatL's rules are loaded and never evaluated"
	fi

	if [ -n "$ZFS_ROOT" ]; then
		_mp=$(zfs get -H -o value mountpoint "$ZFS_ROOT" 2>/dev/null || echo -)
		case $_mp in
		none|legacy|-|"") row "$ZFS_ROOT" FAIL "no usable mountpoint" ;;
		*) row "$ZFS_ROOT" PASS "$_mp" ;;
		esac
	fi

	if pkg info -e ocijail 2>/dev/null; then
		row ocijail PASS "$(pkg query %v ocijail 2>/dev/null)"
	else
		row ocijail FAIL "absent; every container fails at the create step"
	fi

	if service satld status >/dev/null 2>&1; then
		row "satld service" PASS "running"
	else
		row "satld service" FAIL "not running"
	fi

	if [ -S "$SOCKET" ]; then
		row "$SOCKET" PASS "present"
	else
		row "$SOCKET" FAIL "absent; satl has nothing to talk to"
	fi

	if _v=$(satl version 2>/dev/null) && printf '%s' "$_v" | grep -q 'Server:'; then
		_client=$(printf '%s\n' "$_v" | awk '/Version:/ { print $2; exit }')
		row "satl version" PASS "client and server answer ($_client)"
	else
		row "satl version" FAIL "no server answer"
	fi

	if _n=$(satl node ls 2>/dev/null) && printf '%s' "$_n" | grep -q Leader; then
		row "satl node ls" PASS "Ready Active Leader"
	else
		row "satl node ls" FAIL "this node is not a healthy cluster of one"
	fi

	printf '\n'
	if [ "$VERIFY_FAIL" != 0 ]; then
		warn "$VERIFY_FAIL check(s) failed. Start with the log: grep -a satld /var/log/messages | tail -40"
		return 1
	fi
	if [ "$VERIFY_WARN" != 0 ]; then
		ok "no failures, $VERIFY_WARN warning(s) -- read them; each one is a capability you do not have yet."
	else
		ok "every check passed."
	fi
	return 0
}

# `satl node ls` answering at all is the interesting row: nothing here ever
# ran `swarm init`. A fresh satld initialises a one-member cluster on its
# first boot, so the node is Ready, Active and Leader from the first start.

# --------------------------------------------------------------------------- #
# 11. closing notes, then the reboot
# --------------------------------------------------------------------------- #

step_notes() {
	hdr "what this did not do"

	note "no cluster: this node is a cluster of one, which is what a fresh satld makes itself. 'satl swarm join-token' and 'satl swarm join' are how a second node arrives, and that needs addresses this script cannot guess."
	note "no if_vxlan_load in $LOADER: overlay networks are a cluster feature, and satld kldloads if_vxlan itself when the first one is created."
	# These two are conditioned on what the host actually has, not on the
	# flag: a note claiming this node has no registry, on a node that has
	# had one for weeks, is worse than no note at all.
	if ! curl -sf -m 2 http://127.0.0.1:5000/v2/ >/dev/null 2>&1; then
		note "no registry answering on 127.0.0.1:5000: 'satl build' needs a base image to build FROM. See https://docs.satl.cc/start/registry/ or re-run with --with-registry."
	fi
	if [ -z "$(sysctl -n compat.linux.osrelease 2>/dev/null || true)" ]; then
		note "no linuxulator: linux/* images cannot be scheduled on this node. Re-run with --with-linux."
	fi
	[ -z "$PF_CONF_BACKUP" ] ||
		note "your previous ruleset is at $PF_CONF_BACKUP."

	printf '\n'
	printf 'Next: https://docs.satl.cc/start/first-container/\n'
}

step_reboot() {
	[ "$(sysctl -n kern.racct.enable 2>/dev/null || echo 0)" != 1 ] || return 0

	hdr "reboot"
	note "kern.racct.enable is set in $LOADER but needs a reboot to take effect. Until then --memory and --cpus are accepted and not enforced, and per-container metrics are absent."
	note "satld_enable=YES, so satld comes back on its own."

	case $REBOOT_CHOICE in
	yes) ok "rebooting now"; shutdown -r now ;;
	no) note "not rebooting (--no-reboot). Reboot when convenient." ;;
	ask)
		if [ ! -t 0 ]; then
			# Everything above succeeded; a question with a safe default
			# is no reason to exit 1 under a provisioning tool.
			note "no terminal to ask on; not rebooting. Reboot when convenient, or pass --reboot."
		elif confirm n "Reboot now?"; then
			ok "rebooting now"
			shutdown -r now
		else
			note "reboot when convenient."
		fi
		;;
	esac
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

if [ "$VERIFY_ONLY" = 1 ]; then
	[ "$(id -u)" = 0 ] || die "even --verify-only needs root: it reads zfs and pf state."
	# Only to fill in the dataset row; no prompt, no creation.
	if [ -n "$ZPOOL" ]; then
		ZFS_ROOT=$ZPOOL/satl
	elif [ -f "$CONF" ] && grep -qE '^[[:space:]]*zfs_root[[:space:]]*=' "$CONF"; then
		ZFS_ROOT=$(grep -E '^[[:space:]]*zfs_root[[:space:]]*=' "$CONF" | tail -1 | sed 's/.*=//' | tr -d ' "')
	else
		ZFS_ROOT=zroot/satl
	fi
	step_verify
	exit $?
fi

step_preflight
step_ocijail
step_zfs
step_forwarding
step_pf_module
step_pf_conf
step_pf_enable
step_loader
step_package
step_config
step_service
if [ "$WITH_LINUX" = 1 ]; then step_linux; fi
if [ "$WITH_REGISTRY" = 1 ]; then step_registry; fi
if [ "$SMOKE_TEST" = 1 ]; then step_smoke; fi

_rc=0
step_verify || _rc=$?
step_notes
step_reboot

exit $_rc
