#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# End to end test of DiskFlux next to SnapRAID Daemon, the official daemon of Andrea Mazzoleni,
# on the same machine and the same arrays. Every check is named after what he asked (A1 to A7)
# and the clashes found in his source (C1 to C9), as listed in the coexistence note of the
# project; the suite fails if one of them has no check.
#
#   A1  coexist on the same machine, without disrupting or uninstalling SnapRAID Daemon
#   A2  'diskflux' for executables, services, configuration files and other resources
#   A3  a different default port
#   A4  a package that doesn't conflict with or replace snapraid-daemon
#   A5  compatible settings imported from snapraidd.conf at installation, the original unchanged
#   A6  the same SnapRAID log directory for the same array
#   A7  conflicts of scheduled or manual operations left to the user
#   C1  files of both packages       C4  port            C7  imported settings that act twice
#   C2  package scripts on his unit  C5  one log, two runs   C8  his instances snapraidd@NAME
#   C3  his pid file and names       C6  each deletes and reads the other's logs   C9  his journal
#
# The machine: SnapRAID Daemon 2.2 from his package, running on one array, and one instance
# (snapraidd@backup, run by hand: no systemd here) on a second array, set up as his manual says
# (port 7628, logs in /var/log/snapraid/backup). DiskFlux is installed with the one command.
#
# DESTRUCTIVE: it installs and removes packages, and mounts disks of loop devices. It runs only
# in a container started for it:
#
#     docker compose -f docker-compose.coexist.yml up --build --abort-on-container-exit --exit-code-from tests
#     docker compose -f docker-compose.coexist.yml down -v
#
# The packages are in $LAB_PKG, put there by the Dockerfile when built with LAB_PACKAGES=1:
#   snapraid-new.deb     SnapRAID 15
#   snapraid-daemon.deb  SnapRAID Daemon 2.2, the package of its author
#   daemon.deb           DiskFlux, built from the checkout
#   installer.sh         its installer

[ "${LAB_COEXIST:-0}" = 1 ] || { echo "refusing to run: this container was not started by docker-compose.coexist.yml"; exit 99; }

PKG=${LAB_PKG:-/usr/local/share/lab/pkg}
for f in snapraid-new.deb snapraid-daemon.deb daemon.deb installer.sh; do
    [ -f "$PKG/$f" ] || { echo "refusing to run: $PKG/$f is missing, build the image with LAB_PACKAGES=1"; exit 99; }
done
# the image keeps no package lists, and the packages need systemd and the rest from the
# archive: the lists are read once (the container has the network, as the installer needs)
ls /var/lib/apt/lists/*_Packages >/dev/null 2>&1 || apt-get update -q >/dev/null 2>&1
# a container has the nodes of the loop devices it started with only: the disks of this test
# take the next free ones (the entrypoint of the lab does the same for its disks)
for n in $(seq 0 127); do [ -e /dev/loop$n ] || mknod /dev/loop$n b 7 $n 2>/dev/null; done

W=/var/lab-coexist
IMG=$W/img
U=http://127.0.0.1:7700/snapraid
HU=http://127.0.0.1:7627/snapraid
IU=http://127.0.0.1:7628/snapraid
# the endpoints of each array: of DiskFlux (its default array, the one of the instance), of
# his daemon, of his instance
D=$U/v1; B=$U/v1/arrays/backup; H=$HU/v1; I=$IU/v1
AUTH="bob:pw-of-bob"
LOG=/var/log/snapraid
ILOG=/var/log/snapraid/backup
# the program of the package: the image of the lab has a copy of its own in /usr/sbin
DAEMON=/usr/bin/diskflux
PASS=0; FAILS=0
export DEBIAN_FRONTEND=noninteractive
declare -A COVER

ok()   { PASS=$((PASS + 1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; }
section() { echo; echo "== $1"; }
# check "[A1,C2] what is checked" command...: the tags in front count for the coverage
check() {
    local name=$1 t; shift
    for t in $(printf '%s' "$name" | sed -n 's/^\[\([A-Z0-9,]*\)\].*/\1/p' | tr ',' ' '); do COVER[$t]=$(( ${COVER[$t]:-0} + 1 )); done
    if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name" "failed: $*"; return 1; fi
}
not()  { ! "$@"; }
api()  { curl -s -m 60 -u "$AUTH" "$1"; }
post() { curl -s -m 60 -u "$AUTH" -X "${3:-POST}" -H 'Content-Type: application/json' --data-binary "$2" "$1"; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }
listens() { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v p="$(printf ':%04X' "$1")" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit !f }'; }
idle() { # endpoints of an array
    sleep 1
    for _ in $(seq 1 300); do
        [ "$(api "$1/tasks" | jq '(.active | length) + (.pending | length)' 2>/dev/null)" = 0 ] && return 0
        sleep 1
    done
    return 1
}
healthy() { for _ in $(seq 1 90); do [ "$(api "$1/array" | jq -r '.health // empty' 2>/dev/null)" = passed ] && return 0; sleep 1; done; return 1; }
last_task() { api "$1/tasks?limit_history=200" | jq -r --arg c "$2" '[.history[] | select(.command == $c)][0] | "\(.status) \(.exit_code)"'; }

# A disk with a partition table, like a real one, answered for by the fake smartctl of the lab
disk() { # name sizeMB -> prints the partition
    local img=$IMG/$1.img loop base part
    truncate -s "${2}M" "$img"
    echo 'type=83' | sfdisk -q "$img"
    loop=$(losetup -fP --show "$img"); base=${loop##*/}; part=${loop}p1
    for _ in $(seq 1 20); do [ -e "/sys/block/$base/${base}p1/dev" ] && break; partx -a "$loop" 2>/dev/null; sleep 0.1; done
    # a node left from an earlier disk may hold an old number (loop partitions get a
    # new one each time): made again
    local dev; dev=$(cat "/sys/block/$base/${base}p1/dev")
    if [ -b "$part" ] && [ "$(stat -c '%t:%T' "$part")" != "$(printf '%x:%x' "${dev%%:*}" "${dev##*:}")" ]; then rm -f "$part"; fi
    [ -b "$part" ] || mknod "$part" b "${dev%%:*}" "${dev##*:}"
    mkfs.ext4 -q -L "$1" "$part"
    # what udev makes on a real machine: SnapRAID knows a disk by this, also a renamed one
    mkdir -p /dev/disk/by-uuid; ln -sf "$part" "/dev/disk/by-uuid/$(blkid -s UUID -o value "$part")"
    mkdir -p /run/lab/map "${LAB_DIR:-/lab}/smart"
    echo "$1" > "/run/lab/map/$base"; echo "KIND=ata" > "${LAB_DIR:-/lab}/smart/$1.env"
    echo "$part"
}

teardown() {
    pkill -x diskflux 2>/dev/null; pkill -x snapraidd 2>/dev/null; sleep 1
    for m in /mnt/a1 /mnt/a2 /mnt/a3 /mnt/pa /mnt/b1 /mnt/pb; do umount "$m" 2>/dev/null; done
    for f in "$IMG"/*.img; do
        [ -f "$f" ] && for l in $(losetup -j "$f" -O NAME -n); do
            for u in /dev/disk/by-uuid/*; do [ "$(readlink "$u")" = "${l}p1" ] && rm -f "$u"; done
            losetup -d "$l" 2>/dev/null
        done
    done
    for p in diskflux snapraid-daemon snapraid; do dpkg --purge --force-confold "$p" >/dev/null 2>&1; done
    rm -rf "$IMG" /etc/snapraid.conf* /etc/snapraid-backup.conf* /etc/diskflux* /etc/snapraidd* /var/snapraid $LOG \
        /mnt/a1 /mnt/a2 /mnt/a3 /mnt/pa /mnt/b1 /mnt/pb /run/snapraidd*.pid /run/diskflux.pid
    rm -f /etc/systemd/system/*.wants/snapraidd*.service
}

files() { # dir count size-kB
    local i; mkdir -p "$1/media"
    for i in $(seq 1 "$2"); do head -c $(( $3 * 1024 + RANDOM )) /dev/urandom > "$1/media/f$i.bin"; done
}

# His machine: two arrays, synced, his daemon and his instance running and enabled at boot
his_machine() {
    mkdir -p "$IMG" /var/snapraid
    local a1 a2 a3 pa b1 pb
    a1=$(disk a1 300); a2=$(disk a2 300); a3=$(disk a3 300); pa=$(disk pa 400); b1=$(disk b1 300); pb=$(disk pb 400)
    for m in a1 a2 a3 pa b1 pb; do mkdir -p /mnt/$m; done
    mount "$a1" /mnt/a1 && mount "$a2" /mnt/a2 && mount "$a3" /mnt/a3 && mount "$pa" /mnt/pa && mount "$b1" /mnt/b1 && mount "$pb" /mnt/pb || return 1
    files /mnt/a1 20 200; files /mnt/a2 20 200; files /mnt/a3 10 100; files /mnt/b1 20 200
    cat > /etc/snapraid.conf <<'EOF'
# the array of SnapRAID Daemon
parity /mnt/pa/snapraid.parity
content /var/snapraid/a.content
content /mnt/a1/.snapraid.content
data d1 /mnt/a1/
data d2 /mnt/a2/
EOF
    cat > /etc/snapraid-backup.conf <<'EOF'
# the array of the instance "backup", as his manual sets it up
parity /mnt/pb/snapraid.parity
content /var/snapraid/b.content
content /mnt/b1/.snapraid.content
data b1 /mnt/b1/
EOF
    snapraid -c /etc/snapraid.conf sync >/dev/null 2>&1 && snapraid -c /etc/snapraid-backup.conf sync >/dev/null 2>&1 || return 1
    apt-get install -y -q "$PKG/snapraid-daemon.deb" >/dev/null 2>&1 || return 1
    # his settings: a login, a schedule, alerts and a heartbeat (jobs DiskFlux would do too)
    CRED=$(snapraidd -g "$AUTH" | sed -n 's/^net_auth_credential = //p')
    sed -i -e 's/^maintenance_schedule = .*/maintenance_schedule = Mon 03:33/' -e 's/^spindown_idle_minutes = .*/spindown_idle_minutes = 0/' /etc/snapraidd.conf
    printf 'net_port = 127.0.0.1:7627\nnet_auth_credential = %s\nnotify_result = cat > /dev/null\nnotify_heartbeat = true\n# his own line\n' "$CRED" >> /etc/snapraidd.conf
    printf 'net_enabled = 1\nnet_port = 127.0.0.1:7628\nsys_log_directory = %s\nmaintenance_schedule =\nspindown_idle_minutes = 0\nnet_auth_credential = %s\n' "$ILOG" "$CRED" > /etc/snapraidd-backup.conf
    mkdir -p "$ILOG" /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/snapraidd.service /etc/systemd/system/multi-user.target.wants/snapraidd.service
    ln -sf /usr/lib/systemd/system/snapraidd@.service /etc/systemd/system/multi-user.target.wants/snapraidd@backup.service
    snapraidd || return 1
    snapraidd -c /etc/snapraidd-backup.conf -C /etc/snapraid-backup.conf -i backup || return 1
    healthy "$H" && healthy "$I" && idle "$H" && idle "$I"
}

# Everything of his, to compare before and after a step
#   pkg    his package and the engine: versions, every file
#   conf   his configurations and the SnapRAID ones
#   run    his processes, pid files, boot links, ports
#   logs   the logs his daemons wrote (not DiskFlux's)
his_snap() {
    local o=$W/snap/$1; rm -rf "$o"; mkdir -p "$o"
    { dpkg-query -W -f='${Package} ${Version} ${Status}\n' snapraid snapraid-daemon
      dpkg -L snapraid-daemon snapraid | while read -r f; do [ -f "$f" ] && sha256sum "$f"; done; } > "$o/pkg" 2>&1
    for f in /etc/snapraidd.conf /etc/snapraidd-backup.conf /etc/snapraid.conf /etc/snapraid-backup.conf; do
        sha256sum "$f"; stat -c '%n %s %Y %a %U' "$f"
    done > "$o/conf" 2>&1
    { pidof snapraidd | tr ' ' '\n' | sort; cat /run/snapraidd.pid /run/snapraidd-backup.pid
      ls -l /etc/systemd/system/multi-user.target.wants/ | grep snapraidd | awk '{ print $9, $10, $11 }'
      for p in 7627 7628; do listens $p && echo "listens $p"; done; } > "$o/run" 2>&1
    find $LOG -type f ! -name '*-diskflux.log*' -printf '%p %s %T@\n' 2>/dev/null | sort > "$o/logs"
}
same() { # snapA snapB parts...
    local a=$W/snap/$1 b=$W/snap/$2 p; shift 2
    for p in "$@"; do cmp -s "$a/$p" "$b/$p" || { diff "$a/$p" "$b/$p" | head -5; return 1; }; done
}
# his logs of before are all still there, unchanged (his daemons go on adding new ones)
logs_kept() { comm -23 "$W/snap/$1/logs" "$W/snap/$2/logs" | grep -q . && return 1 || return 0; }

mkdir -p "$W/snap"
teardown
apt-get install -y -q "$PKG/snapraid-new.deb" >/dev/null 2>&1

# ---------------------------------------------------------------------------
section "his machine: SnapRAID Daemon and its instance snapraidd@backup, each on its array"
# ---------------------------------------------------------------------------
his_machine; RC=$?
check "his machine is set up" test $RC = 0
check "his daemon answers on 7627, healthy" healthy "$H"
check "his instance answers on 7628, healthy" healthy "$I"
his_snap before
cp -p /etc/snapraidd.conf "$W/his.conf"

# ---------------------------------------------------------------------------
section "DiskFlux installed with the one command"
# ---------------------------------------------------------------------------
env DISKFLUX_DEB="$PKG/daemon.deb" SNAPRAID_DEB="$PKG/snapraid-new.deb" sh "$PKG/installer.sh" > "$W/install.log" 2>&1; RC=$?
sleep 1; [ -f /run/diskflux.pid ] || $DAEMON; healthy "$D"; idle "$D"; idle "$B"
his_snap installed
check "[A1] the installer completes" test $RC = 0
check "[A1] it says SnapRAID Daemon is kept as it is" grep -q "it is kept as it is" "$W/install.log"
check "[A1,A4] his package and the engine: same versions, every file the same" same before installed pkg
check "[A1,A5] his configurations and the SnapRAID ones are unchanged (content, size, time, mode)" same before installed conf
check "[A1,C3] his daemon and his instance still run: same processes, pid files, boot links, ports" same before installed run
check "[A1,A6] his logs are all there, unchanged" logs_kept before installed
check "[A4,C1] apt removed nothing" not grep -q "REMOVED\|Removing snapraid" "$W/install.log"
check "[A4,C1] the DiskFlux package declares nothing toward snapraid-daemon" sh -c "! dpkg-deb -f '$PKG/daemon.deb' Conflicts Replaces Provides Breaks | grep -qE '(^|[ ,:])snapraid-daemon([ ,(]|\$)'"
check "[C1] no file is in both packages" bash -c "comm -12 <(dpkg -L diskflux | sort) <(dpkg -L snapraid-daemon | sort) | while read -r f; do [ -d \"\$f\" ] || exit 1; done"
check "[A2,C1] no file of DiskFlux has the names of SnapRAID Daemon" sh -c "! dpkg -L diskflux | grep -E 'snapraidd|snapraid-daemon'"
check "[A2] its program, service, configuration and pid file are DiskFlux's" sh -c "test -x /usr/bin/diskflux && test -f /usr/lib/systemd/system/diskflux.service && test -f /etc/diskflux.conf && test -f /run/diskflux.pid"
check "[A2,C3] it answers as diskflux, his daemon as snapraidd" sh -c "curl -s -m5 -D - -o /dev/null $U/v1/array | grep -qi '^Server: diskflux/' && curl -s -m5 -D - -o /dev/null $HU/v1/array | grep -qi '^Server: snapraidd/'"
check "[A2] its login realm is DiskFlux" sh -c "curl -s -m5 -D - -o /dev/null $U/v1/config | grep -qi 'realm=\"DiskFlux\"'"
check "[A2,C3] its pid file is its own, his are where they were" sh -c "[ \$(cat /run/diskflux.pid) != \$(cat /run/snapraidd.pid) ] && kill -0 \$(cat /run/diskflux.pid)"
check "[A3,C4] DiskFlux on 7700, his daemon on 7627 and his instance on 7628, all three listening" sh -c "$(declare -f listens); listens 7700 && listens 7627 && listens 7628"
check "[A3,C4] the installer gives both addresses" sh -c "grep -q 'SnapRAID Daemon:  http://127.0.0.1:7627' $W/install.log && grep -q 'DiskFlux:         http://127.0.0.1:7700' $W/install.log"
check "[A5] his settings are imported, the file marked" grep -q "^# Settings imported from /etc/snapraidd.conf" /etc/diskflux.conf
check "[A5] his login opens DiskFlux" test "$(code -u "$AUTH" $U/v1/config)" = 200
check "[A5] and is asked for" test "$(code $U/v1/config)" = 401
check "[A5,C7] his schedule is DiskFlux's, as it is" test "$(api $U/v1/config | jq -r .maintenance_schedule)" = "Mon 03:33"
check "[A5,C4] his address, on the port of DiskFlux" grep -qx "net_port = 127.0.0.1:7700" /etc/diskflux.conf
check "[A5,C8] his instance is an array of DiskFlux, with his SnapRAID configuration" grep -qx "engine_conf = /etc/snapraid-backup.conf" /etc/diskflux.d/backup.conf
check "[A6,C8] and his log directory for it" grep -qx "sys_log_directory = $ILOG" /etc/diskflux.d/backup.conf
check "[C8] DiskFlux shows both arrays" test "$(api $U/v1/arrays | jq -r '[.arrays[].name] | sort | join(" ")')" = "backup default"
check "[C8] the array of the instance is healthy in DiskFlux" healthy "$B"
check "[A7,C7] the installer lists the jobs DiskFlux would do too" sh -c "grep -q '  - the maintenance (Mon 03:33)' $W/install.log && grep -q '  - the alerts' $W/install.log && grep -q '  - the heartbeat ping' $W/install.log"
check "[A7] DiskFlux sees SnapRAID Daemon running, with its instance" sh -c "curl -s -m5 -u $AUTH $U/v1/host | jq -e '.snapraid_daemon.running == true and (.snapraid_daemon.instances | index(\"backup\"))'"
check "[C9] the update command of DiskFlux restarts diskflux.service only" sh -c "grep -q '^UNIT=\"diskflux.service\"' /usr/sbin/diskflux-upgrade && ! grep -q snapraidd /usr/sbin/diskflux-upgrade"
# the Storage page switched on, as its owner would: the diagnostics and the storage calls need it
echo 'net_storage_admin = 1' >> /etc/diskflux.conf; pkill -x diskflux; sleep 2; $DAEMON; healthy "$D"; idle "$D"
check "[C9] the diagnostics read the journal of DiskFlux, not his" sh -c "curl -s -m30 -u $AUTH $U/v1/host/diagnostics | grep -q 'Daemon log' && ! grep -a -q -- '-u snapraidd' /usr/bin/diskflux"
check "[C2] the package scripts of DiskFlux act on diskflux.service only" sh -c "! grep -h 'systemctl' /var/lib/dpkg/info/diskflux.prerm /var/lib/dpkg/info/diskflux.postrm | grep -q snapraidd"

# ---------------------------------------------------------------------------
section "one log directory for each array, two daemons writing in it"
# ---------------------------------------------------------------------------
check "[A6] DiskFlux logs its runs of his array in his directory" sh -c "ls $LOG/*-diskflux.log* >/dev/null"
check "[A6,C8] and the runs of his instance's array in the instance's directory" sh -c "ls $ILOG/*-diskflux.log* >/dev/null"
for i in $(seq 1 12); do
    post "$H/refresh" '{}' >/dev/null & post "$D/refresh" '{}' >/dev/null &
    post "$I/refresh" '{}' >/dev/null & post "$B/refresh" '{}' >/dev/null &
    wait; idle "$H"; idle "$D"; idle "$I"; idle "$B"
done
BAD=0
for f in $LOG/*.log* $ILOG/*.log*; do
    [ -f "$f" ] || continue
    [ "$(zcat -f "$f" | grep -c '^daemon:start:')" -le 1 ] || { BAD=$((BAD + 1)); echo "      two runs in $f"; }
done
check "[A6,C5] twelve times both asked at once, on both arrays: no log holds two runs" test $BAD = 0
# DiskFlux reads back, at its start, the runs of his daemons from the shared directories:
# those are the logs his daemons list as theirs
{ api "$H/tasks?limit_history=1000"; api "$I/tasks?limit_history=1000"; } | jq -r '.history[]?.log_file // empty' | sort -u > "$W/his-runs"
MISS=0
for e in "$D" "$B"; do
    for f in $(api "$e/tasks?limit_history=1000" | jq -r '.history[]?.log_file // empty'); do
        case "$f" in
        *-diskflux.log*) [ -f "$f" ] || { MISS=$((MISS + 1)); echo "      lost: $f"; } ;;
        *) grep -qxF "$f" "$W/his-runs" || { MISS=$((MISS + 1)); echo "      not of DiskFlux, not of his: $f"; } ;;
        esac
    done
done
check "[C5] every run of DiskFlux has its own log, named ...-diskflux.log; the others are his, read back" test $MISS = 0
MISS=0
for e in "$H" "$I"; do
    for f in $(api "$e/tasks?limit_history=500" | jq -r '.history[]?.log_file // empty'); do
        case "$f" in *-diskflux.log*) MISS=$((MISS + 1)) ;; *) [ -f "$f" ] || MISS=$((MISS + 1)) ;; esac
    done
done
check "[A1,C5] every run of his daemon and his instance has its own log, written by them" test $MISS = 0
his_snap logs
check "[A1,C6] none of his logs was deleted or changed by DiskFlux" logs_kept installed logs
# retention: his daemon keeps all its logs (0); DiskFlux set to one day keeps them too
touch -d '-10 days' "$LOG/20200101-010101-probe.log"; touch -d '-10 days' "$LOG/20200101-010102-probe-diskflux.log"
sed -i 's/^#\?sys_log_retention_days = .*/sys_log_retention_days = 1/' /etc/diskflux.conf
grep -q '^sys_log_retention_days = 1' /etc/diskflux.conf || echo 'sys_log_retention_days = 1' >> /etc/diskflux.conf
pkill -x diskflux; sleep 2; $DAEMON; healthy "$D"; sleep 10
check "[C6] DiskFlux keeping one day deletes no old log while SnapRAID Daemon keeps all of them" sh -c "test -f $LOG/20200101-010101-probe.log && test -f $LOG/20200101-010102-probe-diskflux.log"
# his daemon reads the logs of the directory at its start: the runs of DiskFlux too
kill "$(cat /run/snapraidd.pid)"; sleep 2; snapraidd; healthy "$H"
check "[A6,C6] his daemon, restarted, shows the runs of DiskFlux from the shared directory" sh -c "curl -s -m10 -u $AUTH '$H/tasks?limit_history=1000' | jq -r '.history[]?.log_file // empty' | grep -q -- '-diskflux.log'"
idle "$H"

# ---------------------------------------------------------------------------
section "operations of both daemons on the same array, left to the user"
# ---------------------------------------------------------------------------
head -c 120M /dev/urandom > /mnt/a1/media/big1.bin; head -c 120M /dev/urandom > /mnt/a2/media/big2.bin
post "$H/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
for _ in $(seq 1 50); do [ -e /var/snapraid/a.content.lock ] && fuser /var/snapraid/a.content.lock >/dev/null 2>&1 && break; sleep 0.2; done
post "$D/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
idle "$D"; idle "$H"
check "[A7,C7] a sync of DiskFlux while his runs: refused by SnapRAID's lock" sh -c "curl -s -m10 -u $AUTH '$D/tasks?limit_history=50' | jq -r '.history[0:5][].messages[]?.text' | grep -q 'already in use'"
check "[A7] his sync completes" test "$(last_task "$H" sync)" = "terminated 0"
check "[A7] the array stays healthy in DiskFlux" test "$(api $D/array | jq -r .health)" = passed
check "[A7] and in his daemon" test "$(api $H/array | jq -r .health)" = passed
head -c 120M /dev/urandom > /mnt/a1/media/big3.bin
post "$D/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
for _ in $(seq 1 50); do [ -e /var/snapraid/a.content.lock ] && fuser /var/snapraid/a.content.lock >/dev/null 2>&1 && break; sleep 0.2; done
post "$H/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null
idle "$D"; idle "$H"
check "[A7,C7] the other way: his sync while DiskFlux's runs is refused by the lock too" sh -c "curl -s -m10 -u $AUTH '$H/tasks?limit_history=50' | jq -r '.history[0:5][].messages[]?.text' | grep -q 'already in use'"
check "[A7] DiskFlux's sync completes" test "$(last_task "$D" sync)" = "terminated 0"
check "[A7] both still see the array healthy" sh -c "[ \"\$(curl -s -u $AUTH $U/v1/array | jq -r .health)\" = passed ] && [ \"\$(curl -s -u $AUTH $HU/v1/array | jq -r .health)\" = passed ]"
check "[A7] SnapRAID finds no error" sh -c "snapraid -c /etc/snapraid.conf status 2>&1 | grep -q 'No error detected'"
check "[A7,C7] nothing was switched off or moved in his settings" cmp /etc/snapraidd.conf "$W/his.conf"

# ---------------------------------------------------------------------------
section "a disk added and one renamed from DiskFlux, then seen by his daemon"
# ---------------------------------------------------------------------------
api $U/v1/storage | jq -r .engine_conf.text > "$W/conf.txt"
printf 'data d3 /mnt/a3/\n' >> "$W/conf.txt"
jq -Rs '{text: .}' "$W/conf.txt" > "$W/put.json"
check "[A1] DiskFlux adds a disk to his array's configuration" test "$(post $U/v1/storage/engine_conf @"$W/put.json" PUT | jq -r .success)" = true
post "$D/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null; idle "$U"
check "[A1] and syncs it" test "$(last_task "$D" sync)" = "terminated 0"
post "$H/refresh" '{}' >/dev/null; idle "$H"
check "[A1] his daemon, at its next probe, has the disk" sh -c "curl -s -m10 -u $AUTH $HU/v1/disks | jq -e '[.data_disks[].name] | index(\"d3\")'"
sed -i 's|^data d2 /mnt/a2/$|data media2 /mnt/a2/|' "$W/conf.txt"; jq -Rs '{text: .}' "$W/conf.txt" > "$W/put.json"
check "[A1] DiskFlux renames a disk" test "$(post $U/v1/storage/engine_conf @"$W/put.json" PUT | jq -r .success)" = true
post "$D/schedule" '{"tasks":[{"command":"sync"}]}' >/dev/null; idle "$U"
check "[A1] the sync takes the new name" test "$(last_task "$D" sync)" = "terminated 0" || api "$D/tasks?limit_history=5" | jq -r '.history[0] | .log_file, (.messages[]?.text)' | head -8 | sed 's/^/      | /'
post "$H/refresh" '{}' >/dev/null; idle "$H"
check "[A1] his daemon, at its next probe, has the new name" sh -c "curl -s -m10 -u $AUTH $HU/v1/disks | jq -e '[.data_disks[].name] | index(\"media2\")'"
echo "      his daemon lists the data disks: $(api $H/disks | jq -r '[.data_disks[] | .name] | join(" ")')"
check "[A1] the array stays healthy for both" sh -c "[ \"\$(curl -s -u $AUTH $U/v1/array | jq -r .health)\" = passed ] && [ \"\$(curl -s -u $AUTH $HU/v1/array | jq -r .health)\" = passed ]"

# ---------------------------------------------------------------------------
section "DiskFlux removed, then purged: SnapRAID Daemon as it was"
# ---------------------------------------------------------------------------
his_snap kept
apt-get remove -y -q diskflux > "$W/remove.log" 2>&1; RC=$?
pkill -x diskflux   # what systemd does for its prerm: no systemd in the container
sleep 2; his_snap removed
check "[A1,A4] DiskFlux is removed" test $RC = 0
check "[A1,C2] his daemon and his instance still run, with their pid files, boot links and ports" same kept removed run
check "[A1,A4] his package and files unchanged" same kept removed pkg
check "[A1,A5] his configurations unchanged" same kept removed conf
check "[A6] the logs stay, his and DiskFlux's" sh -c "ls $LOG/*-diskflux.log* >/dev/null && $(declare -f logs_kept); W=$W LOG=$LOG logs_kept kept removed"
apt-get purge -y -q diskflux > "$W/purge.log" 2>&1; RC=$?
sleep 1; his_snap purged
check "[A1,A4] DiskFlux is purged" sh -c "test $RC = 0 && ! dpkg-query -W -f='\${Status}' diskflux 2>/dev/null | grep -q 'installed\|config-files'"
check "[A1,C2] his daemon and his instance still run" same kept purged run
check "[A1,A5] his configurations, his package, his engine unchanged" same kept purged conf pkg
check "[A1] his daemon still answers on 7627 and his instance on 7628" sh -c "[ \$(curl -s -m5 -o /dev/null -w '%{http_code}' -u $AUTH $HU/v1/array) = 200 ] && [ \$(curl -s -m5 -o /dev/null -w '%{http_code}' -u $AUTH $IU/v1/array) = 200 ]"

# ---------------------------------------------------------------------------
section "DiskFlux installed again, then his package purged: DiskFlux as it was"
# ---------------------------------------------------------------------------
env DISKFLUX_DEB="$PKG/daemon.deb" SNAPRAID_DEB="$PKG/snapraid-new.deb" sh "$PKG/installer.sh" > "$W/install2.log" 2>&1; RC=$?
sleep 1; [ -f /run/diskflux.pid ] || $DAEMON; healthy "$D"
check "[A5] installed again, it imports again (its configuration was purged)" sh -c "test $RC = 0 && grep -q '^# Settings imported from' /etc/diskflux.conf"
{ sha256sum /etc/diskflux.conf /etc/diskflux.d/*.conf /usr/bin/diskflux; cat /run/diskflux.pid; } > "$W/df1"
pkill -x snapraidd; sleep 1   # what systemd does for his prerm
apt-get purge -y -q snapraid-daemon > "$W/purge-his.log" 2>&1; RC=$?
check "[A4] his package purges with DiskFlux installed" test $RC = 0
check "[A4] apt leaves DiskFlux alone" not grep -q "Removing diskflux" "$W/purge-his.log"
{ sha256sum /etc/diskflux.conf /etc/diskflux.d/*.conf /usr/bin/diskflux; cat /run/diskflux.pid; } > "$W/df2" 2>&1
check "[A4] DiskFlux, its settings and arrays unchanged" cmp "$W/df1" "$W/df2" || diff "$W/df1" "$W/df2" | sed 's/^/      | /'
check "[A4] DiskFlux still runs" sh -c "kill -0 \$(cat /run/diskflux.pid)"
check "[A4] DiskFlux still answers" test "$(code -u "$AUTH" $U/v1/array)" = 200

[ "${LAB_KEEP:-0}" = 1 ] || teardown

# ---------------------------------------------------------------------------
section "coverage"
# ---------------------------------------------------------------------------
MISSING=""
for t in A1 A2 A3 A4 A5 A6 A7 C1 C2 C3 C4 C5 C6 C7 C8 C9; do
    printf '      %s %3d checks\n' "$t" "${COVER[$t]:-0}"
    [ "${COVER[$t]:-0}" -gt 0 ] || MISSING="$MISSING $t"
done
check "every request (A1 to A7) and every clash (C1 to C9) has checks" test -z "$MISSING"

echo
echo "passed: $PASS   failed: $FAILS"
exit $FAILS
