#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# DiskFlux next to SnapRAID Daemon on a real Debian machine with systemd (a
# throwaway LXC or VM): his package 2.2 first, with an instance, both under
# systemd; then DiskFlux built from a branch, installed with the one command.
#
#     bash systemd-check.sh before          everything up to the reboot
#     reboot
#     bash systemd-check.sh after-reboot    the services after the reboot, remove, purge
#
# It changes the machine: run it on a throwaway one. Results also in /root/dfcheck/.
# Environment: BRANCH (coexist).

set -u
BRANCH=${BRANCH:-coexist}
W=/root/dfcheck
ENGINE_URL=https://github.com/amadvance/snapraid/releases/download/v15.2/snapraid_15.2-1_amd64.deb
ENGINE_SUM=9c78f158347cc0340ed5c9877724bb4f3b5e5fb48b43332ee7e0e7b6a63642d9
HIS_URL=https://github.com/amadvance/snapraid-daemon/releases/download/v2.2/snapraid-daemon_2.2-1_amd64.deb
HIS_SUM=bef62b3e986ea77d8c368606f55b2a7ac5762d7a5fdfd319629dc529fad56939
PASS=0; FAILS=0
mkdir -p $W
ok()   { PASS=$((PASS+1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL  $1"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
die() { echo "systemd-check: $*" >&2; exit 2; }
end() { echo; echo "passed: $PASS   failed: $FAILS"; exit $FAILS; }
listens() { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$(printf ':%04X' "$1")" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit !f }'; }
listens6() { awk -v p="$(printf ':%04X' "$1")" '$4 == "0A" && $2 == "00000000000000000000000001000000" p { f = 1 } END { exit !f }' /proc/net/tcp6; }
server() { curl -g -s -m5 -o /dev/null -D - "http://$1/snapraid/v1/state" | tr -d '\r' | sed -n 's/^Server: //Ip' | cut -d/ -f1; }
mainpid() { systemctl show -p MainPID --value "$1"; }
api() { curl -s -m 60 "$1"; }
post() { curl -s -m 60 -X POST -H 'Content-Type: application/json' --data-binary "$2" "$1"; }
idle() { sleep 1; for _ in $(seq 1 300); do [ "$(api "$1/tasks" | jq '(.active | length) + (.pending | length)' 2>/dev/null)" = 0 ] && return 0; sleep 1; done; return 1; }
in_use() { api "$1/tasks?limit_history=50" | jq -r '.history[0:5][].messages[]?.text' 2>/dev/null | grep -q 'already in use'; }
last_task() { api "$1/tasks?limit_history=200" | jq -r --arg c "$2" '[.history[] | select(.command == $c)][0] | "\(.status) \(.exit_code)"'; }
his_sums() { { dpkg -V snapraid-daemon; sha256sum /etc/snapraidd.conf /etc/snapraidd-backup.conf /etc/snapraid.conf /etc/snapraid-backup.conf; stat -c '%n %a %U %Y' /etc/snapraidd.conf /etc/snapraidd-backup.conf; ls -l /etc/systemd/system/multi-user.target.wants/ | awk '/snapraidd/ {print $9, $11}'; } 2>&1; }
wait_active() { for _ in $(seq 1 60); do systemctl is-active -q "$@" && return 0; sleep 1; done; return 1; }
export -f listens listens6 server mainpid his_sums api

D=http://127.0.0.1:7700/snapraid/v1
H=http://127.0.0.1:7627/snapraid/v1
[ "$(id -u)" = 0 ] || die "run it as root"
[ -d /run/systemd/system ] || die "systemd is not running here"
IP=$(hostname -I | awk '{print $1}')
# IPv6 is checked where the machine has it (::1)
V6=0; grep -q '^00000000000000000000000000000001 ' /proc/net/if_inet6 2>/dev/null && V6=1
v6check() { if [ $V6 = 1 ]; then check "$@"; else echo "skip  $1 (no IPv6 here)"; fi; }

if [ "${1:-}" = before ]; then
	echo "== tools, SnapRAID 15.2, SnapRAID Daemon 2.2, DiskFlux built from $BRANCH"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q >/dev/null 2>&1
	apt-get install -y -q --no-install-recommends git ca-certificates curl jq psmisc build-essential autoconf automake zip zlib1g-dev libzstd-dev > $W/tools.log 2>&1 || die "tools (see $W/tools.log)"
	curl -fsSL -o $W/snapraid.deb "$ENGINE_URL" && echo "$ENGINE_SUM  $W/snapraid.deb" | sha256sum -c --quiet - || die "engine download"
	curl -fsSL -o $W/his.deb "$HIS_URL" && echo "$HIS_SUM  $W/his.deb" | sha256sum -c --quiet - || die "his download"
	for v in 26.12.0 26.12.1; do
		rm -rf $W/src-$v
		git clone -q --depth 1 -b "$BRANCH" https://github.com/paleka/diskflux.git $W/src-$v || die "clone"
		( cd $W/src-$v && echo $v > .version && autoreconf -fi && ./configure && make dist && bash makedeb.sh ) > $W/build-$v.log 2>&1 || die "build $v (see $W/build-$v.log)"
	done
	DEB0=$W/src-26.12.0/diskflux_26.12.0-1_amd64.deb; DEB1=$W/src-26.12.1/diskflux_26.12.1-1_amd64.deb
	echo "built from commit $(git -C $W/src-26.12.0 rev-parse --short HEAD)"
	apt-get install -y -q --no-install-recommends $W/snapraid.deb $W/his.deb > $W/his-install.log 2>&1 || die "his install"

	echo "== his machine: the default daemon and the instance backup, as his manual says"
	for a in a b; do mkdir -p /srv/$a/d1 /srv/$a/d2 /srv/$a/parity; for i in $(seq 1 20); do head -c 40000 /dev/urandom > /srv/$a/d1/f$i; head -c 30000 /dev/urandom > /srv/$a/d2/g$i; done; done
	printf 'parity /srv/a/parity/snapraid.parity\ncontent /srv/a/d1/snapraid.content\ncontent /srv/a/d2/snapraid.content\ndata d1 /srv/a/d1\ndata d2 /srv/a/d2\n' > /etc/snapraid.conf
	printf 'parity /srv/b/parity/snapraid.parity\ncontent /srv/b/d1/snapraid.content\ncontent /srv/b/d2/snapraid.content\ndata d1 /srv/b/d1\ndata d2 /srv/b/d2\n' > /etc/snapraid-backup.conf
	snapraid -c /etc/snapraid.conf sync >/dev/null 2>&1; snapraid -c /etc/snapraid-backup.conf sync >/dev/null 2>&1
	# his daemon on the network for the browser checks, protected by an address list, on IPv4 and IPv6
	if [ $V6 = 1 ]; then PORTS='0.0.0.0:7627,[::1]:7627'; else PORTS=0.0.0.0:7627; fi
	cat >> /etc/snapraidd.conf <<-C
	net_port = $PORTS
	net_acl = +127.0.0.1,+::1,+192.168.0.0/16,+10.0.0.0/8,+172.16.0.0/12
	C
	sed -i 's/^#\?maintenance_schedule = .*/maintenance_schedule = 03:00/' /etc/snapraidd.conf
	grep -q '^maintenance_schedule = 03:00' /etc/snapraidd.conf || echo 'maintenance_schedule = 03:00' >> /etc/snapraidd.conf
	printf 'net_enabled = 1\nnet_port = 127.0.0.1:7628\nsys_log_directory = /var/log/snapraid/backup\n' > /etc/snapraidd-backup.conf
	mkdir -p /var/log/snapraid/backup
	systemctl restart snapraidd; systemctl enable --now snapraidd@backup >/dev/null 2>&1; sleep 3
	check "his daemon and his instance active and enabled" bash -c 'systemctl is-active -q snapraidd snapraidd@backup && systemctl is-enabled -q snapraidd snapraidd@backup'
	check "7627 and 7628 answer as snapraidd" bash -c 'test "$(server 127.0.0.1:7627)" = snapraidd && test "$(server 127.0.0.1:7628)" = snapraidd'
	v6check "his daemon on IPv6 [::1]:7627" bash -c 'listens6 7627 && test "$(server [::1]:7627)" = snapraidd'
	his_sums > $W/his.before; H1=$(mainpid snapraidd); H2=$(mainpid snapraidd@backup)

	echo "== DiskFlux installed with the one command"
	DISKFLUX_DEB=$DEB0 sh $W/src-26.12.0/installer.sh > $W/installer.log 2>&1; RC=$?
	check "installer completes" test $RC = 0
	check "diskflux.service active and enabled" bash -c 'systemctl is-active -q diskflux && systemctl is-enabled -q diskflux'
	check "his two not restarted (same processes)" bash -c "test \$(mainpid snapraidd) = $H1 && test \$(mainpid snapraidd@backup) = $H2"
	check "his package, settings and boot links unchanged" bash -c "his_sums | diff -q $W/his.before -"
	check "DiskFlux on 0.0.0.0:7700, reachable at $IP" bash -c "test \"\$(server $IP:7700)\" = diskflux"
	v6check "DiskFlux on IPv6 [::1]:7700" bash -c 'listens6 7700 && test "$(server [::1]:7700)" = diskflux'
	check "nothing of DiskFlux on 7627" bash -c "test \"\$(server $IP:7627)\" = snapraidd"
	check "his address list imported" grep -q '^net_acl = +127.0.0.1,+::1,+192.168.0.0/16' /etc/diskflux.conf
	check "his schedule imported as it is" grep -q '^maintenance_schedule = 03:00' /etc/diskflux.conf
	check "his instance imported as the array backup" test -f /etc/diskflux.d/backup.conf
	check "both addresses printed" bash -c "grep -q 'SnapRAID Daemon:.*7627' $W/installer.log && grep -q 'DiskFlux:.*7700' $W/installer.log"
	check "the notice of the jobs both do" grep -q 'maintenance' $W/installer.log
	check "/host sees his daemon running, with his instance" bash -c "curl -s -m5 $D/host | jq -e '.snapraid_daemon.running == true and (.snapraid_daemon.instances | index(\"backup\"))'"
	check "the journal read by DiskFlux is its own" bash -c '! journalctl -u diskflux -b --no-pager -o cat | grep -q "^snapraidd"'
	check "no unit of DiskFlux names his" bash -c '! grep -rl snapraidd /usr/lib/systemd/system/diskflux*'

	echo "== each service acted on: the other keeps running and enabled"
	DP=$(mainpid diskflux)
	systemctl restart diskflux; wait_active diskflux
	check "restart of DiskFlux: his two untouched" bash -c "test \$(mainpid snapraidd) = $H1 && test \$(mainpid snapraidd@backup) = $H2"
	systemctl disable --now diskflux >/dev/null 2>&1
	check "stop and disable of DiskFlux: his two active, enabled, answering" bash -c 'systemctl is-active -q snapraidd snapraidd@backup && systemctl is-enabled -q snapraidd snapraidd@backup && test "$(server 127.0.0.1:7627)" = snapraidd'
	systemctl enable --now diskflux >/dev/null 2>&1; wait_active diskflux; sleep 2
	DP=$(mainpid diskflux)
	systemctl restart snapraidd; systemctl stop snapraidd@backup; sleep 2
	check "restart and stop of his: DiskFlux untouched" bash -c "test \$(mainpid diskflux) = $DP && test \"\$(server 127.0.0.1:7700)\" = diskflux"
	systemctl start snapraidd@backup; sleep 2; H1=$(mainpid snapraidd); H2=$(mainpid snapraidd@backup)

	echo "== a sync of each while the other's runs, on the same array"
	idle $D; idle $H
	head -c 300M /dev/urandom > /srv/a/d1/big1.bin; head -c 300M /dev/urandom > /srv/a/d2/big2.bin
	post "$H/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
	for _ in $(seq 1 50); do fuser /srv/a/d1/snapraid.content.lock >/dev/null 2>&1 && break; sleep 0.2; done
	post "$D/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
	idle $D; idle $H
	check "a sync of DiskFlux while his runs: refused by SnapRAID's lock" in_use $D
	check "his sync completes" test "$(last_task $H sync)" = "terminated 0"
	head -c 300M /dev/urandom > /srv/a/d1/big3.bin
	post "$D/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
	for _ in $(seq 1 50); do fuser /srv/a/d1/snapraid.content.lock >/dev/null 2>&1 && break; sleep 0.2; done
	post "$H/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
	idle $D; idle $H
	check "the other way: refused by the lock too" in_use $H
	check "DiskFlux's sync completes" test "$(last_task $D sync)" = "terminated 0"
	check "SnapRAID finds no error" bash -c 'snapraid -c /etc/snapraid.conf status 2>&1 | grep -q "No error detected"'
	check "the logs of both in his directory, DiskFlux's named -diskflux" bash -c 'ls /var/log/snapraid/ | grep -q -- "-sync-diskflux.log" && ls /var/log/snapraid/ | grep -v diskflux | grep -q -- "-sync.log"'

	echo "== an update as the web UI starts it: a transient unit out of the service"
	systemd-run --unit=diskflux-upgrade-check --collect --quiet --description="Update of DiskFlux" --setenv=DISKFLUX_DEB=$DEB1 -- /usr/sbin/diskflux-upgrade --background --dir /etc
	for _ in $(seq 1 120); do grep -q '^state=\(done\|failed\)' /etc/diskflux-upgrade.status 2>/dev/null && ! systemctl is-active -q diskflux-upgrade-check && break; sleep 1; done
	check "the update ends done, 26.12.1 running" bash -c 'grep -qx state=done /etc/diskflux-upgrade.status && dpkg-query -W -f="\${Version}" diskflux | grep -qx 26.12.1-1 && systemctl is-active -q diskflux'
	check "the unit lived through the restart by the package" grep -q 'Upgraded from 26.12.0 to 26.12.1' /etc/diskflux-upgrade.log
	check "his two not restarted by the update" bash -c "test \$(mainpid snapraidd) = $H1 && test \$(mainpid snapraidd@backup) = $H2"
	systemd-run --unit=diskflux-upgrade-check2 --collect --quiet --setenv=DISKFLUX_DEB=$DEB0 -- /usr/sbin/diskflux-upgrade --background --dir /etc
	for _ in $(seq 1 120); do grep -q '^to=26.12.0' /etc/diskflux-upgrade.status && grep -q '^state=\(done\|failed\)' /etc/diskflux-upgrade.status && ! systemctl is-active -q diskflux-upgrade-check2 && break; sleep 1; done
	check "back to 26.12.0 the same way" bash -c 'grep -qx state=done /etc/diskflux-upgrade.status && dpkg-query -W -f="\${Version}" diskflux | grep -qx 26.12.0-1 && systemctl is-active -q diskflux'
	his_sums > $W/his.before2
	echo
	echo "Web UI: DiskFlux http://$IP:7700   SnapRAID Daemon http://$IP:7627"
	echo "Next: reboot, then: bash $0 after-reboot"
	end
fi

if [ "${1:-}" = after-reboot ]; then
	[ -f $W/his.before2 ] || die "run it with 'before' first"
	echo "== after the reboot"
	wait_active snapraidd snapraidd@backup diskflux
	check "his daemon, his instance and DiskFlux started at boot" systemctl is-active -q snapraidd snapraidd@backup diskflux
	check "each on its port" bash -c 'test "$(server 127.0.0.1:7627)" = snapraidd && test "$(server 127.0.0.1:7628)" = snapraidd && test "$(server 127.0.0.1:7700)" = diskflux'
	v6check "each on IPv6 too" bash -c 'test "$(server [::1]:7700)" = diskflux && test "$(server [::1]:7627)" = snapraidd'
	check "his files as before the reboot" bash -c "his_sums | diff -q $W/his.before2 -"
	H1=$(mainpid snapraidd); H2=$(mainpid snapraidd@backup)
	echo "== DiskFlux removed, then purged"
	apt-get remove -y -q diskflux > $W/rm.log 2>&1
	check "remove: his two running, same processes" bash -c "test \$(mainpid snapraidd) = $H1 && test \$(mainpid snapraidd@backup) = $H2"
	check "remove: DiskFlux stopped, nothing on 7700" bash -c '! systemctl is-active -q diskflux && ! listens 7700'
	apt-get purge -y -q diskflux > $W/purge.log 2>&1
	check "purge: his two running and enabled, his files unchanged" bash -c "systemctl is-active -q snapraidd snapraidd@backup && systemctl is-enabled -q snapraidd snapraidd@backup && his_sums | diff -q $W/his.before2 -"
	check "purge: the logs and SnapRAID confs stay" bash -c 'ls /var/log/snapraid/*-diskflux.log >/dev/null && test -f /etc/snapraid.conf && test -f /etc/snapraid-backup.conf'
	echo "== installed again, then his package purged"
	apt-get install -y -q --no-install-recommends $W/src-26.12.0/diskflux_26.12.0-1_amd64.deb > $W/again.log 2>&1
	wait_active diskflux; sleep 2
	check "installed again: imports again, runs next to his" bash -c 'grep -q "^# Settings imported from /etc/snapraidd.conf" /etc/diskflux.conf && systemctl is-active -q diskflux snapraidd && test "$(server 127.0.0.1:7700)" = diskflux'
	DP=$(mainpid diskflux)
	systemctl disable --now snapraidd@backup >/dev/null 2>&1
	apt-get purge -y -q snapraid-daemon > $W/hispurge.log 2>&1
	check "his package purged: DiskFlux untouched, its settings and arrays kept" bash -c "test \$(mainpid diskflux) = $DP && test -f /etc/diskflux.conf && test -f /etc/diskflux.d/backup.conf && test \"\$(server 127.0.0.1:7700)\" = diskflux"
	end
fi

die "usage: $0 before | after-reboot"
