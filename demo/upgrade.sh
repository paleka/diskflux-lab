#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# Updates the demo to a release of SnapRAID Daemon and to the newest lab, then
# starts it again. The demo runs in Docker: it is updated by rebuilding its image
# from the sources, not by the installer or snapraidd-upgrade.
#
#   sudo /opt/demo/snapraid-lab/demo/upgrade.sh            the latest release
#   sudo /opt/demo/snapraid-lab/demo/upgrade.sh 2.2.s9     that release
#   sudo /opt/demo/snapraid-lab/demo/upgrade.sh storage    the newest work, not released yet
#   sudo /opt/demo/snapraid-lab/demo/upgrade.sh --check    what runs and what is available
#
# The daemon is the checkout next to the lab (../diskflux-daemon, or DAEMON_SRC;
# ../snapraid-daemon, its earlier name, is used when that is the one there).
# If the build fails the demo keeps running the image it had.
set -eu

LAB=$(cd "$(dirname "$0")/.." && pwd)
DAEMON="${DAEMON_SRC:-$LAB/../diskflux-daemon}"
[ -n "${DAEMON_SRC:-}" ] || [ -d "$DAEMON" ] || [ ! -d "$LAB/../snapraid-daemon" ] || DAEMON="$LAB/../snapraid-daemon"
[ -d "$DAEMON/.git" ] || { echo "upgrade.sh: no checkout of the daemon in $DAEMON" >&2; exit 1; }
DAEMON=$(cd "$DAEMON" && pwd)

# --force: a release tag that was moved on GitHub replaces the one kept here.
# Without it git refuses the tag, and with -q it says nothing.
git -C "$DAEMON" fetch -q --tags --force origin || { echo "upgrade.sh: could not fetch the daemon from $(git -C "$DAEMON" remote get-url origin)" >&2; exit 1; }
git -C "$LAB" fetch -q origin || { echo "upgrade.sh: could not fetch the lab from $(git -C "$LAB" remote get-url origin)" >&2; exit 1; }

latest=$(git -C "$DAEMON" tag -l 'v*.s*' | sort -V | tail -n 1)
now=$(git -C "$DAEMON" describe --tags --match 'v*' 2>/dev/null || git -C "$DAEMON" rev-parse --short HEAD)

if [ "${1:-}" = "--check" ]; then
	echo "daemon: running $now, latest release ${latest#v}"
	echo "lab:    $(git -C "$LAB" log --oneline -1 HEAD), newest $(git -C "$LAB" log --oneline -1 origin/main)"
	exit 0
fi

case "${1:-latest}" in
latest) ref="$latest" ;;
storage) ref="origin/storage" ;;
v*) ref="$1" ;;
*) ref="v$1" ;;
esac
git -C "$DAEMON" rev-parse -q --verify "$ref^{commit}" >/dev/null || { echo "upgrade.sh: $ref is not a release or a branch of the daemon" >&2; exit 1; }

echo "daemon: $now -> $ref"
git -C "$DAEMON" checkout -q --detach "$ref"
echo "lab:    $(git -C "$LAB" log --oneline -1 HEAD) -> $(git -C "$LAB" log --oneline -1 origin/main)"
git -C "$LAB" checkout -q main
git -C "$LAB" merge -q --ff-only origin/main 2>/dev/null || {
	echo "upgrade.sh: the lab here cannot be fast-forwarded to origin/main: its history was rewritten on GitHub, or this copy has commits of its own." >&2
	echo "To take the lab of GitHub as it is, losing the changes made here:" >&2
	echo "  git -C $LAB reset --hard origin/main" >&2
	echo "then run upgrade.sh again. Nothing was built, the demo runs as before." >&2
	exit 1
}

cd "$LAB"
echo "Building the image (several minutes)"
DAEMON_SRC="$DAEMON" docker compose -f docker-compose.yml -f demo/demo.yml build

echo "Starting the new demo"
DAEMON_SRC="$DAEMON" "$LAB/demo/reset.sh"
echo "The demo runs $(git -C "$DAEMON" describe --tags --match 'v*' 2>/dev/null)."
