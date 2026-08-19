#!/bin/sh
# Publish site/ to the documentation host.
#
# Invoked by `make deploy`, which builds the site and runs every check first.
# Do not run this against an unbuilt or half-built site/ -- it will happily
# publish whatever is there.
#
# The transport is tar over ssh, and that is a decision, not laziness. The
# target runs OpenBSD with no rsync package and no intention of gaining one;
# its base openrsync speaks protocol 27 while macOS ships protocol 29, so the
# obvious tool does not actually connect. tar over ssh needs nothing on either
# side that is not already installed, and the whole site is 1.6 MB compressed.
#
# COPYFILE_DISABLE=1 is not optional on macOS. The files under site/ carry
# extended attributes (com.apple.provenance), and without that variable bsdtar
# adds an AppleDouble `._name` entry beside every single one of them -- so every
# published page would arrive with a junk sibling that nginx would serve.
#
# Layout on the host:
#
#     $ROOT/releases/<UTC timestamp>/   one directory per deploy
#     $ROOT/current -> releases/...     what nginx's `root` points at
#
# Which is what makes a rollback a symlink change rather than a rebuild.
set -e

HOST=${DEPLOY_HOST:-fralix@obsd0.fredalix.com}
ROOT=${DEPLOY_ROOT:-/var/www/htdocs/docs.satl.cc}
KEEP=${DEPLOY_KEEP:-3}
SITE=${SITE:-site}

if [ ! -f "$SITE/index.html" ]; then
	echo "deploy: no $SITE/index.html -- run \`make build\` first" >&2
	exit 1
fi

REL=$(date -u +%Y%m%dT%H%M%SZ)
WANT=$(find "$SITE" -type f | wc -l | tr -d ' ')
PRUNE=$((KEEP + 1))

echo "deploy: $WANT files -> $HOST:$ROOT/releases/$REL"

# The remote half is one shell, because the file count check has to happen
# before the symlink moves: a truncated transfer that still extracted cleanly
# would otherwise be published as a site with pages missing.
COPYFILE_DISABLE=1 tar -czf - -C "$SITE" . | ssh "$HOST" "
	set -e
	umask 022

	d=$ROOT/releases/$REL
	mkdir -p \$d
	tar -xzf - -C \$d

	n=\$(find \$d -type f | wc -l | tr -d ' ')
	if [ \"\$n\" != $WANT ]; then
		echo \"deploy: extracted \$n files, expected $WANT -- not publishing\" >&2
		exit 1
	fi
	for f in index.html 404.html sitemap.xml; do
		if [ ! -s \$d/\$f ]; then
			echo \"deploy: \$f missing from the release -- not publishing\" >&2
			exit 1
		fi
	done

	chmod -R a+rX \$d

	# The symlink target is RELATIVE, and that is not a style choice. nginx on
	# the host is chrooted to /var/www, so it resolves the target inside that
	# jail, where an absolute /var/www/... does not exist. The symptom of an
	# absolute target is a 404 on every page with nothing whatsoever in the
	# error log, because try_files does not log ENOENT.
	#
	# ln -sfh replaces the symlink without following it -- see ln(1) on
	# OpenBSD. It is unlink then symlink, so there is a sub-millisecond window
	# where current does not exist; with open_file_cache holding metadata for
	# 30s anyway, that is noise. It is also the safe form: mv would stat() the
	# existing symlink, see a directory, and move the new link *inside* the old
	# release.
	cd $ROOT && ln -sfh releases/$REL current

	cd $ROOT/releases && ls -1dt * | tail -n +$PRUNE | while read old; do
		rm -rf \"\$old\"
	done

	echo \"deploy: published \$(readlink $ROOT/current)\"
"
