#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Robert Paleka
#
# Makes a Debian 12 or 13 machine (a VM, or a privileged LXC that allows loop devices) the DiskFlux CI runner of git.lan (docs/forgejo-ci.md). Run as root on the VM:
#
#   sh runner-vm-setup.sh [registration token] [/path/to/home-lab-ca.crt]
#
# Without a token it installs and prepares everything and stops before registering; run it again with the token.
# The token: git.lan → Site administration → Actions → Runners → Show registration token (not "Create new runner": in Forgejo 15 that makes a runner for the config-file connection, whose token `register` refuses). One token registers both
# runners below. The CA is the home lab's (the one git.lan's certificate is signed with); without it, put it in
# /usr/local/share/ca-certificates/ first and run update-ca-certificates.
#
# Two forgejo-runner daemons, as in SiteHB's CT 121:
#   diskflux-vm      label `diskflux`     job containers (node:24-bookworm), capacity 2: the daemon's build, ship
#   diskflux-vm-lab  label `diskflux-lab` host mode (docker compose on the VM), capacity 1: the lab's suites, which
#                                         need privileged containers, loop devices and the lab's fixed port
# Running it again is safe: it keeps a registration it already has.
set -eu

TOKEN="${1:-}"
CA="${2:-}"
INSTANCE="${FORGEJO_INSTANCE:-https://git.lan}"
RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-13.2.1}" # CT 121 runs 13.2.1 (2026-11-26); keep the two alike
ARCH=amd64

if [ -n "$CA" ]; then
	install -m 644 "$CA" /usr/local/share/ca-certificates/home-lab-ca.crt
	update-ca-certificates
fi

apt-get update -q
apt-get install -y -q git curl ca-certificates
. /etc/os-release
if [ "$VERSION_CODENAME" = bookworm ]; then
	# Debian 12's docker-compose is v1: Docker's own packages, with the compose v2 plugin
	if ! dpkg -s docker-compose-plugin > /dev/null 2>&1; then
		install -d -m 755 /etc/apt/keyrings
		curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
		echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
			> /etc/apt/sources.list.d/docker.list
		apt-get update -q
	fi
	apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
else
	apt-get install -y -q docker.io docker-compose
fi
curl -fsS -o /dev/null "$INSTANCE/api/v1/version" \
	|| { echo "runner-vm-setup: $INSTANCE does not answer with a trusted certificate (CA? DNS on AdGuard 192.168.50.3?)" >&2; exit 1; }
# Debian's docker-compose is the v2 program; make it the `docker compose` plugin the workflows call
if ! docker compose version > /dev/null 2>&1 && [ -x /usr/bin/docker-compose ]; then
	install -d /usr/libexec/docker/cli-plugins
	ln -sf /usr/bin/docker-compose /usr/libexec/docker/cli-plugins/docker-compose
fi
docker compose version
modprobe loop 2> /dev/null || true # in an LXC the host loads it (loop, fuse, xfs, btrfs)
echo loop > /etc/modules-load.d/diskflux-ci.conf
# In an LXC /dev has no loop nodes (no devtmpfs): the kernel adds a loop device when asked, but nothing makes its
# node, and Docker hands a privileged container the nodes it finds here. Make loop0..127 at every boot.
if [ ! -e /dev/loop0 ] || [ -f /etc/systemd/system/diskflux-loop-nodes.service ]; then
	cat > /etc/systemd/system/diskflux-loop-nodes.service <<'EOF2'
[Unit]
Description=Loop device nodes for the DiskFlux lab suites (no devtmpfs in an LXC)
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 0 127); do [ -e /dev/loop$i ] || mknod -m 660 /dev/loop$i b 7 $i; chgrp disk /dev/loop$i; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2
	systemctl daemon-reload
	systemctl enable --now diskflux-loop-nodes.service
	systemctl restart docker
fi

id runner > /dev/null 2>&1 || useradd -m -s /bin/bash -G docker runner

if [ ! -x /usr/local/bin/forgejo-runner ] || ! /usr/local/bin/forgejo-runner --version | grep -q "$RUNNER_VERSION"; then
	curl -fsSL -o /usr/local/bin/forgejo-runner \
		"https://code.forgejo.org/forgejo/runner/releases/download/v$RUNNER_VERSION/forgejo-runner-$RUNNER_VERSION-linux-$ARCH"
	chmod 755 /usr/local/bin/forgejo-runner
fi

# name, labels, capacity, folder
setup_runner() {
	dir="/home/runner/$4"
	install -d -o runner -g runner "$dir"
	cat > "$dir/config.yml" <<EOF
log:
  level: info
runner:
  file: $dir/.runner
  capacity: $3
  timeout: 3h
  labels: [] # the labels of the registration
cache:
  enabled: true
  dir: $dir/cache
container:
  # the job containers trust git.lan like the VM does
  options: -v /etc/ssl/certs:/etc/ssl/certs:ro
  valid_volumes: [/etc/ssl/certs]
host:
  workdir_parent: $dir/work
EOF
	chown runner:runner "$dir/config.yml"
	if [ ! -f "$dir/.runner" ]; then
		su - runner -c "cd '$dir' && forgejo-runner register --no-interactive --config '$dir/config.yml' \
			--instance '$INSTANCE' --token '$TOKEN' --name '$1' --labels '$2'"
	fi
	unit="forgejo-runner-$4"
	cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=Forgejo runner $1 ($2)
After=docker.service network-online.target
Requires=docker.service

[Service]
User=runner
WorkingDirectory=$dir
ExecStart=/usr/local/bin/forgejo-runner daemon --config $dir/config.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now "$unit"
}

if [ -z "$TOKEN" ]; then
	echo "Prepared. Register the runners: sh $0 <token>   (git.lan: Site administration, Actions, Runners, Show registration token)"
	exit 0
fi

setup_runner diskflux-vm 'diskflux:docker://node:24-bookworm' 2 jobs
setup_runner diskflux-vm-lab 'diskflux-lab:host' 1 lab

# Old images and build cache, every week: each lab suite builds its image again
cat > /etc/cron.weekly/diskflux-ci-prune <<'EOF'
#!/bin/sh
docker system prune -af --filter until=168h > /dev/null
EOF
chmod 755 /etc/cron.weekly/diskflux-ci-prune

systemctl --no-pager status forgejo-runner-jobs forgejo-runner-lab | grep -E '●|Active'
echo "Done: both runners should show Idle under $INSTANCE → Site administration → Actions → Runners."
