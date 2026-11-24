#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# The .rpm of DiskFlux on a real rpm machine with systemd (a throwaway Rocky,
# Alma or Fedora LXC or VM): next to the .rpm of SnapRAID Daemon 2.2, removed,
# and the move of a machine on the earlier snapraid-daemon-storage .rpm.
#
#     bash rpm-check.sh
#
# It changes the machine: run it on a throwaway one. Environment: BRANCH (coexist).

set -u
export HOME=${HOME:-/root}
BRANCH=${BRANCH:-coexist}
W=/root/dfcheck
ENGINE_URL=https://github.com/amadvance/snapraid/releases/download/v15.2/snapraid-15.2-1.x86_64.rpm
ENGINE_SUM=f1c37fa43beea8445858520a5cd514198d8c0c0ac5a5ab588adcd02e872ee681
HIS_URL=https://github.com/amadvance/snapraid-daemon/releases/download/v2.2/snapraid-daemon-2.2-1.x86_64.rpm
HIS_SUM=9c43591cecf2be5276d944acfdf414fc5860d470f53dc44432752794f9aa1e2e
S14_URL=https://github.com/paleka/diskflux/releases/download/v2.2.s14/snapraid-daemon-storage-2.2.s14-1.x86_64.rpm
PASS=0; FAILS=0
mkdir -p $W
ok()   { PASS=$((PASS+1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL  $1"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
die() { echo "rpm-check: $*" >&2; exit 2; }
end() { echo; echo "passed: $PASS   failed: $FAILS"; exit $FAILS; }
listens() { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$(printf ':%04X' "$1")" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit !f }'; }
server() { curl -g -s -m5 -o /dev/null -D - "http://$1/snapraid/v1/state" | tr -d '\r' | sed -n 's/^Server: //Ip' | cut -d/ -f1; }
mainpid() { systemctl show -p MainPID --value "$1"; }
wait_active() { for _ in $(seq 1 60); do systemctl is-active -q "$@" && return 0; sleep 1; done; return 1; }
his_sums() { { rpm -V snapraid-daemon; sha256sum /etc/snapraidd.conf /etc/snapraid.conf; stat -c '%n %a %U %Y' /etc/snapraidd.conf; } 2>&1; }
export -f listens server mainpid his_sums

[ "$(id -u)" = 0 ] || die "run it as root"
[ -d /run/systemd/system ] || die "systemd is not running here"
command -v dnf >/dev/null || die "dnf is needed"
. /etc/os-release; echo "== $PRETTY_NAME"

echo "== tools, SnapRAID 15.2 and SnapRAID Daemon 2.2 (.rpm), DiskFlux .rpm built from $BRANCH"
dnf -y -q install git curl jq gcc make autoconf automake zip zlib-devel libzstd-devel rpm-build tar gzip procps-ng findutils diffutils > $W/tools.log 2>&1 || die "tools (see $W/tools.log)"
curl -fsSL -o $W/snapraid.rpm "$ENGINE_URL" && echo "$ENGINE_SUM  $W/snapraid.rpm" | sha256sum -c --quiet - || die "engine download"
curl -fsSL -o $W/his.rpm "$HIS_URL" && echo "$HIS_SUM  $W/his.rpm" | sha256sum -c --quiet - || die "his download"
curl -fsSL -o $W/s14.rpm "$S14_URL" || die "s14 download (removed from the releases by D6?)"
rm -rf $W/src ~/rpmbuild
git clone -q --depth 1 -b "$BRANCH" https://github.com/paleka/diskflux.git $W/src || die "clone"
( cd $W/src && echo 26.12.0 > .version && autoreconf -fi && ./configure && make dist && bash makerpm.sh ) > $W/build.log 2>&1 || die "build (see $W/build.log)"
RPM=$(ls ~/rpmbuild/RPMS/x86_64/diskflux-26.12.0-1*.x86_64.rpm 2>/dev/null | head -1)
[ -n "$RPM" ] || die "no rpm built (see $W/build.log)"
echo "built $(basename $RPM) from commit $(git -C $W/src rev-parse --short HEAD)"
check "the rpm has no relation toward snapraid-daemon" bash -c "! rpm -qp --conflicts --obsoletes --provides $RPM | grep -qx 'snapraid-daemon\( .*\)\?'"
check "it obsoletes only snapraid-daemon-storage" bash -c "rpm -qp --obsoletes $RPM | grep -q '^snapraid-daemon-storage'"

echo "== his machine: SnapRAID Daemon 2.2 from its .rpm"
dnf -y -q install $W/snapraid.rpm $W/his.rpm > $W/his-install.log 2>&1 || die "his install (see $W/his-install.log)"
mkdir -p /srv/a/d1 /srv/a/d2 /srv/a/parity
for i in $(seq 1 20); do head -c 40000 /dev/urandom > /srv/a/d1/f$i; head -c 30000 /dev/urandom > /srv/a/d2/g$i; done
printf 'parity /srv/a/parity/snapraid.parity\ncontent /srv/a/d1/snapraid.content\ncontent /srv/a/d2/snapraid.content\ndata d1 /srv/a/d1\ndata d2 /srv/a/d2\n' > /etc/snapraid.conf
snapraid -c /etc/snapraid.conf sync >/dev/null 2>&1
echo 'maintenance_schedule = 03:00' >> /etc/snapraidd.conf
systemctl enable --now snapraidd >/dev/null 2>&1; wait_active snapraidd; sleep 2
check "his daemon active on 7627" bash -c 'systemctl is-active -q snapraidd && test "$(server 127.0.0.1:7627)" = snapraidd'
his_sums > $W/his.before; H1=$(mainpid snapraidd)

echo "== DiskFlux installed with dnf next to it"
dnf -y install $RPM > $W/df-install.log 2>&1; RC=$?
wait_active diskflux; sleep 2
check "dnf installs DiskFlux" test $RC = 0
check "dnf removes nothing" bash -c "rpm -q snapraid-daemon && ! grep -qi '^Removing\|Obsoleting\|Erasing' $W/df-install.log"
check "diskflux.service active and enabled on 7700" bash -c 'systemctl is-active -q diskflux && systemctl is-enabled -q diskflux && test "$(server 127.0.0.1:7700)" = diskflux'
check "his daemon not restarted, still on 7627" bash -c "test \$(mainpid snapraidd) = $H1 && test \"\$(server 127.0.0.1:7627)\" = snapraidd"
check "his package and settings unchanged" bash -c "his_sums | diff -q $W/his.before -"
check "his settings imported by %post" bash -c "grep -q '^# Settings imported from /etc/snapraidd.conf' /etc/diskflux.conf && grep -q '^maintenance_schedule = 03:00' /etc/diskflux.conf"
check "no file in both packages" bash -c 'test -z "$(comm -12 <(rpm -ql diskflux | while read -r f; do [ -f "$f" ] && echo "$f"; done | sort) <(rpm -ql snapraid-daemon | while read -r f; do [ -f "$f" ] && echo "$f"; done | sort))"'
check "no old name in the paths of DiskFlux" bash -c '! rpm -ql diskflux | grep -q "snapraidd\|snapraid-daemon"'

echo "== DiskFlux removed with dnf"
dnf -y -q remove diskflux > $W/df-remove.log 2>&1
check "removed: his daemon running, same process, unchanged" bash -c "test \$(mainpid snapraidd) = $H1 && systemctl is-enabled -q snapraidd && his_sums | diff -q $W/his.before -"
check "removed: DiskFlux stopped, nothing on 7700" bash -c '! systemctl is-active -q diskflux && ! listens 7700'

echo "== a machine on the earlier snapraid-daemon-storage 2.2.s14 .rpm, moved by dnf"
systemctl disable --now snapraidd >/dev/null 2>&1
dnf -y -q remove snapraid-daemon > /dev/null 2>&1
rm -f /etc/snapraidd.conf /etc/snapraidd.conf.rpmsave /etc/diskflux.conf /etc/diskflux.conf.rpmsave
dnf -y -q install $W/s14.rpm > $W/s14.log 2>&1 || die "s14 install (see $W/s14.log)"
echo 'maintenance_schedule = 04:00' >> /etc/snapraidd.conf
snapraidd -g robert:pw 2>/dev/null | grep -m1 '^net_auth_credential' >> /etc/snapraidd.conf
cp /etc/snapraidd.conf $W/s14.conf
mkdir -p /etc/snapraidd.d; printf 'engine_conf = /etc/snapraid.conf\n' > /etc/snapraidd.d/media.conf
printf 'shares = media\n' > /etc/snapraidd-host.conf
systemctl enable --now snapraidd >/dev/null 2>&1; wait_active snapraidd; sleep 2
check "s14 runs on 7627" test "$(server 127.0.0.1:7627)" = snapraidd
dnf -y install $RPM > $W/move.log 2>&1; RC=$?
wait_active diskflux; sleep 3
check "dnf installs DiskFlux over s14" test $RC = 0
check "snapraid-daemon-storage obsoleted (gone)" bash -c '! rpm -q snapraid-daemon-storage'
check "DiskFlux active and enabled on 7700, the old service gone" bash -c 'systemctl is-active -q diskflux && systemctl is-enabled -q diskflux && test "$(server 127.0.0.1:7700)" = diskflux && ! systemctl is-active -q snapraidd'
check "the settings moved" bash -c "head -1 /etc/diskflux.conf | grep -q '^# Moved from' && grep -q '^maintenance_schedule = 04:00' /etc/diskflux.conf"
check "the arrays and machine settings moved" bash -c "test -f /etc/diskflux.d/media.conf && grep -qx 'shares = media' /etc/diskflux-host.conf && test ! -e /etc/snapraidd.d"
check "nothing of the move left in /run" bash -c "test ! -e /run/diskflux-move.list"
check "the login moved too" bash -c "grep -q '^net_auth_credential' $W/s14.conf && test \"\$(grep '^net_auth_credential' /etc/diskflux.conf)\" = \"\$(grep '^net_auth_credential' $W/s14.conf)\""
check "the default file of the package kept as diskflux.conf.rpmnew, nothing waiting" bash -c "test -f /etc/diskflux.conf.rpmnew && test ! -e /etc/diskflux.conf.moved"
dnf -y -q install $W/his.rpm > $W/his-again.log 2>&1
wait_active snapraidd; sleep 2
check "then his .rpm installs next to it, both running" bash -c 'rpm -q diskflux snapraid-daemon && systemctl is-active -q diskflux snapraidd && test "$(server 127.0.0.1:7627)" = snapraidd && test "$(server 127.0.0.1:7700)" = diskflux'
end
