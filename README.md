# firecracker-scripts

Opinionated wrapper scripts for running [Firecracker](https://github.com/firecracker-microvm/firecracker) microVMs with networking, SSH access, and easy updates — the minimal tooling for running agent sessions (Claude Code) inside firecracker VMs on a Linux + KVM host.

Seven small scripts, no runtime dependencies beyond standard Linux tools:

| Script | What it does |
|---|---|
| `prereqs.sh` | Checks the host for KVM, TUN, `nft`, `jq`, etc. Run this first on a new machine. |
| `update-firecracker.sh` | Fetches/updates the `firecracker` binary and the guest kernel + Ubuntu rootfs. |
| `start-vm.sh` | Boots a networked microVM, prints the `ssh` command. Supports multiple concurrent VMs. |
| `list-vms.sh` | Shows running VMs: guest IP, TAP device, PID, config, and liveness. |
| `stop-vm.sh` | Cleanly shuts a VM down and tears down its host networking. |
| `share-dir.sh` | Shares a host directory into a running VM, live, over NFSv4 (with `--unmount`). |
| `auth-login.sh` | Mints Anthropic platform credentials on the host for in-VM Claude Code (via `ant`). |

Everything the scripts download or build — kernels, rootfs images, the guest SSH key, logs — lives inside this repo directory and is gitignored. Nothing touches `~/.ssh` or personal keys.

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

## Setup

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

The point of this repo: run an agent (stable Claude Code) inside a firecracker microVM, working **live** on a host directory, authenticated with credentials minted on the host.

Two constraints shape the design:

- **Firecracker has no shared-filesystem device** (no virtio-fs, no 9p — v1.16 device model). A live host↔guest directory must ride on networking: we use **NFSv4** (guest kernel has the client built in; only `mount.nfs` from `nfs-common` is needed).
- **Refresh tokens rotate on renewal.** Host and guest must share **one copy** of the credentials (the NFS mount provides it), and the guest gets a **dedicated auth profile** (`fc-agents`) so host-side usage never rotates the guest's token out from under it.

### One-time setup

```bash
# 1. build the agent image: fixes guest DNS (empty resolv.conf in the CI rootfs),
#    installs git + nfs-common via apt, drops in a static ripgrep binary, installs
#    the stable Claude Code binary (it bundles its own runtime — no Node in the
#    guest), pins the stable auto-update channel, and grows the ext4 to 2 GiB.
./update-firecracker.sh agent

# 2. mint credentials (opens a browser for the Anthropic OAuth flow)
./auth-login.sh
```

`auth-login.sh` wraps:

```bash
ANTHROPIC_CONFIG_DIR=$PWD/anthropic-config ant auth login --profile fc-agents
```

It installs `ant` via `go install github.com/anthropics/anthropic-cli/cmd/ant@latest` if missing. `anthropic-config/` holds **live refresh tokens** — it is gitignored; treat it as a secret.

### Per session

```bash
# 1. boot the VM with your workspace mounted at /workspace (live over NFS)
SHARE_DIR=~/my-project ./start-vm.sh

# 2. share the credentials once (they land in the guest at /root/.config/anthropic)
./share-dir.sh 0 "$PWD/anthropic-config" /root/.config/anthropic

# 3. run Claude Code inside the VM, in your host workspace
ssh -t -i guest.id_rsa root@172.16.0.2
cd /workspace && ANTHROPIC_PROFILE=fc-agents claude
```

Why this works:

- Claude Code **natively reads `ant` profiles**: with `ANTHROPIC_PROFILE=fc-agents` set, the `user_oauth` profile written by `ant auth login` outranks `/login`. Claude Code renews the token itself (using the `client_id` stored in the profile config) and adds the required `anthropic-beta: oauth-2025-04-20` header — no `ant` binary needed in the guest.
- Because the credentials are NFS-mounted (not copied), renewal writes back through to the single shared copy — rotation-safe by construction. **Never `scp` these files into a VM.**
- Files created in `/workspace` by the agent are your host files, immediately.

### `share-dir.sh` reference

```bash
./share-dir.sh <VM_ID> <hostdir> [guest_mntpoint]   # default mntpoint: /workspace
./share-dir.sh --unmount <VM_ID> <hostdir> [guest_mntpoint]
```

Host side it manages `/etc/exports.d/fc-agents.exports` (`rw,no_subtree_check,root_squash,anonuid=<you>,anongid=<you>` — the guest is root-only, so instead of `no_root_squash` (guest root = host root, and every session-created file lands `root:root` on the host), guest root acts as **your uid/gid**: full access to your files, and everything created during a session — workspace edits, `.claude/` project dirs, token refreshes in `anthropic-config` — is owned by you, so cleanup never needs sudo), re-exports with `exportfs -ra`, ensures `nfs-server` is running, prunes entries whose host directory no longer exists, and — if firewalld is active — allows NFS (2049/tcp) from `172.16.0.0/24` in the TAP's zone. On Fedora with SELinux enforcing, exporting a directory under `/home` also enables the `nfs_home_dirs` boolean. Guest side it mounts `172.16.0.1:<hostdir>` over SSH.

If you have files created during earlier `no_root_squash` sessions, fix them once with `sudo chown -R $USER: <dir>`.

`--unmount` tears down both sides. The firewalld rule and `nfs-server` stay enabled (shared by all VMs, harmless). NFS is stateless, so `stop-vm.sh` needs no changes — a guest with mounted NFS shares simply keeps working after a host NFS restart.

Caveat: inotify doesn't cross NFS — irrelevant for Claude Code (it inspects files via bash commands), but don't expect host-side file-watchers to see guest-side writes.

## Run a VM

```bash
# boot VM 0 (default) — creates TAP fc0, guest gets 172.16.0.2
./start-vm.sh

# ssh in
ssh -i guest.id_rsa root@172.16.0.2

# see what's running (or stale)
./list-vms.sh

# stop it
./stop-vm.sh
```

### Multiple concurrent VMs

Each VM id gets its own API socket, TAP device, and /30 subnet:

```bash
./start-vm.sh 0   # guest 172.16.0.2  (TAP fc0)
./start-vm.sh 1   # guest 172.16.0.6  (TAP fc1)
./start-vm.sh 2   # guest 172.16.0.10 (TAP fc2)

./list-vms.sh     # status of all of them (ping, PID, vCPU/mem)
./list-vms.sh 0 2 # or check specific ids ("absent" = really stopped)
```

### How the guest IP is assigned (no DHCP needed)

The CI rootfs ships with a `fcnet-setup.sh` that derives the guest IP from the interface MAC: `06:00:ac:10:00:GG` → `172.16.0.GG`. `start-vm.sh` sets the MAC accordingly, so the guest auto-configures its address on boot with no DHCP server.

### Environment overrides

All paths are env-overridable for testing or non-default layouts:

```bash
FC_DIR=/some/other/dir ./start-vm.sh
BIN_INSTALL_DIR=~/.local/bin ./update-firecracker.sh binary
FC_SOCKET_DIR=/run ./start-vm.sh           # put API sockets in /run
API_SOCKET=/run/fc-vm0.sock ./start-vm.sh   # fully override one socket's path
VM_ID=3 FC_DIR=/some/other/dir ./start-vm.sh   # VM_ID env wins over the positional arg
KERNEL=/path/to/vmlinux ROOTFS=/path/to/rootfs.ext4 SSH_KEY=/path/to/key ./start-vm.sh
SHARE_DIR=~/project ./start-vm.sh          # live-mount ~/project at /workspace in the guest
SHARE_DIR=~/project SHARE_MNT=/work ./start-vm.sh  # ...or at a custom guest path
AGENT_PROFILE=fc-agents ./auth-login.sh    # auth profile name (default fc-agents)
ANTHROPIC_CONFIG_DIR=... ./auth-login.sh   # ant's config dir (default <repo>/anthropic-config)
```

Notes:

- `start-vm.sh`, `stop-vm.sh`, and `list-vms.sh` all understand `FC_SOCKET_DIR` and `VM_ID` — pass the same values you started the VM with when stopping or listing it.
- A fully-renamed `API_SOCKET` is only seen by `./list-vms.sh <id>` (single-id mode), not by the socket scan.
- `VM_ID` must be an integer in `0..63` — each id consumes one /30 out of the `172.16.0.0/24` range.

## Layout

```
firecracker-scripts/
├── prereqs.sh
├── update-firecracker.sh
├── start-vm.sh
├── list-vms.sh
├── stop-vm.sh
├── share-dir.sh
├── auth-login.sh
├── README.md
└── .gitignore
```

After `./update-firecracker.sh` (plus `agent`), the repo directory also contains (all gitignored):

```
vmlinux-<version>          # guest kernel
ubuntu-<version>.ext4      # guest rootfs (agent step: 2 GiB, claude, git, rg, nfs-common)
ubuntu-<version>.squashfs.upstream
squashfs-root/             # extracted rootfs tree the ext4 is built from
guest.id_rsa / .pub        # dedicated SSH keypair (gitignored)
anthropic-config/          # ant profile + credentials for the guest (gitignored, SECRET)
vmlinux-latest             # -> vmlinux-<version>
ubuntu-latest.ext4         # -> ubuntu-<version>.ext4
ubuntu-latest.id_rsa       # -> guest.id_rsa
fc-vm*.log                 # per-VM serial console logs
```

## Notes

- The firecracker binary is installed to `/usr/local/bin/firecracker-<tag>-<arch>` with a stable `firecracker` symlink pointing at it.
- Firecracker's serial console goes to `fc-vm<ID>.log` — `tail -f` it to watch boot. For interactive access, use SSH (the scripts launch firecracker detached with stdin from `/dev/null`, so the serial console is read-only by design).
- Networking uses a hardcoded `172.16.0.0/24` range. Each VM's `/30` subnet and TAP name are derived from `VM_ID` inside `start-vm.sh` (`GUEST_IP`, `HOST_IP`, `TAP`, and the MAC are computed, not env-overridable). If the `172.16.0.0/24` range collides with another network on your host, edit the derivation in `start-vm.sh` (and `NFS_SUBNET` in `share-dir.sh`).
- Guest internet egress needs four things, all handled by `start-vm.sh` (each was a real failure mode on Fedora): the host routes (`net.ipv4.ip_forward=1`, persisted to `/etc/sysctl.d/99-fc-agents.conf`), masquerade by **source subnet** leaving via the uplink (nft), the TAP bound to the **same firewalld zone as the uplink interface** + intra-zone forwarding (`--add-forward`) — firewalld rejects cross-zone forwarding even when our own nft chains accept — and a **default route in the guest** (the CI `fcnet-setup.sh` ships none; the `agent` step patches it in).
- `./update-firecracker.sh agent` operates on the extracted `squashfs-root/` tree and rebuilds the ext4 from it — any state accumulated in the previous ext4 (packages installed over SSH, etc.) is discarded by design, keeping rebuilds reproducible. Re-run `agent` after every `images` rebuild.
- The guest ext4 is persistent: anything installed over SSH survives guest reboots, but not an `images`/`agent` rebuild.
- The CI rootfs ships an empty `/etc/resolv.conf`; the `agent` step bakes working nameservers (`1.1.1.1`, `8.8.8.8`) into the image. Without it nothing resolves in the guest.
