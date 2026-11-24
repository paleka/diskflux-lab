#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
# End to end test of the move of a machine on snapraid-daemon-storage, the package of DiskFlux
# up to 2.2.s14 (with the names of SnapRAID Daemon), to the diskflux package: by the update
# command of the earlier releases, which the web UI runs, given the transition package of the
# release; and by the installer. Settings, arrays, shares and history are kept, the web UI moves
# from 7627 to 7700, nothing of SnapRAID Daemon is touched, and a failed installation puts
# everything back.
#
# The machine has no systemd: a stand-in systemctl and systemd-run (tests/fake-systemd) start and
# stop the two daemons as systemd would.
#
# DESTRUCTIVE: it installs and removes packages and rewrites files of /etc (Samba, NFS). It runs
# only in a container started for it, after tests/coexist-test.sh:
#
#     docker compose -f docker-compose.coexist.yml up --build --abort-on-container-exit --exit-code-from tests
#     docker compose -f docker-compose.coexist.yml down -v
#
# The packages are in $LAB_PKG, put there by the Dockerfile when built with LAB_PACKAGES=1:
# daemon.deb, transition.deb (snapraid-daemon-storage of this release), s14.deb (the earlier
# package, built from the tag v2.2.s14 of the checkout), snapraid-daemon.deb, snapraid-new.deb,
# installer.sh.

[ "${LAB_COEXIST:-0}" = 1 ] || { echo "refusing to run: this container was not started by docker-compose.coexist.yml"; exit 99; }
PKG=${LAB_PKG:-/usr/local/share/lab/pkg}
for f in daemon.deb transition.deb s14.deb snapraid-daemon.deb snapraid-new.deb installer.sh; do
    [ -f "$PKG/$f" ] || { echo "refusing to run: $PKG/$f is missing, build the image with LAB_PACKAGES=1 (s14.deb needs the tag v2.2.s14 in the checkout)"; exit 99; }
done
OURS=$PKG/daemon.deb; TRANS=$PKG/transition.deb; S14=$PKG/s14.deb
HIS=$PKG/snapraid-daemon.deb; ENG=$PKG/snapraid-new.deb
INST=$PKG/installer.sh
HERE=$(cd "$(dirname "$0")" && pwd)
W=/var/lab-move; mkdir -p $W; rm -rf $W/run; mkdir -p $W/run
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "ok    $1"; }
fail() { FAILS=$((FAILS+1)); echo "FAIL  $1"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else fail "$n"; fi; }
sum() { sha256sum < "$1" | cut -c1-64; }
listens() { cat /proc/net/tcp /proc/net/tcp6 | awk -v p="$(printf ':%04X' "$1")" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit !f }'; }
code() { curl -s -m5 -o /dev/null -w '%{http_code}' "$@"; }
state() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null; }

# systemd as the workspace can have it: a systemctl and a systemd-run that act
for t in systemctl systemd-run; do install -m 755 "$HERE/fake-systemd/$t" /usr/local/sbin/$t; done
mkdir -p /run/systemd/system
# apt runs the package scripts with its own PATH, without /usr/local
echo 'DPkg::Path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";' > /etc/apt/apt.conf.d/99lab-move-path
: > $W/systemctl.log; : > $W/systemd-run.log

clean() {
  pkill -x diskflux; pkill -x snapraidd; pkill -f move-to-diskflux; sleep 1
  for p in diskflux snapraid-daemon snapraid-daemon-storage; do dpkg --purge --force-confold $p >/dev/null 2>&1; done
  rm -rf /etc/diskflux* /etc/snapraidd* /etc/snapraid /etc/samba /etc/exports.d /var/tmp/diskflux-move /run/diskflux-move.list /run/diskflux-move.conf /run/snapraidd*.pid /run/diskflux.pid
  rm -f /etc/systemd/system/*.wants/snapraidd*.service /etc/systemd/system/*.wants/diskflux.service
  dpkg -i $ENG >/dev/null 2>&1
}

# a machine on s14 as the web UI leaves it: login, alerts on two channels, an array, a remote,
# shares, history; port left at its default (7627); the service enabled and running
s14_machine() {
  dpkg -i --force-confold $S14 >/dev/null 2>&1
  CRED=$(/usr/bin/snapraidd -g bob:pw-of-bob | sed -n 's/^net_auth_credential = //p')
  sed -i 's/^maintenance_schedule = .*/maintenance_schedule = Sun 03:15/' /etc/snapraidd.conf
  printf 'net_auth_credential = %s\nnet_storage_admin = 1\nnotify_result = sh /etc/snapraidd-alerts.sh "%%s" "%%n" "%%t"\nsys_log_directory = %s\n' "$CRED" $W/run/log >> /etc/snapraidd.conf
  mkdir -p /etc/snapraidd.d /etc/snapraid $W/run/log
  printf 'parity /mnt/p/snapraid.parity\ncontent /mnt/d1/snapraid.content\ndata d1 /mnt/d1\n' > /etc/snapraid/media.conf
  printf 'engine_conf = /etc/snapraid/media.conf\nmaintenance_schedule =\n' > /etc/snapraidd.d/media.conf
  printf '#!/bin/sh\n# channel\tkind=ntfy\turl=https://ntfy.sh/x\n' > /etc/snapraidd-alerts.sh; chmod 700 /etc/snapraidd-alerts.sh
  printf 'shares = media\n' > /etc/snapraidd-host.conf
  for f in runs.log space.log events.log; do echo "history of $f" > /etc/snapraidd-$f; done
  printf 'username=ann\npassword=secret\n' > /etc/snapraidd-remote-nas.cred; chmod 600 /etc/snapraidd-remote-nas.cred
  printf 'state=done\nfrom=2.2.s13\nto=2.2.s14\nstarted=1\nfinished=2\npid=1\nmessage=Upgraded from 2.2.s13 to 2.2.s14\n' > /etc/snapraidd-upgrade.status
  echo "old log" > /etc/snapraidd-upgrade.log
  mkdir -p /etc/samba /etc/exports.d
  printf '[global]\n   workgroup = WORKGROUP\n\n# Shares of the SnapRAID Daemon. Keep this line last.\ninclude = /etc/samba/snapraidd-shares.conf\n' > /etc/samba/smb.conf
  printf '[media]\n   path = /mnt/storage/media\n' > /etc/samba/snapraidd-shares.conf
  printf '/mnt/storage/media *(ro)\n' > /etc/exports.d/snapraidd.exports
  systemctl enable snapraidd.service; systemctl start snapraidd.service
  for f in /etc/snapraidd.conf /etc/snapraidd.d/media.conf /etc/snapraidd-alerts.sh /etc/snapraidd-host.conf /etc/snapraidd-runs.log \
    /etc/snapraidd-space.log /etc/snapraidd-events.log /etc/snapraidd-remote-nas.cred /etc/samba/smb.conf /etc/samba/snapraidd-shares.conf \
    /etc/exports.d/snapraidd.exports; do cp -p "$f" "$W/run/before-$(echo "$f" | tr / _)"; done
}
before() { echo "$W/run/before-$(echo "$1" | tr / _)"; }

# what every move must give
moved_checks() {
  check "the old configuration is gone from its old name" test ! -e /etc/snapraidd.conf
  check "the settings are DiskFlux's, with a line saying where from" sh -c "head -n 1 /etc/diskflux.conf | grep -q '^# Moved from /etc/snapraidd.conf of snapraid-daemon-storage on '"
  check "every setting kept, but the alerts script's new name (comments take the new names)" bash -c "diff <(sed 1d /etc/diskflux.conf) $(before /etc/snapraidd.conf) | grep '^[<>]' | grep -v 'alerts.sh' | grep -v '^[<>] *#' | grep -q . && exit 1 || exit 0"
  check "the comments of the settings name DiskFlux, not the old program or port" sh -c "! grep '^ *#' /etc/diskflux.conf | grep -v '^# Moved from /etc/snapraidd.conf' | grep -q 'snapraidd\|7627\|SnapRAID Daemon Config'"
  check "the alerts point to the script's new name" grep -qxF 'notify_result = sh /etc/diskflux-alerts.sh "%s" "%n" "%t"' /etc/diskflux.conf
  check "no port written: the default of DiskFlux, 7700, at the addresses of the old default" sh -c "! grep -q '^net_port' /etc/diskflux.conf"
  check "the login is kept" grep -qxF "net_auth_credential = $CRED" /etc/diskflux.conf
  check "not marked as imported (it was ours, moved whole)" sh -c "! grep -q '^# Settings imported from' /etc/diskflux.conf"
  check "the settings stay readable by root only" test "$(stat -c %a /etc/diskflux.conf)" = "$(stat -c %a $(before /etc/snapraidd.conf))"
  check "the array moved, unchanged" cmp /etc/diskflux.d/media.conf $(before /etc/snapraidd.d/media.conf)
  for n in alerts.sh remote-nas.cred; do
    check "snapraidd-$n is diskflux-$n, unchanged" sh -c "test ! -e /etc/snapraidd-$n && cmp /etc/diskflux-$n $(before /etc/snapraidd-$n)"
  done
  # DiskFlux goes on writing its history and machine settings
  for n in runs.log space.log events.log; do
    check "snapraidd-$n is diskflux-$n, its history kept" sh -c "test ! -e /etc/snapraidd-$n && head -c \$(stat -c %s $(before /etc/snapraidd-$n)) /etc/diskflux-$n | cmp - $(before /etc/snapraidd-$n)"
  done
  check "snapraidd-host.conf is diskflux-host.conf, its settings kept" sh -c "test ! -e /etc/snapraidd-host.conf && grep -qx 'shares = media' /etc/diskflux-host.conf"
  check "the credentials of the remote stay root only" test "$(stat -c %a /etc/diskflux-remote-nas.cred)" = 600
  check "the shares of Samba under their new name" sh -c "test ! -e /etc/samba/snapraidd-shares.conf && cmp /etc/samba/diskflux-shares.conf $(before /etc/samba/snapraidd-shares.conf)"
  check "smb.conf includes the new name" grep -qx "include = /etc/samba/diskflux-shares.conf" /etc/samba/smb.conf
  check "smb.conf changed only in that line and the comment above it" bash -c "diff /etc/samba/smb.conf $(before /etc/samba/smb.conf) | grep '^[<>]' | grep -v 'include = \|# Shares of ' | grep -q . && exit 1 || exit 0"
  check "the comment names DiskFlux" grep -qx "# Shares of DiskFlux. Keep this line last." /etc/samba/smb.conf
  check "smb.conf as it was is kept as smb.conf.diskflux.bak" cmp /etc/samba/smb.conf.diskflux.bak $(before /etc/samba/smb.conf)
  check "the NFS exports under their new name" sh -c "test ! -e /etc/exports.d/snapraidd.exports && cmp /etc/exports.d/diskflux.exports $(before /etc/exports.d/snapraidd.exports)"
  check "DiskFlux is installed" sh -c "dpkg-query -W -f='\${Status}' diskflux | grep -q 'ok installed'"
  check "snapraid-daemon-storage is gone, purged" sh -c "dpkg-query -W -f='\${Status}' snapraid-daemon-storage 2>/dev/null | grep -q 'ok installed\|config-files' && exit 1 || exit 0"
  check "no file of the old package is left" sh -c "test ! -e /usr/bin/snapraidd && test ! -e /usr/lib/systemd/system/snapraidd.service && test ! -e /usr/share/snapraidd"
  check "the old daemon is stopped" sh -c "! pidof snapraidd"
  check "the old service no longer starts at boot" sh -c "! ls /etc/systemd/system/*.wants/snapraidd.service"
  check "DiskFlux starts at boot" test -L /etc/systemd/system/multi-user.target.wants/diskflux.service
  check "DiskFlux runs on 7700, nothing on 7627 any more" sh -c "pidof diskflux && $(declare -f listens); listens 7700 && ! listens 7627"
  check "the login opens it" test "$(code -u bob:pw-of-bob http://127.0.0.1:7700/snapraid/v1/host)" = 200
  check "it asks for it" test "$(code http://127.0.0.1:7700/snapraid/v1/host)" = 401
  check "the array is loaded" sh -c "curl -s -m5 -u bob:pw-of-bob http://127.0.0.1:7700/snapraid/v1/arrays | jq -e '[.arrays[].name] | index(\"media\")'"
  check "the schedule is kept" sh -c "curl -s -m5 -u bob:pw-of-bob http://127.0.0.1:7700/snapraid/v1/config | jq -e '.maintenance_schedule == \"Sun 03:15\"'"
    check "nothing is left of the move" test ! -e /run/diskflux-move.list
}

echo "== the update of s14 (the web UI's 'Update'), with the transition package of the release"
clean; s14_machine
check "s14 runs on 7627" listens 7627
# with SNAPRAIDD_DEB: the package the web UI would download from the release
SNAPRAIDD_DEB=$TRANS /usr/sbin/snapraidd-upgrade --background; URC=$?
check "the update command of s14 completes" test $URC = 0
for i in $(seq 1 90); do [ -z "$(state snapraid-daemon-storage)" ] && pidof diskflux >/dev/null && break; sleep 1; done
sleep 2
check "the move ran detached, as a unit of its own" grep -q "move-to-diskflux" $W/systemd-run.log
check "the old daemon kept running until the update command was done" sh -c "grep -q 'Upgraded from 2.2.s14 to' /etc/diskflux-upgrade.log"
moved_checks
check "the status of the update says the move and the new port" grep -q "^message=Moved to DiskFlux .*, with the same settings, arrays, shares and history. The web UI is now on port 7700" /etc/diskflux-upgrade.status
check "the log said the port before the old daemon stopped" grep -q "The web UI moves from port 7627 to 7700" /etc/diskflux-upgrade.log
check "the status says done" grep -qx "state=done" /etc/diskflux-upgrade.status
check "it says from which release" grep -qx "from=2.2.s14" /etc/diskflux-upgrade.status
check "the log of the update has the update and the move" sh -c "grep -q 'snapraidd-upgrade, ' /etc/diskflux-upgrade.log && grep -q 'Moved to DiskFlux' /etc/diskflux-upgrade.log"
check "DiskFlux sees no SnapRAID Daemon here" sh -c "! curl -s -m5 -u bob:pw-of-bob http://127.0.0.1:7700/snapraid/v1/host | jq -e '.snapraid_daemon'"
check "the update command of DiskFlux is there" test -x /usr/sbin/diskflux-upgrade
cp /etc/diskflux.conf $W/run/df-after

echo "== then his package installed next to it"
fp() { stat -c '%s %Y %a' /etc/diskflux.conf; sum /etc/diskflux.conf; }
fp > $W/run/df1
dpkg -i $HIS > $W/run/his.log 2>&1; RC=$?
check "his package installs next to DiskFlux" test $RC = 0
check "nothing of DiskFlux changed" bash -c "fp() { stat -c '%s %Y %a' /etc/diskflux.conf; sha256sum < /etc/diskflux.conf | cut -c1-64; }; diff <(fp) $W/run/df1"
check "DiskFlux still runs" pidof diskflux
/usr/bin/snapraidd -c /etc/snapraidd.conf > $W/run/his-start.log 2>&1; sleep 2
check "both run: his on his default 7627, DiskFlux on 7700" sh -c "pidof snapraidd && pidof diskflux && $(declare -f listens); listens 7627 && listens 7700"
check "his answers on 7627 as SnapRAID Daemon" sh -c "curl -s -m5 -o /dev/null -D - http://127.0.0.1:7627/snapraid/v1/array | grep -qi '^Server: snapraidd/'"

echo "== the installer on an s14 machine"
clean; s14_machine
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst1.log 2>&1; RC=$?
sleep 2
check "the installer completes" test $RC = 0
check "it says DiskFlux takes the place of the earlier package" grep -q "snapraid-daemon-storage 2.2.s14-1, the earlier package of DiskFlux, is installed" $W/run/inst1.log
check "no password of its own, no port check stop" sh -c "! grep -q 'Password:\|another program already listens' $W/run/inst1.log"
check "it gives the address, on 7700" grep -q "Web UI:    http://127.0.0.1:7700" $W/run/inst1.log
check "it says the web UI moved from 7627" grep -q "The web UI moved from port 7627, the default of SnapRAID Daemon, to 7700" $W/run/inst1.log
check "Samba and NFS are not added" sh -c "! grep -q 'Samba and NFS were installed' $W/run/inst1.log"
moved_checks
fp > $W/run/df1
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst2.log 2>&1; RC=$?
check "a second run completes and keeps the configuration" sh -c "test $RC = 0 && grep -q 'The existing configuration in /etc/diskflux.conf was kept' $W/run/inst2.log"
check "and changes nothing in it" bash -c "fp() { stat -c '%s %Y %a' /etc/diskflux.conf; sha256sum < /etc/diskflux.conf | cut -c1-64; }; diff <(fp) $W/run/df1"

echo "== his package, then s14 over it (the early way), then the installer"
clean; dpkg -i $HIS >/dev/null 2>&1; echo "# his line" >> /etc/snapraidd.conf
apt-get install -y -q -o Dpkg::Options::=--force-confold $S14 >/dev/null 2>&1
check "s14 took his place (his: configuration left, taken over)" sh -c "dpkg-query -W -f='\${Status} \${Conffiles}' snapraid-daemon | grep -q 'config-files.*obsolete'"
cp -p /etc/snapraidd.conf $W/run/early.conf
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst3.log 2>&1; RC=$?
check "the installer completes" test $RC = 0
check "the configuration was s14's: moved, with the line his had" sh -c "test ! -e /etc/snapraidd.conf && grep -qx '# his line' /etc/diskflux.conf && grep -q '^# Moved from' /etc/diskflux.conf"
check "not imported" sh -c "! grep -q '^# Settings imported' /etc/diskflux.conf"
check "the old package is gone" sh -c "dpkg-query -W -f='\${Status}' snapraid-daemon-storage 2>/dev/null | grep -q 'ok installed\|config-files' && exit 1 || exit 0"

echo "== his package installed: never moved, only imported"
clean; dpkg -i $HIS >/dev/null 2>&1; cp -p /etc/snapraidd.conf $W/run/his.conf
apt-get install -y -q -o Dpkg::Options::=--force-confold $OURS >/dev/null 2>&1
check "his configuration is where it was, unchanged" cmp /etc/snapraidd.conf $W/run/his.conf
check "DiskFlux imported it" grep -q "^# Settings imported from /etc/snapraidd.conf" /etc/diskflux.conf
check "nothing was moved" sh -c "! grep -q '^# Moved from' /etc/diskflux.conf"

echo "== the installer, s14 opened to the network on 7627 (as its installer left it), and a port chosen by hand"
clean; s14_machine
systemctl stop snapraidd.service; echo 'net_port = 0.0.0.0:7627' >> /etc/snapraidd.conf; systemctl start snapraidd.service
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst5.log 2>&1; RC=$?
check "the installer completes" test $RC = 0
check "the addresses stay, on 7700" grep -qx "net_port = 0.0.0.0:7700" /etc/diskflux.conf
check "the old value is written above it" grep -qx "# Port 7627, the default of SnapRAID Daemon, moved to 7700 (it was: net_port = 0.0.0.0:7627)" /etc/diskflux.conf
check "DiskFlux on 0.0.0.0:7700" sh -c "$(declare -f listens); listens 7700 && ! listens 7627"
clean; s14_machine
systemctl stop snapraidd.service; echo 'net_port = 127.0.0.1:8080' >> /etc/snapraidd.conf; systemctl start snapraidd.service
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst6.log 2>&1; RC=$?
check "a port chosen by hand (8080): the installer completes" test $RC = 0
check "8080 is kept" sh -c "grep -qx 'net_port = 127.0.0.1:8080' /etc/diskflux.conf && ! grep -q '^# Port 7627' /etc/diskflux.conf"
check "DiskFlux on 8080" sh -c "$(declare -f listens); listens 8080"
check "nothing said about a move of the port" sh -c "! grep -q 'moved from port 7627' $W/run/inst6.log"

echo "== the installer, s14 on 7627 and 7700 taken by another program: it stops"
clean; s14_machine
perl -MIO::Socket::INET -e 'my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => 7700, Listen => 1, ReuseAddr => 1) or die; sleep 600' & BLOCK=$!; sleep 1
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst7.log 2>&1; RC=$?
kill $BLOCK
check "the installer stops" test $RC = 1
check "it says where the web UI would go, and how to choose" grep -q "moves there from 7627" $W/run/inst7.log
check "nothing installed, s14 still there and running" sh -c "dpkg-query -W -f='\${Version}' snapraid-daemon-storage | grep -qx 2.2.s14-1 && pidof snapraidd && test -z \"\$(dpkg-query -W -f='\${Status}' diskflux 2>/dev/null | grep installed)\""
check "its settings unchanged" cmp /etc/snapraidd.conf $(before /etc/snapraidd.conf)

echo "== an instance snapraidd@NAME of s14 enabled: nothing changes"
clean; s14_machine
ln -sf /usr/lib/systemd/system/snapraidd@.service /etc/systemd/system/multi-user.target.wants/snapraidd@backup.service
SNAPRAIDD_DEB=$TRANS /usr/sbin/snapraidd-upgrade --background; URC=$?
check "the update of s14 stops" test $URC != 0
check "it says why" grep -q "snapraidd@backup.service is enabled" /etc/snapraidd-upgrade.log
check "s14 is still installed, with its files" sh -c "dpkg-query -W -f='\${Version}' snapraid-daemon-storage | grep -qx 2.2.s14-1 && test -x /usr/bin/snapraidd"
check "its configuration is where it was, unchanged" cmp /etc/snapraidd.conf $(before /etc/snapraidd.conf)
check "its daemon still runs" pidof snapraidd
env DISKFLUX_DEB=$OURS SNAPRAID_DEB=$ENG sh $INST > $W/run/inst4.log 2>&1; RC=$?
check "the installer stops too" test $RC = 1
check "saying why" grep -q "snapraidd@backup.service of snapraid-daemon-storage is enabled" $W/run/inst4.log
check "nothing installed" test -z "$(state diskflux)"

echo "== an installation that fails after the move: everything goes back"
clean; s14_machine
# another package owning the program of DiskFlux: dpkg can't unpack it
mkdir -p $W/blocker/DEBIAN $W/blocker/usr/bin
printf 'Package: lab-blocker\nVersion: 1\nArchitecture: all\nMaintainer: lab <lab@localhost>\nDescription: owns /usr/bin/diskflux, to make an unpack fail\n' > $W/blocker/DEBIAN/control
echo x > $W/blocker/usr/bin/diskflux; dpkg-deb --root-owner-group -b $W/blocker $W/blocker.deb >/dev/null
dpkg -i $W/blocker.deb >/dev/null 2>&1
apt-get install -y -q -o Dpkg::Options::=--force-confold $OURS > $W/run/fail.log 2>&1; RC=$?
dpkg --purge lab-blocker >/dev/null 2>&1
check "the installation fails" test $RC != 0
check "the settings are back, as they were (content and time)" sh -c "cmp /etc/snapraidd.conf $(before /etc/snapraidd.conf) && test \$(stat -c %Y /etc/snapraidd.conf) = \$(stat -c %Y $(before /etc/snapraidd.conf))"
check "the array is back" cmp /etc/snapraidd.d/media.conf $(before /etc/snapraidd.d/media.conf)
check "the files next to it are back" sh -c "for n in alerts.sh host.conf runs.log remote-nas.cred; do cmp /etc/snapraidd-\$n $W/run/before-_etc_snapraidd-\$n || exit 1; done"
check "smb.conf is back" cmp /etc/samba/smb.conf $(before /etc/samba/smb.conf)
check "the shares are back" cmp /etc/samba/snapraidd-shares.conf $(before /etc/samba/snapraidd-shares.conf)
check "no file of DiskFlux is left" sh -c "! ls /etc/diskflux* /etc/samba/diskflux-shares.conf /etc/exports.d/diskflux.exports"
check "nothing is left of the move" test ! -e /run/diskflux-move.list

echo "== a machine that had DiskFlux once (purged), back on s14, then moved again"
# a purge of DiskFlux removes only /etc/diskflux.conf: its other files stay
leftovers() {
  mkdir -p /etc/diskflux.d; echo 'engine_conf = /etc/snapraid/old.conf' > /etc/diskflux.d/old.conf
  echo 'shares = stale' > /etc/diskflux-host.conf
  echo 'stale history' > /etc/diskflux-runs.log
  printf 'state=done\nfrom=26.12.1\nto=26.12.0\n' > /etc/diskflux-upgrade.status
  printf '[stale]\n   path = /nowhere\n' > /etc/samba/diskflux-shares.conf
  # its include line left in smb.conf, before the one s14 wrote
  sed -i 's|^# Shares of the SnapRAID Daemon\. Keep this line last\.$|# Shares of DiskFlux. Keep this line last.\ninclude = /etc/samba/diskflux-shares.conf\n&|' /etc/samba/smb.conf
  cp -p /etc/samba/smb.conf $W/run/smb.leftover
}
clean; s14_machine; leftovers
apt-get install -y -q -o Dpkg::Options::=--force-confold $OURS > $W/run/left.log 2>&1; RC=$?
check "the move completes" test $RC = 0
check "the arrays of s14 are moved, the old ones kept aside" sh -c "cmp /etc/diskflux.d/media.conf $(before /etc/snapraidd.d/media.conf) && test ! -e /etc/diskflux.d/old.conf && test -f /etc/diskflux.d.before-move/old.conf"
check "the settings and history of s14 are moved" sh -c "grep -qx 'shares = media' /etc/diskflux-host.conf && ! grep -q stale /etc/diskflux-host.conf /etc/diskflux-runs.log && grep -qx 'history of runs.log' /etc/diskflux-runs.log"
check "the files left by DiskFlux are kept as .before-move" sh -c "grep -qx 'shares = stale' /etc/diskflux-host.conf.before-move && grep -qx 'stale history' /etc/diskflux-runs.log.before-move && grep -qx from=26.12.1 /etc/diskflux-upgrade.status.before-move"
check "the update record is the one of s14" grep -qx from=2.2.s13 /etc/diskflux-upgrade.status
check "the shares of s14, the old shares file kept aside" sh -c "grep -q '^\[media\]' /etc/samba/diskflux-shares.conf && grep -q '^\[stale\]' /etc/samba/diskflux-shares.conf.before-move"
check "smb.conf includes the shares once, with one marker" sh -c "test \$(grep -c '^include = /etc/samba/diskflux-shares.conf\$' /etc/samba/smb.conf) = 1 && test \$(grep -c '^# Shares of DiskFlux. Keep this line last.\$' /etc/samba/smb.conf) = 1 && ! grep -q snapraidd-shares /etc/samba/smb.conf"
check "the move lists what it kept aside" grep -q 'diskflux-host.conf -> /etc/diskflux-host.conf.before-move' $W/run/left.log

echo "== the same, and the installation fails: both are back where they were"
clean; s14_machine; leftovers
dpkg -i $W/blocker.deb >/dev/null 2>&1
apt-get install -y -q -o Dpkg::Options::=--force-confold $OURS > $W/run/leftfail.log 2>&1; RC=$?
dpkg --purge lab-blocker >/dev/null 2>&1
check "the installation fails" test $RC != 0
check "the files of s14 are back" sh -c "cmp /etc/snapraidd.d/media.conf $(before /etc/snapraidd.d/media.conf) && cmp /etc/snapraidd-host.conf $(before /etc/snapraidd-host.conf) && cmp /etc/samba/snapraidd-shares.conf $(before /etc/samba/snapraidd-shares.conf)"
check "the files left by DiskFlux are back under their names" sh -c "test -f /etc/diskflux.d/old.conf && grep -qx 'shares = stale' /etc/diskflux-host.conf && grep -qx 'stale history' /etc/diskflux-runs.log && grep -q '^\[stale\]' /etc/samba/diskflux-shares.conf"
check "smb.conf as it was" cmp /etc/samba/smb.conf $W/run/smb.leftover
check "nothing is left aside" sh -c "! ls -d /etc/*.before-move* /etc/samba/*.before-move* 2>/dev/null | grep -q ."

clean
for t in systemctl systemd-run; do rm -f /usr/local/sbin/$t; done
rm -f /etc/apt/apt.conf.d/99lab-move-path
rmdir /run/systemd/system 2>/dev/null; rmdir /run/systemd 2>/dev/null
echo; echo "passed: $PASS   failed: $FAILS"; exit $FAILS
