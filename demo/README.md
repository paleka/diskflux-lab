# Public demo

The showcase lab of `docker-compose.yml`, run on a machine of its own, reachable
from the network, protected by a login, and thrown away and started again every
25 minutes, so visitors can change anything.

| File | What it does |
|---|---|
| `demo.yml` | Compose override: publishes port 7627 on every address, login `demo` / `demo` (`DEMO_AUTH=user:password` to change it, `DEMO_AUTH=` for none) |
| `reset.sh` | Removes the lab with its disks and starts a new one |
| `demo-reset.service`, `demo-reset.timer` | Run `reset.sh` 30 seconds after boot and every 25 minutes |
| `upgrade.sh` | Moves the demo to a release of SnapRAID Daemon and to the newest lab, rebuilds the image and starts it |

## Setting it up

On a Debian or Ubuntu machine (a VM with 2 cores, 2 GB of memory and 20 GB of disk
is enough), as root:

```sh
apt-get install -y docker.io docker-compose git
mkdir -p /opt/demo && cd /opt/demo
git clone -b storage https://github.com/paleka/diskflux.git snapraid-daemon
git clone https://github.com/paleka/snapraid-lab.git
snapraid-lab/demo/upgrade.sh
cp snapraid-lab/demo/demo-reset.service snapraid-lab/demo/demo-reset.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now demo-reset.timer
```

The demo is then at `http://ADDRESS:7627/`. Put a tunnel or a reverse proxy in
front of it to reach it from the Internet.

## Updating it

The demo runs in Docker, so it is not updated with the installer or with
`snapraidd-upgrade`: those install the daemon on the machine itself, where it
would fight with the container for port 7627 (the installer refuses to). Instead:

```sh
sudo /opt/demo/snapraid-lab/demo/upgrade.sh --check     # what runs, what is available
sudo /opt/demo/snapraid-lab/demo/upgrade.sh             # the latest release
sudo /opt/demo/snapraid-lab/demo/upgrade.sh 2.2.s9      # a chosen release, also an older one
sudo /opt/demo/snapraid-lab/demo/upgrade.sh storage     # the newest work, not released yet
```

The image is built while the old demo keeps running; if the build fails, nothing
changes. Then the demo starts again on the new image.
