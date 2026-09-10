# firecracker-scripts

Opinionated wrapper scripts for running [Firecracker](https://github.com/firecracker-microvm/firecracker) microVMs with networking, SSH access, and easy updates — the minimal tooling for running agent sessions (Claude Code) inside firecracker VMs on a Linux + KVM host.

Seven small scripts and one sourced library, no runtime dependencies beyond standard Linux tools:

| Script | What it does |
|---|---|
| `prereqs.sh` | Checks the host for KVM, TUN, `nft`, `jq`, etc. Run this first on a new machine. |
| `update-firecracker.sh` | Fetches/updates the `firecracker` binary and the guest kernel + Ubuntu rootfs. |
| `start-vm.sh` | Boots a networked microVM, prints the `ssh` command. Supports multiple concurrent VMs. |
| `list-vms.sh` | Shows running VMs: guest IP, TAP device, PID, config, and liveness. |
| `stop-vm.sh` | Cleanly shuts a VM down (orderly poweroff over SSH) and tears down its host networking. |
| `share-dir.sh` | Shares a host directory into a running VM, live, over NFSv4 (with `--unmount`). |
| `auth-login.sh` | Mints Anthropic platform credentials on the host for in-VM Claude Code (via `ant`). |
| `lib-fcnet.sh` | Sourced by the four VM scripts: VM-id derivation, API socket location, SSH options, and the host nftables ruleset. Not run directly. |

Everything the scripts download or build — kernels, rootfs images, the guest SSH key, logs — lives inside this repo directory and is gitignored. Nothing touches `~/.ssh` or personal keys.

**[THREAT-MODEL.md](docs/THREAT-MODEL.md)** describes the trust boundaries, what is deliberately not defended, and the planned jailer work. Read it before pointing `SHARE_DIR` at anything you care about.

## Prerequisites

- **Linux x86_64** with **KVM** (`/dev/kvm` readable+writable by you) and the **TUN** module (`/dev/net/tun`)
- **nftables** (`nft`) for guest NAT — the scripts use nftables, not iptables
- A few standard tools: `curl`, `jq`, `wget`, `ip`, `setsid`, `pgrep`/`pkill` (procps), `ping`, `tar`, `file`, `unsquashfs` (squashfs-tools), `mkfs.ext4` (e2fsprogs), `ssh-keygen`
- For agent sessions: `ssh` + **nfs-utils** (`exportfs`) on the host; **firewalld** (optional, opened automatically) and `go` (optional, auto-installs `ant`)
- `sudo` for: installing the firecracker binary, creating TAP devices, NAT rules, and building the ext4 rootfs

Run the check:

```bash
./prereqs.sh
```

On a minimal Fedora, install the obvious gaps with:

```bash
sudo dnf install squashfs-tools e2fsprogs nftables nfs-utils
```

If `/dev/kvm` exists but isn't accessible:

```bash
sudo usermod -aG kvm "$USER"   # then log out and back in
```

If `/dev/net/tun` is missing:

```bash
sudo modprobe tun
```

## Quick start on a new host

Everything needed to go from a bare Linux box to Claude Code running inside a firecracker VM, in order:

```bash
# 1. requirements (checked in detail below): x86_64 + KVM, TUN, nftables,
#    nfs-utils, standard tools, sudo. On Fedora the gaps are usually:
#    sudo dnf install squashfs-tools e2fsprogs nftables jq wget nfs-utils

# 2. clone + verify the host
git clone git@github.com:pshickeydev/firecracker-scripts.git
cd firecracker-scripts
./prereqs.sh

# 3. fetch the firecracker binary + guest kernel/rootfs, then build the agent image
./update-firecracker.sh            # binary + images (~10 min, needs sudo)
./update-firecracker.sh agent      # DNS fix, nfs-common, Claude Code, 2 GiB,
                                   # apt state stripped — no package manager in
                                   # the running guest (~10 min)

# 4. mint credentials (browser OAuth; installs `ant` via go if missing)
./auth-login.sh

# 5. per session — boot with your workspace live-mounted, share credentials, run
SHARE_DIR=~/some/project ./start-vm.sh 0
./share-dir.sh 0 "$PWD/anthropic-config" /root/.config/anthropic
mkdir -p claude-sessions && ./share-dir.sh 0 "$PWD/claude-sessions" /root/.claude
ssh -t -i guest.id_rsa -o UserKnownHostsFile=.known_hosts root@172.16.0.2
     # then: cd /workspace && ANTHROPIC_PROFILE=fc-agents claude
```

### What it installs on the host

The scripts keep everything they build (images, keys, logs, credentials) inside the repo dir — gitignored. But some host-level state is created; worth knowing before adopting:

| Persistent (survives reboots) | Per-boot (created + torn down by the scripts) |
|---|---|
| `/usr/local/bin/firecracker-<tag>` + `firecracker` symlink | TAP device `fc<N>` + its `/30` address |
| `/etc/sysctl.d/99-fc-agents.conf` (`ip_forward=1`) | nft `fc-nat` table (NAT, isolation, guest→host filtering) |
| `/etc/exports.d/fc-agents.exports` (one entry per shared dir; `--unmount` removes) | firewalld: TAP bound to the uplink's zone, intra-zone forwarding, per-guest NFS rich rule |
| `nfs-server` service enabled | |
| `~/go/bin/ant` (only if `go` is present) | |

**All firewalld changes are runtime-only** and are undone on teardown: the TAP binding when its VM stops, the per-guest NFS rule on `share-dir.sh --unmount`, and intra-zone forwarding once the last VM stops. The scripts only undo what *they* turned on: `stop-vm.sh` removes the forward (runtime and permanent) when the `.fw-forward-added` marker says `start-vm.sh` enabled it and the last VM is gone — so on zones where intra-zone forwarding is already the distro default (Fedora's `FedoraWorkstation` among them) nothing is recorded and the default is left alone. Earlier versions wrote these with `--permanent`, which left `--add-forward` enabling forwarding for *every* interface in the zone indefinitely; because the marker postdates those versions, a permanent `--add-forward` they left behind on a zone where it isn't the default is **not** cleaned up automatically — remove it once by hand with `sudo firewall-cmd --permanent --zone=<zone> --remove-forward`. The cost of runtime-only is that a `firewall-cmd --reload` mid-session drops guest egress until the VM is restarted.

[THREAT-MODEL.md](docs/THREAT-MODEL.md) lists these and the commands to remove them.

### Second-machine caveats

- **`anthropic-config/` does not travel with the repo** (gitignored — it holds live refresh tokens). On another machine, run `./auth-login.sh` there. The same account can hold the profile refreshed from multiple hosts, but never keep **two copies of the same profile mounted at the same time** — refresh-token rotation would orphan one of them (the rotation hazard, below).
- The `172.16.0.0/24` range must not collide with an existing route on the host; if it does, change `FC_SUBNET` in `lib-fcnet.sh` and the matching derivation in `start-vm.sh`.
- Guest DNS is baked as `1.1.1.1`/`8.8.8.8` — fine unless the network blocks external resolvers.
- The firewalld and SELinux paths auto-detect; on hosts without them (e.g. Debian-family with ufw, no SELinux) the guards simply skip.
- The CI kernel/rootfs are **x86_64-only**.

## Setup (detailed, per-command reference)

```bash
# 1. get the scripts
git clone git@github.com:pshickeydev/firecracker-scripts.git
cd firecracker-scripts

# 2. check the host
./prereqs.sh

# 3. install the firecracker binary + fetch the guest kernel/rootfs
./update-firecracker.sh            # = "all": binary + images
# or split it up:
./update-firecracker.sh binary
./update-firecracker.sh images
```

`update-firecracker.sh` is idempotent: it compares the installed version against the latest release and skips if already up to date (pass `--force` to reinstall/rebuild).

## Agent sessions: Claude Code inside the VM

Full agent-session guide: design, per-session workflow, `share-dir.sh` reference,
transcript sharing, and the three guest caveats (no git / no separate ripgrep /
no package manager) are in [docs/AGENT-SESSIONS.md](docs/AGENT-SESSIONS.md).

Quick version:

```bash
# build agent image + mint credentials (once)
./update-firecracker.sh agent
./auth-login.sh

# per session — boot with workspace mounted, share auth, ssh in
SHARE_DIR=~/project ./start-vm.sh
./share-dir.sh 0 "$PWD/anthropic-config" /root/.config/anthropic
mkdir -p claude-sessions && ./share-dir.sh 0 "$PWD/claude-sessions" /root/.claude
ssh -t -i guest.id_rsa -o UserKnownHostsFile=.known_hosts root@172.16.0.2
# inside VM: cd /workspace && ANTHROPIC_PROFILE=fc-agents claude
```

## Run a VM

```bash
# boot VM 0 (default) — creates TAP fc0, guest gets 172.16.0.2
./start-vm.sh

# ssh in
ssh -i guest.id_rsa -o UserKnownHostsFile=.known_hosts root@172.16.0.2

# see what's running (or stale)
./list-vms.sh

# stop it
./stop-vm.sh
```

### Clean shutdown, concurrent VMs, and runtime details

Full reference — halt verification, concurrent VMs, IP assignment, environment
overrides, file layout, firewall rules, IPv6 disable, SSH host keys, download
integrity, and build-chroot architecture — is in [docs/RUNTIME.md](docs/RUNTIME.md).

Quick reference:

```bash
# basic commands
./start-vm.sh [VM_ID]      # default 0
./list-vms.sh [VM_ID ...]
./stop-vm.sh [VM_ID]        # default 0
```

See [docs/RUNTIME.md](docs/RUNTIME.md) for the environment-override table,
clean-shutdown design notes, and architecture details.

See [docs/AGENT-SESSIONS.md](docs/AGENT-SESSIONS.md) for agent session workflow,
and [THREAT-MODEL.md](docs/THREAT-MODEL.md) for trust boundaries and planned jailer
work.

## Files

```
firecracker-scripts/
├── prereqs.sh
├── update-firecracker.sh
├── start-vm.sh
├── list-vms.sh
├── stop-vm.sh
├── share-dir.sh
├── auth-login.sh
├── lib-fcnet.sh           # sourced by the four VM scripts (not executable on its own)
├── image-pins.lock        # sha256 of artifacts that publish no checksum (committed)
├── README.md
├── docs/THREAT-MODEL.md
├── docs/
│   ├── AGENT-SESSIONS.md
│   └── RUNTIME.md
└── .gitignore
```

After `./update-firecracker.sh` (plus `agent`), the repo directory also
contains (all gitignored):

```
vmlinux-<version>          # guest kernel
ubuntu-<version>.ext4      # guest rootfs (agent step: 2 GiB, claude, nfs-common, apt state stripped)
ubuntu-<version>.squashfs.upstream
squashfs-root/             # extracted rootfs tree the ext4 is built from
guest.id_rsa / .pub        # dedicated SSH keypair (gitignored)
anthropic-config/          # ant profile + credentials for the guest (gitignored, SECRET)
claude-sessions/           # Claude Code transcripts shared out of /root/.claude (gitignored, optional)
vmlinux-latest             # -> vmlinux-<version>
ubuntu-latest.ext4         # -> ubuntu-<version>.ext4
ubuntu-latest.id_rsa       # -> guest.id_rsa
fc-vm*.log                 # per-VM serial console logs (mode 0600)
.known_hosts               # TOFU guest host keys; deleted on an images rebuild
.fw-forward-added          # marker: we enabled firewalld intra-zone forwarding
```
