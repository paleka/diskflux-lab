#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# Check on a real machine with systemd (made for the Proxmox test LXC) that a
# machine on snapraid-daemon-storage moves to DiskFlux with its next update,
# keeping its settings, arrays, shares and history, and that SnapRAID Daemon
# then installs and runs next to it, also after a reboot.
#
# DiskFlux is built here from a branch of paleka/diskflux (default coexist),
# as version 0.9.0, below every release (from 1.0.0), so that the machine is
# offered the real release afterwards; with the build tools of the release workflow. SnapRAID
# Daemon 2.2 is downloaded from its author's release, with its checksum.
#
# It changes the machine: take a snapshot first, on the Proxmox node:
#     pct snapshot <ID> before-diskflux        (back: pct rollback <ID> before-diskflux)
#
# As root in the machine:
#     bash lxc-check.sh                 move, then SnapRAID Daemon next to it
#     reboot
#     bash lxc-check.sh after-reboot    everything back after the reboot
#
# Environment: BRANCH (coexist), VER (0.9.0).

set -u
BRANCH=${BRANCH:-coexist}
VER=${VER:-0.9.0}
W=/root/diskflux-check
HIS_URL=https://github.com/amadvance/snapraid-daemon/releases/download/v2.2/snapraid-daemon_2.2-1_amd64.deb
HIS_SUM=bef62b3e986ea77d8c368606f55b2a7ac5762d7a5fdfd319629dc529fad56939

PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL  $1"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
say() { echo "$*"; }
die() { echo "lxc-check: $*" >&2; exit 2; }
listens() { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$(printf ':%04X' "$1")" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit !f }'; }
server() { curl -s -m5 -o /dev/null -D - "http://127.0.0.1:$1/snapraid/v1/state" | tr -d '\r' | sed -n 's/^Server: //Ip' | cut -d/ -f1; }
state() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null; }
installed() { state "$1" | grep -q 'ok installed'; }
mainpid() { systemctl show -p MainPID --value "$1"; }
arrays() { ls "$1" 2>/dev/null | sed -n 's/\.conf$//p' | sort | tr '\n' ' '; }
end() { echo; echo "passed: $PASS   failed: $FAILS"; exit $FAILS; }
export -f listens server state installed mainpid

[ "$(id -u)" = 0 ] || die "run it as root"
[ -d /run/systemd/system ] || die "systemd is not running here: this check is for a machine with systemd"
command -v apt-get >/dev/null || die "apt is needed"
mkdir -p $W

# --- after the reboot -------------------------------------------------------
if [ "${1:-}" = after-reboot ]; then
	[ -f $W/after ] || die "run it without arguments first"
	. $W/after
	echo "== after the reboot"
	for i in $(seq 1 60); do systemctl is-active -q diskflux snapraidd && break; sleep 1; done
	check "DiskFlux started at boot" systemctl is-active -q diskflux
	check "SnapRAID Daemon started at boot" systemctl is-active -q snapraidd
	check "DiskFlux listens on $DF_PORT" listens "$DF_PORT"
	check "SnapRAID Daemon listens on 7627" listens 7627
	check "each answers with its own name" bash -c 'test "$(server '"$DF_PORT"')" = diskflux && test "$(server 7627)" = snapraidd'
	check "the arrays of DiskFlux are the same" test "$(arrays /etc/diskflux.d)" = "$DF_ARRAYS"
	check "nothing failed at boot in either" bash -c '! systemctl is-failed -q diskflux snapraidd'
	end
fi

# --- before -----------------------------------------------------------------
OLD=$(dpkg-query -W -f='${Version}' snapraid-daemon-storage 2>/dev/null | sed 's/-[0-9]*$//')
installed snapraid-daemon-storage || die "snapraid-daemon-storage is not installed: this check moves a machine on it"
installed snapraid-daemon && die "the snapraid-daemon package is installed already: this check installs it after the move"
[ -f /etc/snapraidd.conf ] || die "/etc/snapraidd.conf is missing"

echo "== this machine before"
say "snapraid-daemon-storage $OLD, $(systemctl is-active snapraidd) and $(systemctl is-enabled snapraidd 2>/dev/null)"
OLD_ARRAYS=$(arrays /etc/snapraidd.d)
say "arrays besides the default one: ${OLD_ARRAYS:-none}"
OLD_PORT=$(sed -n 's/^[[:space:]]*net_port[[:space:]]*=[[:space:]]*//p' /etc/snapraidd.conf | tail -1)
say "net_port: ${OLD_PORT:-not set (7627)}"
# the port the web UI moves to: 7627 (or unset) gives 7700, a port chosen by hand stays
case "${OLD_PORT:-7627}" in
	*7627*|"") DF_PORT=7700 ;;
	*) DF_PORT=$(echo "$OLD_PORT" | sed 's/.*://; s/[^0-9].*//') ;;
esac
grep -v '^[[:space:]]*\(#\|$\)' /etc/snapraidd.conf | grep -v '^net_port\|^net_auth_credential' | sort > $W/settings.before
for f in runs.log space.log events.log; do { wc -l < /etc/snapraidd-$f; } 2>/dev/null || echo 0; done > $W/history.before
SMB_INCLUDE=0; grep -q '^include = /etc/samba/snapraidd-shares.conf$' /etc/samba/smb.conf 2>/dev/null && SMB_INCLUDE=1
grep '^net_auth_credential' /etc/snapraidd.conf | sha256sum > $W/cred.before
[ -f /etc/samba/snapraidd-shares.conf ] && cp /etc/samba/snapraidd-shares.conf $W/shares.before

echo "== DiskFlux $VER built from the branch $BRANCH"
apt-get update -q >/dev/null 2>&1
apt-get install -y -q --no-install-recommends git ca-certificates build-essential autoconf automake zip zlib1g-dev libzstd-dev curl > $W/tools.log 2>&1 || die "the build tools could not be installed (see $W/tools.log)"
rm -rf $W/src
git clone -q --depth 1 -b "$BRANCH" https://github.com/paleka/diskflux.git $W/src || die "git clone failed"
( cd $W/src && echo "$VER" > .version && autoreconf -fi && ./configure && make dist && bash makedeb.sh && bash maketransition.sh ) > $W/build.log 2>&1 || die "the build failed (see $W/build.log)"
DEB=$W/src/diskflux_${VER}-1_amd64.deb
TRANS=$W/src/snapraid-daemon-storage_${VER}-1_amd64.deb
[ -f "$DEB" ] && [ -f "$TRANS" ] || die "the packages were not built (see $W/build.log)"
say "built: $(basename $DEB), $(basename $TRANS) (commit $(git -C $W/src rev-parse --short HEAD))"
curl -fsSL -o $W/snapraid-daemon.deb "$HIS_URL" || die "SnapRAID Daemon could not be downloaded"
echo "$HIS_SUM  $W/snapraid-daemon.deb" | sha256sum -c --quiet - || die "SnapRAID Daemon: wrong checksum"

echo "== the update of snapraid-daemon-storage $OLD, given the release $VER"
if [ -x /usr/sbin/snapraidd-upgrade ]; then
	SNAPRAIDD_DEB=$TRANS /usr/sbin/snapraidd-upgrade --background > $W/update.log 2>&1; RC=$?
	say "the update command of $OLD, as the web UI's Update runs it (exit $RC)"
else
	# older than 2.2.s11: no update command, the installer moves it
	DISKFLUX_DEB=$DEB sh $W/src/installer.sh > $W/update.log 2>&1; RC=$?
	say "no update command in $OLD: the installer (exit $RC)"
fi
for i in $(seq 1 240); do
	installed diskflux && ! installed snapraid-daemon-storage && systemctl is-active -q diskflux \
		&& grep -q '^state=\(done\|failed\)' /etc/diskflux-upgrade.status 2>/dev/null && break
	sleep 1
done
sleep 3
check "the update completes" test "$RC" = 0
check "DiskFlux $VER installed" bash -c "dpkg-query -W -f='\${Version}' diskflux | grep -qx '$VER-1'"
check "snapraid-daemon-storage is gone" bash -c '! installed snapraid-daemon-storage'
check "diskflux.service active and enabled" bash -c 'systemctl is-active -q diskflux && systemctl is-enabled -q diskflux'
check "the old service stopped, its boot link gone" bash -c '! systemctl is-active -q snapraidd && test ! -e /etc/systemd/system/multi-user.target.wants/snapraidd.service'
check "the web UI on $DF_PORT" listens "$DF_PORT"
check "it answers as diskflux" test "$(server $DF_PORT)" = diskflux
[ "$DF_PORT" = 7700 ] && check "nothing left on 7627" bash -c '! listens 7627'
check "the settings moved, the same" bash -c "test -f /etc/diskflux.conf && diff <(grep -v '^[[:space:]]*\(#\|\$\)' /etc/diskflux.conf | grep -v '^net_port\|^net_auth_credential' | sed 's|/etc/diskflux-alerts.sh|/etc/snapraidd-alerts.sh|g' | sort) $W/settings.before"
check "the login kept" bash -c "test \"\$(grep '^net_auth_credential' /etc/diskflux.conf | sha256sum)\" = \"$(cat $W/cred.before)\""
check "the arrays moved: ${OLD_ARRAYS:-none}" test "$(arrays /etc/diskflux.d)" = "$OLD_ARRAYS"
check "the history moved" bash -c "paste -d' ' $W/history.before <(for f in runs.log space.log events.log; do { wc -l < /etc/diskflux-\$f; } 2>/dev/null || echo 0; done) | awk '\$2 < \$1 { exit 1 }'"
if [ $SMB_INCLUDE = 1 ]; then
	check "Samba includes the shares of DiskFlux, once" bash -c "test \$(grep -c '^include = /etc/samba/diskflux-shares.conf\$' /etc/samba/smb.conf) = 1 && ! grep -q snapraidd-shares /etc/samba/smb.conf"
	check "the shares the same" cmp /etc/samba/diskflux-shares.conf $W/shares.before
fi
check "the record of the update: $OLD to $VER, done" bash -c "grep -qx 'from=$OLD' /etc/diskflux-upgrade.status && grep -qx 'to=$VER' /etc/diskflux-upgrade.status && grep -qx 'state=done' /etc/diskflux-upgrade.status"
check "no old name in the paths of DiskFlux" bash -c '! dpkg -L diskflux | grep -q "snapraidd\|snapraid-daemon"'

echo "== SnapRAID Daemon 2.2 of its author installed next to it"
D=$(mainpid diskflux)
apt-get install -y -q --no-install-recommends $W/snapraid-daemon.deb > $W/his.log 2>&1; RC=$?
for i in $(seq 1 30); do systemctl is-active -q snapraidd && break; sleep 1; done
check "his package installs" test "$RC" = 0
check "apt removes nothing" bash -c "! grep -q '^Removing' $W/his.log"
check "his daemon runs on 7627" bash -c 'systemctl is-active -q snapraidd && listens 7627 && test "$(server 7627)" = snapraidd'
check "DiskFlux untouched (same process, same port)" bash -c "test \"\$(mainpid diskflux)\" = '$D' && listens $DF_PORT"
check "no file in both packages" bash -c 'files() { dpkg -L "$1" | while read -r f; do [ -f "$f" ] && echo "$f"; done | sort; }; test -z "$(comm -12 <(files diskflux) <(files snapraid-daemon))"'
systemctl restart snapraidd; sleep 2
check "a restart of his leaves DiskFlux running" bash -c "test \"\$(mainpid diskflux)\" = '$D'"

printf 'DF_PORT=%s\nDF_ARRAYS="%s"\n' "$DF_PORT" "$(arrays /etc/diskflux.d)" > $W/after
echo
echo "Next: reboot, then run: bash $0 after-reboot"
echo "DiskFlux: http://<this machine>:$DF_PORT   SnapRAID Daemon: http://<this machine>:7627"
end
