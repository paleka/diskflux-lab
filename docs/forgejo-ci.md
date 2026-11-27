# DiskFlux on Forgejo (git.lan)

The DiskFlux repositories are tested on Robert's Forgejo, `git.lan`, the way SiteHB is (web_build ADR-0412 and
`docs/forgejo-ci.md` there): **a push goes to Forgejo, Forgejo tests it, and only a green commit or tag is pushed on to
GitHub.** What GitHub runs for free on the public repositories stays on GitHub and is not run again on Forgejo.

```
Mac: git push ──▶ git.lan (Forgejo) ──.forgejo/workflows/ci.yml──▶ green? ──▶ github.com
                                                                   red?   ──▶ stops; GitHub is not touched
```

| Repository on git.lan | GitHub | Forgejo runs | Then on GitHub |
|---|---|---|---|
| `robert/diskflux` | `paleka/diskflux` (public) | `check`: redocly and yamllint on `diskflux.yaml`, `make distcheck` (tarball, out-of-tree build, C self-tests, UI tests). For a tag also `release-check`: three numbers, annotated, signed, a `## X.Y.Z` section in `RELEASE-NOTES.md` | the branch or tag. A tag starts `release.yml`, which builds and publishes the release (free on a public repository). CodeQL on `storage` |
| `robert/diskflux-lab` | `paleka/diskflux-lab` (public) | every suite, one at a time, against the daemon's `storage` from git.lan: test (unit + API), sizes, arrays, showcase, tiers, extras, machine, existing, coexist. Again every night at 01:17, without shipping | the branch |
| `robert/diskflux-web` | `paleka/diskflux-web` (private) | `check`: `.forgejo/check-site.mjs` — SiteHB's upload limits, no password field, nothing loaded from another host (SiteHB's CSP), local links and pictures present, JSON/JSON-LD/XML well formed | the branch; SiteHB, connected to the repository, pulls `main` onto diskflux.com (ADR-0413) |

The daemon's `.github/workflows/build.yml` runs only on upstream's `master` and `stable` and stays as it is.

## Daily use

`origin` keeps fetching from GitHub; only its push address is Forgejo, over SSH to Forgejo's own address (the
`git.lan` proxy does not forward SSH, and large HTTPS pushes through it arrive cut off):

```sh
cd ~/Documents/projects/snapraid2
git -C diskflux-daemon remote set-url --push origin git@git-ssh.lan:robert/diskflux.git
git -C diskflux-lab    remote set-url --push origin git@git-ssh.lan:robert/diskflux-lab.git
git -C diskflux-web    remote set-url --push origin git@git-ssh.lan:robert/diskflux-web.git
git -C diskflux-daemon remote -v   # fetch: github.com, push: git-ssh.lan
```

Nothing else changes: `git push origin storage`, and for a release `git tag -s v1.3.0 -m "DiskFlux 1.3.0" && git push
origin v1.3.0`. The tag goes to git.lan; once `check` and `release-check` are green it reaches GitHub and the release is
published there. Push the branch first, then the tag. The runs are at `https://git.lan/robert/<repository>/actions`;
after a green run `git fetch` shows GitHub at the pushed commit.

**Forgejo or Proxmox down:** push straight to GitHub, untested, as before:
`git push https://github.com/paleka/diskflux.git storage` (same for a tag).
Undo the whole thing: `git remote set-url --delete --push origin git@git-ssh.lan:robert/<repository>.git`.

## One-time setup

### 1. The repositories on git.lan

For each of `diskflux`, `diskflux-lab`, `diskflux-web`: create `robert/<name>` on `https://git.lan/` (empty, no README),
**public** for the two public ones (the lab's runs clone the daemon from git.lan without a login; git.lan is only on the
LAN), private for the website. Seed it from the Mac before turning Actions on:

```sh
git -C diskflux-daemon push git@git-ssh.lan:robert/diskflux.git storage master && git -C diskflux-daemon push git@git-ssh.lan:robert/diskflux.git --tags
git -C diskflux-lab    push git@git-ssh.lan:robert/diskflux-lab.git main
git -C diskflux-web    push git@git-ssh.lan:robert/diskflux-web.git main
```

Old tags start nothing: a tag runs the workflow of its own commit, and only commits with `.forgejo/workflows` have one.
Then *Settings → Units*: **Actions** on. `actions/checkout` already has its mirror in the org `actions` (SiteHB's).

### 2. The GitHub token

github.com → *Settings → Developer settings → Fine-grained tokens → Generate*: repository access **only
paleka/diskflux, paleka/diskflux-lab, paleka/diskflux-web**; permissions **Contents: Read and write** and **Workflows:
Read and write** (a commit that changes `.github/workflows/` is refused without it). Expiry: a year.

Store it on git.lan in each of the three repositories: *Settings → Actions → Secrets → Add secret*, name
**`GH_PUSH_TOKEN`**. It is never on the Mac.

### 3. The runner machine

The lab's suites need privileged Docker that can mount loop-device filesystems, which SiteHB's unprivileged CT 121 cannot
give. DiskFlux has its own guest on the CI host **proxmox-ci-runners.lan** (192.168.50.2, the host of CT 121):
**CT 100 `diskflux-ci`**, 192.168.50.34, Debian 12, 4 cores, 6 GB RAM + 2 GB swap, 40 GB on `local-lvm`, DNS on AdGuard
(192.168.50.3), starts at boot, tag `diskflux-ci`. Built 2026-11-26:

```sh
# on the host: the modules the lab mounts with, at every boot
modprobe -a loop fuse xfs btrfs; printf 'loop\nfuse\nxfs\nbtrfs\n' > /etc/modules-load.d/diskflux-ci.conf
pct create 100 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst --hostname diskflux-ci --cores 4 --memory 6144 \
  --swap 2048 --rootfs local-lvm:40 --net0 name=eth0,bridge=vmbr0,ip=192.168.50.34/24,gw=192.168.50.1 \
  --nameserver 192.168.50.3 --searchdomain lan --unprivileged 0 --features nesting=1 --onboot 1 --tags diskflux-ci
cat >> /etc/pve/lxc/100.conf <<'EOF2'
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw cgroup:rw
lxc.mount.entry: /dev/loop-control dev/loop-control none bind,create=file
lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file
EOF2
pct start 100
# the home lab CA from CT 121, the script into CT 100, then prepare (no token: everything but the registration)
pct exec 121 -- cat /usr/local/share/ca-certificates/paleka-homelab-ca.crt > /root/paleka-homelab-ca.crt
pct push 100 /root/paleka-homelab-ca.crt /root/paleka-homelab-ca.crt
pct push 100 runner-vm-setup.sh /root/runner-vm-setup.sh
pct exec 100 -- sh /root/runner-vm-setup.sh "" /root/paleka-homelab-ca.crt
```

Privileged on purpose, on a host used only for CI: the lab's own containers are privileged. The script installs Docker's
packages (Debian 12's `docker-compose` is v1), makes `/dev/loop0`–`127` at every boot (`diskflux-loop-nodes.service`: an
LXC has no devtmpfs, so a loop device the kernel adds has no node and Docker could not hand it to the lab), and
forgejo-runner 13.2.1 (CT 121's version). Checked: a privileged container in CT 100 attaches a loop device, makes ext4 on
it and mounts it.

**Registering** (once, with a token from *git.lan → Site administration → Actions → Runners → Show registration token (not "Create new runner": in Forgejo 15 that makes a runner for the config-file connection, whose token `register` refuses)*), in the
host's shell:

```sh
pct exec 100 -- sh /root/runner-vm-setup.sh <token>
```

| Runner | Label | Capacity | Runs |
|---|---|---|---|
| `diskflux-vm` | `diskflux` (`docker://node:24-bookworm`, internet) | 2 | the daemon's `check`, `release-check`, the website's `check`, every `ship` |
| `diskflux-vm-lab` | `diskflux-lab` (host) | 1 | the lab's suites, one at a time |

Both should show *Idle* under *Site administration → Actions → Runners*. Configs in `/home/runner/jobs` and
`/home/runner/lab`, services `forgejo-runner-jobs` and `forgejo-runner-lab`. Old images are pruned weekly. The same script
also works on a Debian 12 or 13 VM.

### 4. Check it

Push the daemon's `storage`: `check`, then `ship`; GitHub's `storage` moves to the commit. Push the lab's `main`: nine
suites, then `ship`.

## When something goes wrong

| What you see | What it means |
|---|---|
| Runs stay *Waiting* | A runner is down: `pct exec 100 -- systemctl status forgejo-runner-jobs forgejo-runner-lab` on proxmox-ci-runners.lan. Or push to GitHub directly |
| `ship` fails: `GH_PUSH_TOKEN is not set` / 403 | The secret is missing, or the token expired or lacks Workflows |
| `ship` fails: `rejected (fetch first)` / non-fast-forward | GitHub has a commit git.lan doesn't (pushed there directly). `git pull`, then `git push` again |
| `release-check`: lightweight / not signed | The tag was made without `-s`. `git tag -d v1.3.0 && git push origin :refs/tags/v1.3.0`, then tag again with `git tag -s` |
| `release-check`: no section | Write `## X.Y.Z` in `RELEASE-NOTES.md` in the commit that is tagged, then tag again |
| A lab suite cannot clone the daemon from git.lan | `robert/diskflux` is private, or CT 100 does not trust git.lan's CA. The run falls back to GitHub's `storage`, which lacks what was not shipped yet |
| The lab image build fails pulling `debian:bookworm-slim` | Docker Hub rate limit or no internet in CT 100 |
| `actions/<name>` cannot be found | git.lan has no mirror `actions/<name>`: add it (*+ → New migration → GitHub*, owner `actions`, mirror) |
