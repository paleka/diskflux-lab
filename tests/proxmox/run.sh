#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# Runs the DiskFlux checks on a Proxmox node, as root, each in the background
# (systemd-run), with its log in /root/diskflux-t13/STEP.log:
#
#   bash run.sh test-lxc ID          an existing test LXC on snapraid-daemon-storage:
#                                    snapshot, move (tests/lxc-check.sh), reboot, check again
#   bash run.sh coexist [ID]         a new Debian LXC: SnapRAID Daemon 2.2 under systemd,
#                                    then DiskFlux next to it (tests/proxmox/systemd-check.sh),
#                                    reboot, check again (default ID 140)
#   bash run.sh rpm [ID]             a new Rocky/Alma LXC: the .rpm next to his .rpm,
#                                    and the move from the s14 .rpm (default ID 141)
#   bash run.sh docker [ID] [IP]     a new Debian VM with Docker: every suite of the lab
#                                    (default ID 142, IP: the first free from 192.168.50.84)
#   bash run.sh status               the end of every log
#   bash run.sh destroy ID...        removes guests tagged diskflux-test (and only those)
#
# New guests are tagged diskflux-test and named dft-*. Environment: BRANCH (coexist),
# RAWREF (a commit of the lab to fetch the scripts from, past GitHub's cache).

set -u
BRANCH=${BRANCH:-coexist}
RAW=https://raw.githubusercontent.com/paleka/diskflux-lab/${RAWREF:-$BRANCH}/tests
OUT=/root/diskflux-t13
NODE=$(hostname)
mkdir -p $OUT
die() { echo "run.sh: $*" >&2; exit 2; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

# run the rest of this script in the background, logging to OUT/NAME.log
background() {
	local name=$1; shift
	if [ -z "${DFT_INNER:-}" ]; then
		systemctl reset-failed "dft-$name" >/dev/null 2>&1
		systemd-run --unit="dft-$name" --collect --quiet --setenv=DFT_INNER=1 --setenv=BRANCH="$BRANCH" --setenv=RAWREF="${RAWREF:-$BRANCH}" \
			-p StandardOutput=file:$OUT/$name.log -p StandardError=file:$OUT/$name.log -- bash "$(readlink -f "$0")" "$@" \
			&& echo "started in the background: tail -f $OUT/$name.log"
		exit 0
	fi
}

template() { # debian | rocky
	local want=$1 t
	t=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -m1 "vztmpl/${want}")
	if [ -z "$t" ]; then
		pveam update >/dev/null 2>&1
		case $want in
			debian) t=$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard' | sort -V | tail -1) ;;
			rocky) t=$(pveam available --section system | awk '{print $2}' | grep -E '^(rockylinux|almalinux)-(9|10)' | sort -V | tail -1) ;;
		esac
		[ -n "$t" ] || die "no $want template available"
		pveam download local "$t" >/dev/null || die "template download"
		t=local:vztmpl/$t
	fi
	echo "$t"
}

new_lxc() { # id name template [pct create options...]
	local id=$1 name=$2 tpl=$3; shift 3
	pct status "$id" >/dev/null 2>&1 && die "guest $id exists already (destroy it first: bash run.sh destroy $id)"
	qm status "$id" >/dev/null 2>&1 && die "guest $id exists already"
	say "creating LXC $id $name from $tpl"
	pct create "$id" "$tpl" --hostname "$name" --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:16 \
		--net0 name=eth0,bridge=vmbr0,ip=dhcp,ip6=auto --unprivileged 1 --features nesting=1 \
		--tags diskflux-test --onboot 0 --description "DiskFlux test machine (run.sh), safe to destroy" "$@" >/dev/null || die "pct create"
	pct start "$id" || die "pct start"
	for _ in $(seq 1 60); do pct exec "$id" -- sh -c 'ip -4 route | grep -q default' 2>/dev/null && break; sleep 2; done
	sleep 3
}

in_lxc() { # id script args...: fetch a script of the lab into the LXC and run it
	local id=$1 script=$2; shift 2
	pct exec "$id" -- sh -c "command -v curl >/dev/null || { apt-get update -q >/dev/null 2>&1; apt-get install -y -q curl ca-certificates >/dev/null 2>&1; } || dnf -y -q install curl >/dev/null 2>&1; curl -fsSL '$RAW/$script' -o /root/$(basename "$script")" || die "fetch $script"
	pct exec "$id" -- env BRANCH="$BRANCH" HOME=/root bash "/root/$(basename "$script")" "$@"
}

reboot_lxc() {
	say "rebooting LXC $1"
	pct reboot "$1" --timeout 120 || pct stop "$1"
	pct status "$1" | grep -q running || pct start "$1"
	for _ in $(seq 1 60); do pct exec "$1" -- systemctl is-system-running >/dev/null 2>&1 && break; sleep 2; done
	sleep 10
}

case "${1:-}" in
test-lxc)
	ID=${2:?the ID of the test LXC}
	background "test-lxc-$ID" "$@"
	if ! pct listsnapshot "$ID" | grep -q before_t13; then
		say "snapshot before_t13 of $ID (back: pct rollback $ID before_t13)"
		pct snapshot "$ID" before_t13 --description "before the DiskFlux move test" || die "snapshot"
	fi
	pct set "$ID" --memory 2048 --cores 2 >/dev/null
	in_lxc "$ID" lxc-check.sh; RC1=$?
	reboot_lxc "$ID"
	pct exec "$ID" -- bash /root/lxc-check.sh after-reboot; RC2=$?
	say "test-lxc $ID done: before $RC1 failed, after the reboot $RC2 failed"
	;;
coexist)
	ID=${2:-140}
	background "coexist-$ID" "$@"
	# six disks of their own for the two arrays: SnapRAID wants a filesystem per disk
	new_lxc "$ID" dft-coexist "$(template debian)" \
		--mp0 local-lvm:2,mp=/srv/a/d1 --mp1 local-lvm:2,mp=/srv/a/d2 --mp2 local-lvm:2,mp=/srv/a/parity \
		--mp3 local-lvm:1,mp=/srv/b/d1 --mp4 local-lvm:1,mp=/srv/b/d2 --mp5 local-lvm:1,mp=/srv/b/parity
	in_lxc "$ID" proxmox/systemd-check.sh before; RC1=$?
	say "browser check window: DiskFlux http://$(pct exec "$ID" -- hostname -I | awk '{print $1}'):7700, 2 minutes"
	sleep 120
	reboot_lxc "$ID"
	pct exec "$ID" -- bash /root/systemd-check.sh after-reboot; RC2=$?
	say "coexist $ID done: before $RC1 failed, after the reboot $RC2 failed"
	;;
rpm)
	ID=${2:-141}
	background "rpm-$ID" "$@"
	new_lxc "$ID" dft-rpm "$(template rocky)"
	in_lxc "$ID" proxmox/rpm-check.sh; RC=$?
	say "rpm $ID done: $RC failed"
	;;
docker)
	ID=${2:-142}
	IP=${3:-}
	background "docker-$ID" "$@"
	qm status "$ID" >/dev/null 2>&1 && die "guest $ID exists already"
	pct status "$ID" >/dev/null 2>&1 && die "guest $ID exists already"
	IMG=$(pvesm list local --content import 2>/dev/null | awk '{print $1}' | grep -m1 'debian-13-generic-amd64')
	[ -n "$IMG" ] || die "no Debian 13 cloud image in local:import"
	GW=$(ip -4 route | awk '/^default/ {print $3; exit}')
	NET=$(ip -4 -o addr show vmbr0 | awk '{print $4; exit}')
	if [ -z "$IP" ]; then
		base=${GW%.*}
		for n in $(seq 84 99); do
			ping -c1 -W1 "$base.$n" >/dev/null 2>&1 && continue
			ip neigh show "$base.$n" | grep -q lladdr && continue
			IP=$base.$n; break
		done
		[ -n "$IP" ] || die "no free address found; give one: bash run.sh docker $ID ADDRESS"
	fi
	KEY=/root/.ssh/diskflux-test
	[ -f $KEY ] || ssh-keygen -q -t ed25519 -N '' -f $KEY -C diskflux-test
	say "creating VM $ID dft-docker at $IP (4 cores, 8 GB, 60 GB)"
	qm create "$ID" --name dft-docker --cores 4 --cpu host --memory 8192 --net0 virtio,bridge=vmbr0 \
		--scsihw virtio-scsi-single --scsi0 "local-lvm:0,import-from=$IMG" --ide2 local-lvm:cloudinit \
		--boot order=scsi0 --serial0 socket --vga serial0 --ostype l26 --tags diskflux-test \
		--ciuser dft --sshkeys $KEY.pub --ipconfig0 "ip=$IP/${NET#*/},gw=$GW" --nameserver "$GW" \
		--description "DiskFlux test machine (run.sh), safe to destroy" >/dev/null || die "qm create"
	qm resize "$ID" scsi0 60G >/dev/null
	qm start "$ID"
	SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 dft@$IP"
	for _ in $(seq 1 90); do $SSH true 2>/dev/null && break; sleep 5; done
	$SSH true || die "the VM does not answer on ssh at $IP"
	$SSH "sudo cloud-init status --wait >/dev/null 2>&1; curl -fsSL '$RAW/proxmox/docker-suites.sh' -o docker-suites.sh && sudo env BRANCH=$BRANCH bash docker-suites.sh"; RC=$?
	say "docker $ID done: $RC suites failed"
	;;
status)
	for f in $OUT/*.log; do [ -f "$f" ] || continue; echo "=== $(basename "$f" .log)"; grep -E '^(passed:|FAIL|\[..:..:..\]|suite )' "$f" | tail -n 30; done
	systemctl list-units --no-legend 'dft-*' | awk '{print "running:", $1}'
	;;
destroy)
	shift
	for id in "$@"; do
		if pct config "$id" 2>/dev/null | grep -q '^tags:.*diskflux-test'; then pct stop "$id" >/dev/null 2>&1; pct destroy "$id" --purge && say "destroyed LXC $id"
		elif qm config "$id" 2>/dev/null | grep -q '^tags:.*diskflux-test'; then qm stop "$id" >/dev/null 2>&1; qm destroy "$id" --purge && say "destroyed VM $id"
		else say "$id is not a diskflux-test guest: left alone"; fi
	done
	;;
*) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
