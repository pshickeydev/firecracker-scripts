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

**[THREAT-MODEL.md](THREAT-MODEL.md)** describes the trust boundaries, what is deliberately not defended, and the planned jailer work. Read it before pointing `SHARE_DIR` at anything you care about.

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

[THREAT-MODEL.md](THREAT-MODEL.md) lists these and the commands to remove them.

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

The point of this repo: run an agent (stable Claude Code) inside a firecracker microVM, working **live** on a host directory, authenticated with credentials minted on the host.

Two constraints shape the design:

- **Firecracker has no shared-filesystem device** (no virtio-fs, no 9p — v1.16 device model). A live host↔guest directory must ride on networking: we use **NFSv4** (guest kernel has the client built in; only `mount.nfs` from `nfs-common` is needed).
- **Refresh tokens rotate on renewal.** Host and guest must share **one copy** of the credentials (the NFS mount provides it), and the guest gets a **dedicated auth profile** (`fc-agents`) so host-side usage never rotates the guest's token out from under it.

### One-time setup

```bash
# 1. build the agent image: fixes guest DNS (empty resolv.conf in the CI rootfs),
#    installs nfs-common via apt, installs the stable Claude Code binary (it
#    bundles its own runtime — no Node in the
#    guest), pins the stable auto-update channel, hardens sshd + locks root's
#    (empty!) password + masks rpcbind, grows the ext4 to 2 GiB, and then
#    strips the apt/dpkg state so the running image — like the upstream
#    CI rootfs — has no working package manager. No git either — see the caveats
#    below.
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

# 2b. (optional) share session transcripts too, so they persist on the host
mkdir -p claude-sessions
./share-dir.sh 0 "$PWD/claude-sessions" /root/.claude

# 3. run Claude Code inside the VM, in your host workspace
ssh -t -i guest.id_rsa -o UserKnownHostsFile=.known_hosts root@172.16.0.2
cd /workspace && ANTHROPIC_PROFILE=fc-agents claude
```

Why this works:

- Claude Code **natively reads `ant` profiles**: with `ANTHROPIC_PROFILE=fc-agents` set, the `user_oauth` profile written by `ant auth login` outranks `/login`. Claude Code renews the token itself (using the `client_id` stored in the profile config) and adds the required `anthropic-beta: oauth-2025-04-20` header — no `ant` binary needed in the guest.
- Because the credentials are NFS-mounted (not copied), renewal writes back through to the single shared copy — rotation-safe by construction. **Never `scp` these files into a VM.**
- Files created in `/workspace` by the agent are your host files, immediately.

**Session transcripts (2b).** Without this mount, Claude Code inside the guest
writes its transcripts to `/root/.claude/projects/*.jsonl` on the guest's own
ext4 rootfs — persistent across guest reboots, but invisible to the host and
lost on the next `images`/`agent` rebuild. Mounting it out to `claude-sessions/`
puts it on the host at `claude-sessions/projects/*/*.jsonl`, same shape as the
native `~/.claude/projects`, so token-usage tooling that reads that layout
(e.g. a cost estimator) can point `--root claude-sessions/projects` at it. It's
gitignored. Unlike `anthropic-config/`, there's no rotation hazard here, so the
same `claude-sessions/` dir can safely be shared to multiple VMs at once —
each session writes its own UUID-named transcript file.

### `share-dir.sh` reference

```bash
./share-dir.sh <VM_ID> <hostdir> [guest_mntpoint]   # default mntpoint: /workspace
./share-dir.sh --unmount <VM_ID> <hostdir> [guest_mntpoint]
```

Host side it manages `/etc/exports.d/fc-agents.exports` (`rw,no_subtree_check,root_squash,anonuid=<you>,anongid=<you>` — the guest is root-only, so instead of `no_root_squash` (guest root = host root, and every session-created file lands `root:root` on the host), guest root acts as **your uid/gid**: full access to your files, and everything created during a session — workspace edits, `.claude/` project dirs, token refreshes in `anthropic-config` — is owned by you, so cleanup never needs sudo), re-exports with `exportfs -ra`, ensures `nfs-server` is running, prunes entries whose host directory no longer exists, and — if firewalld is active — allows NFS (2049/tcp) from that guest's address in the TAP's zone. On Fedora with SELinux enforcing, exporting a directory under `/home` also enables the `nfs_home_dirs` boolean. Guest side it mounts `172.16.0.1:<hostdir>` over SSH.

**Each export is scoped to one VM** (`172.16.0.2/32`), not to the `172.16.0.0/24` range. A subnet-wide export would let any VM mount every other VM's shares — including `anthropic-config/` and its live refresh tokens. Sharing one directory with several VMs is still supported and gets one client entry per VM on the same export line, which is how NFS expresses it:

```
/home/you/project 172.16.0.2/32(rw,...,fsid=100000) 172.16.0.6/32(rw,...,fsid=100000)
```

An entry written by an older `share-dir.sh` (subnet-wide, or `no_root_squash`) is narrowed in place the next time you share that directory, with a notice — other VMs already using it must re-run `share-dir.sh` to get their own entry. If you have files created during earlier `no_root_squash` sessions, fix them once with `sudo chown -R $USER: <dir>`.

Host directory paths must not contain whitespace, quotes or `#`: `/etc/exports` has no quoting, so a path with a space would silently export its *parent*. `share-dir.sh` refuses rather than over-sharing.

`--unmount` tears down both sides, and drops that guest's firewalld rule once nothing is exported to it any more. Neither side needs to still exist: if the guest is already unreachable (stopped or crashed), it retires the host side alone — an unreachable guest holds no mount, but its export entry and rich rule would otherwise linger with no script path left to remove them — and the host directory may likewise have been deleted, since for `--unmount` it is only a lookup key into the exports file. `nfs-server` stays enabled (shared by all VMs). NFS is stateless, so `stop-vm.sh` needs no changes — a guest with mounted NFS shares simply keeps working after a host NFS restart.

Caveat: inotify doesn't cross NFS — irrelevant for Claude Code (it inspects files via bash commands), but don't expect host-side file-watchers to see guest-side writes.

**No git in the guest, so Claude Code's rewind is limited inside the microVM.** The agent image deliberately ships without git (smaller image, less to install; the guest is a disposable sandbox). The cost: Claude Code's rewind / checkpoint capability relies on git to snapshot and restore file state, so without it you can't reliably rewind to a previous point in a session — treat edits as one-way inside the VM (or undo them by asking Claude to revert the specific changes). It also means git commands simply don't work in the guest (`status`/`commit`/`log` against the shared workspace fail) — do repo operations on the host.

**No separate ripgrep either — Claude Code ships its own.** The `agent` step used to install a static `rg` into `/usr/bin`. It doesn't any more: Claude Code's `Grep` tool uses a ripgrep bundled inside its own binary (`USE_BUILTIN_RIPGREP=0` opts out and falls back to a system `rg`), so the separate copy was never what the tool actually ran. Dropping it removes a download and ~5 MB from the image. If you want `rg` on `PATH` for your own shell commands inside the guest, add it back via the same pattern the step uses for other binaries. Re-running `./update-firecracker.sh agent` removes `/usr/bin/rg` from images built by an earlier version.

**No working package manager in the guest — package installation is build-time only.** The `agent` step installs its packages (nfs-common, etc.) inside the chroot on the host, then strips everything that makes apt functional — `/etc/apt` (sources + keyrings), the apt lists, the dpkg database, apt/dpkg logs and caches — before building the ext4. Like the upstream Firecracker CI rootfs (whose build drops all of `/var` from the shipped tree and empties resolv.conf, leaving apt as inert binaries), the running guest can neither locate nor fetch any package: `apt-get install` fails with *Unable to locate package*, and `apt-get update` has no sources to fetch. To ship git (or anything else) in the guest, add it to `AGENT_APT_PKGS` in `update-firecracker.sh` and re-run `./update-firecracker.sh agent` — there is deliberately no way to install packages at runtime.

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

### Clean shutdown

`stop-vm.sh` runs `systemctl poweroff` over SSH, waits for the guest to actually
halt, then reaps the firecracker process and tears down host networking — so ext4
unmounts properly instead of replaying the journal on next boot.

Two non-obvious facts drive the design:

- **No ctrl-alt-del.** The API's `SendCtrlAltDel` is inert here: `start-vm.sh`
  boot args pass `i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd`, the
  controller probe fails (`error -22`), so the injected scancode reaches no
  driver (the call still returns `204`). It is intentionally not used.
- **A clean poweroff does NOT exit firecracker.** x86 Firecracker has no power
  device, so the kernel prints `reboot: Power off not available: System halted
  instead` and parks the VCPUs while the parent process keeps running. "Process
  exited" is therefore *not* the halt signal; `stop-vm.sh` always reaps.

Halt is confirmed by two independent signals, checked each poll:

1. **Serial log (authoritative).** The boot log ends with that final `reboot:`
   line — proof `poweroff.target` completed and filesystems were unmounted. The
   log is `rm -f`'d every boot, so a match can't be stale.
2. **Fallback:** guest answers no ping (a live-but-idle VM always answers ICMP;
   parked VCPUs kill virtio-net RX) *and* its CPU time stays frozen across two
   consecutive polls. Ping is the gate that stops an idle live guest from being
   misread as halted.

Consequences:

- `ssh` must be present on the host, or you silently fall back to hard kills.
- Every outcome prints how it was decided (`serial log confirms…` vs
  `guest unreachable + CPU frozen…`); a path that ends in a kill without halt
  evidence says so on stderr. Read that line rather than assuming a clean stop.
- Typical clean stop is ~12s (matches the image's systemd teardown); the wait
  budget is 45s to absorb slow NFS unmounts from shared workspaces.

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
VCPU_COUNT=4 MEM_SIZE_MIB=8192 ./start-vm.sh   # override the machine profile (default: 2 vCPU / 2048 MiB)
AGENT_PROFILE=fc-agents ./auth-login.sh    # auth profile name (default fc-agents)
ANTHROPIC_CONFIG_DIR=... ./auth-login.sh   # ant's config dir (default <repo>/anthropic-config)

# network policy (start-vm.sh; applied to the whole fc-nat table)
GUEST_LAN_ACCESS=1 ./start-vm.sh           # let guests reach RFC1918 (default: blocked)
GUEST_HOST_PORTS=2049,8080 ./start-vm.sh   # host ports guests may reach (default: 2049)
GUEST_HOST_PORTS=2049,111 ./start-vm.sh    # ...add rpcbind if an NFS mount ever needs it
GUEST_HOST_FILTER=0 ./start-vm.sh          # disable guest->host filtering entirely

# download integrity (update-firecracker.sh)
STRICT_PINS=1 ./update-firecracker.sh agent      # any pin change is fatal, incl. the installer
ALLOW_UNVERIFIED=1 ./update-firecracker.sh binary # proceed if upstream ships no checksum

FORCE_POWEROFF=1 ./stop-vm.sh 3            # ssh-poweroff the guest IP even with no TAP present
```

Notes:

- `start-vm.sh`, `stop-vm.sh`, and `list-vms.sh` all understand `FC_SOCKET_DIR` and `VM_ID` — pass the same values you started the VM with when stopping or listing it.
- **API sockets default to `$XDG_RUNTIME_DIR/firecracker`** (falling back to `/tmp/firecracker-$UID`), created `0700`, and firecracker is launched under `umask 077`. The socket is a full control channel — anything that can connect to it can attach arbitrary host files as guest drives and read guest memory — and its mode otherwise comes from whatever umask you happen to have. `stop-vm.sh` and `list-vms.sh` still find sockets left in `/tmp` by an older `start-vm.sh`, so an already-running VM is not orphaned by the change.
- A fully-renamed `API_SOCKET` is only seen by `./list-vms.sh <id>` (single-id mode), not by the socket scan.
- `stop-vm.sh` will not ssh-poweroff a guest address when its TAP is absent — that address may belong to something that is not ours. `FORCE_POWEROFF=1` overrides.
- `VM_ID` must be an integer in `0..63` — each id consumes one /30 out of the `172.16.0.0/24` range.
- `VCPU_COUNT` (>= 1) and `MEM_SIZE_MIB` (>= 128) are validated and rejected if not integers; Firecracker has no memory or vCPU hot-plug, so a running VM keeps the profile it booted with (`./list-vms.sh` shows it).

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
├── lib-fcnet.sh           # sourced by the four VM scripts (not executable on its own)
├── image-pins.lock        # sha256 of artifacts that publish no checksum (committed)
├── README.md
├── THREAT-MODEL.md
└── .gitignore
```

After `./update-firecracker.sh` (plus `agent`), the repo directory also contains (all gitignored):

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

## Notes

- The firecracker binary is installed to `/usr/local/bin/firecracker-<tag>-<arch>` with a stable `firecracker` symlink pointing at it.
- Firecracker's serial console goes to `fc-vm<ID>.log` — `tail -f` it to watch boot. For interactive access, use SSH (the scripts launch firecracker detached with stdin from `/dev/null`, so the serial console is read-only by design).
- Networking uses a hardcoded `172.16.0.0/24` range. Each VM's `/30` subnet and TAP name are derived from `VM_ID` in `lib-fcnet.sh` (`GUEST_IP`, `HOST_IP`, `TAP`, and the MAC are computed, not env-overridable). If the range collides with another network on your host, change `FC_SUBNET` in `lib-fcnet.sh` and the matching derivation in `start-vm.sh`.
- **The host firewall treats every VM as its own trust domain.** `fc_nft_apply` in `lib-fcnet.sh` rebuilds the whole `fc-nat` table atomically on every start and stop (validated with `nft -c` first, so a bad ruleset is reported instead of half-applied), from the TAPs that exist at that moment. The policy: guests reach the internet masqueraded; guest-to-guest is dropped; guests may not reach RFC1918/CGNAT/link-local destinations, i.e. your LAN (`GUEST_LAN_ACCESS=1` opts out); guest-to-host is limited to NFS and ping (`GUEST_HOST_PORTS` adds ports, `GUEST_HOST_FILTER=0` disables it); and a packet arriving on a TAP with a source outside the VM range is dropped, so a guest cannot spoof past any of it. Services on the host itself are unaffected by the LAN block — those are input, not forward. The guest→host allowance is 2049 only, on the basis that NFSv4 needs no portmapper; if a mount ever fails against a host whose nfs-utils disagrees, `GUEST_HOST_PORTS=2049,111` is the escape hatch.
- **IPv6 is disabled on the TAP.** The `fc-nat` rules are `ip`-family only, so a link-local address on the host end of the TAP would be an unfiltered path from the guest to any host service bound to `::` — around the guest→host filtering entirely. `start-vm.sh` sets `net.ipv6.conf.<tap>.disable_ipv6=1` before bringing the device up, and warns if a link-local address survives anyway. Nothing here uses IPv6: the /30, the NAT and the NFS mount are all IPv4.
- **Guest SSH host keys are verified.** The scripts use a repo-local `.known_hosts` with `StrictHostKeyChecking=accept-new`: an unseen key is recorded, a *changed* one is refused. Host keys are baked into the image, so they are stable across boots; `update-firecracker.sh images` deletes `.known_hosts` when it rebuilds, since the rebuild regenerates them.
- Guest internet egress needs four things, all handled by `start-vm.sh` (each was a real failure mode on Fedora): the host routes (`net.ipv4.ip_forward=1`, persisted to `/etc/sysctl.d/99-fc-agents.conf`), masquerade by **source subnet** leaving via the uplink (nft), the TAP bound to the **same firewalld zone as the uplink interface** + intra-zone forwarding (`--add-forward`) — firewalld rejects cross-zone forwarding even when our own nft chains accept — and a **default route in the guest** (the CI `fcnet-setup.sh` ships none; the `agent` step patches it in).
- `./update-firecracker.sh agent` operates on the extracted `squashfs-root/` tree and rebuilds the ext4 from it — any state accumulated in the previous ext4 (e.g. a newer claude pulled by the auto-updater) is discarded by design, keeping rebuilds reproducible. The apt/dpkg state stripped from the shipped image lives on in `squashfs-root/` (the strip runs on a hardlink staging copy), so re-running `agent` stays a fast idempotent no-op for the apt part. Re-run `agent` after every `images` rebuild. The flip side still holds: `agent` never removes anything the previous run put into `squashfs-root/` — converting a tree built by an older script version (e.g. one with git) requires `./update-firecracker.sh images --force` (fresh extract; plain `images` skips if versions match) followed by `agent`.
- The guest ext4 is persistent across guest reboots (e.g. claude's self-updates survive), but not an `images`/`agent` rebuild. It ships no working package manager: the image is built appliance-style — packages are installed in the build chroot only, via `AGENT_APT_PKGS` in `update-firecracker.sh`.
- The CI rootfs ships an empty `/etc/resolv.conf`; the `agent` step bakes working nameservers (`1.1.1.1`, `8.8.8.8`) into the image. Without it nothing resolves in the guest.
- **The `agent` step hardens the guest image.** The upstream CI rootfs allows SSH password authentication and ships root with an *empty* password field in `/etc/shadow`, guarded only by `PermitEmptyPasswords no`; the build turns password auth off (`sshd_config.d/10-fc-agents.conf`) and locks the account. Pubkey login is unaffected by a locked password. It also masks `rpcbind`, which `nfs-common` pulls in and which otherwise listens on `0.0.0.0:111` — NFSv4 only ever talks to 2049.
- **Downloads are checksum-verified.** The firecracker tarball is checked against the `.sha256` file upstream publishes, and a mismatch is fatal. The CI kernel/rootfs and `claude.ai/install.sh` publish no checksums, so their hashes are recorded in `image-pins.lock` (committed) on first fetch and checked afterwards — for the CI artifacts a later change is fatal, since a dated CI key is immutable; for the installer it is reported and re-pinned, since it legitimately changes. `STRICT_PINS=1` makes everything fatal, `ALLOW_UNVERIFIED=1` relaxes the first case. This does not protect a first fetch; see [THREAT-MODEL.md](THREAT-MODEL.md).
