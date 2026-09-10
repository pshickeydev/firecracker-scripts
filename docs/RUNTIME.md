# Runtime reference

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

## Clean shutdown

`stop-vm.sh` runs `systemctl poweroff` over SSH, waits for the guest to actually
halt, then reaps the firecracker process and tears down host networking — so
ext4 unmounts properly instead of replaying the journal on next boot.

Two non-obvious facts drive the design:

- **No ctrl-alt-del.** The API's `SendCtrlAltDel` is inert here: `start-vm.sh`
  boot args pass `i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd`, the
  controller probe fails (`error -22`), so the injected scancode reaches no
  driver (the call still returns `204`). It is intentionally not used.
- **A clean poweroff does NOT exit firecracker.** x86 Firecracker has no
  power device, so the kernel prints `reboot: Power off not available: System
  halted instead` and parks the VCPUs while the parent process keeps running.
  "Process exited" is therefore *not* the halt signal; `stop-vm.sh` always reaps.

Halt is confirmed by two independent signals, checked each poll:

1. **Serial log (authoritative).** The boot log ends with that final `reboot:`
   line — proof `poweroff.target` completed and filesystems were unmounted.
   The log is `rm -f`'d every boot, so a match can't be stale.
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

## Multiple concurrent VMs

Each VM id gets its own API socket, TAP device, and /30 subnet:

```bash
./start-vm.sh 0   # guest 172.16.0.2  (TAP fc0)
./start-vm.sh 1   # guest 172.16.0.6  (TAP fc1)
./start-vm.sh 2   # guest 172.16.0.10 (TAP fc2)

./list-vms.sh     # status of all of them (ping, PID, vCPU/mem)
./list-vms.sh 0 2 # or check specific ids ("absent" = really stopped)
```

## How the guest IP is assigned (no DHCP needed)

The CI rootfs ships with a `fcnet-setup.sh` that derives the guest IP from the
interface MAC: `06:00:ac:10:00:GG` → `172.16.0.GG`. `start-vm.sh` sets the MAC
accordingly, so the guest auto-configures its address on boot with no DHCP
server.

## Environment overrides

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

- `start-vm.sh`, `stop-vm.sh`, and `list-vms.sh` all understand `FC_SOCKET_DIR`
  and `VM_ID` — pass the same values you started the VM with when stopping or
  listing it.
- **API sockets default to `$XDG_RUNTIME_DIR/firecracker`** (falling back to
  `/tmp/firecracker-$UID`), created `0700`, and firecracker is launched under
  `umask 077`. The socket is a full control channel — anything that can connect
  to it can attach arbitrary host files as guest drives and read guest memory —
  and its mode otherwise comes from whatever umask you happen to have.
  `stop-vm.sh` and `list-vms.sh` still find sockets left in `/tmp` by an older
  `start-vm.sh`, so an already-running VM is not orphaned by the change.
- A fully-renamed `API_SOCKET` is only seen by `./list-vms.sh <id>` (single-id
  mode), not by the socket scan.
- `stop-vm.sh` will not ssh-poweroff a guest address when its TAP is absent —
  that address may belong to something that is not ours. `FORCE_POWEROFF=1`
  overrides.
- `VM_ID` must be an integer in `0..63` — each id consumes one /30 out of the
  `172.16.0.0/24` range.
- `VCPU_COUNT` (>= 1) and `MEM_SIZE_MIB` (>= 128) are validated and rejected
  if not integers; Firecracker has no memory or vCPU hot-plug, so a running VM
  keeps the profile it booted with (`./list-vms.sh` shows it).

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
├── docs/THREAT-MODEL.md
└── .gitignore
```

After `./update-firecracker.sh` (plus `agent`), the repo directory also contains
(all gitignored):

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

## Architecture notes

- The firecracker binary is installed to `/usr/local/bin/firecracker-<tag>-<arch>`
  with a stable `firecracker` symlink pointing at it.
- Firecracker's serial console goes to `fc-vm<ID>.log` — `tail -f` it to watch
  boot. For interactive access, use SSH (the scripts launch firecracker detached
  with stdin from `/dev/null`, so the serial console is read-only by design).
- Networking uses a hardcoded `172.16.0.0/24` range. Each VM's `/30` subnet and
  TAP name are derived from `VM_ID` in `lib-fcnet.sh` (`GUEST_IP`, `HOST_IP`,
  `TAP`, and the MAC are computed, not env-overridable). If the range collides
  with another network on your host, change `FC_SUBNET` in `lib-fcnet.sh` and the
  matching derivation in `start-vm.sh`.
- **The host firewall treats every VM as its own trust domain.** `fc_nft_apply`
  in `lib-fcnet.sh` rebuilds the whole `fc-nat` table atomically on every start
  and stop (validated with `nft -c` first, so a bad ruleset is reported instead
  of half-applied), from the TAPs that exist at that moment. The policy: guests
  reach the internet masqueraded; guest-to-guest is dropped; guests may not
  reach RFC1918/CGNAT/link-local destinations, i.e. your LAN (`GUEST_LAN_ACCESS=1`
  opts out); guest-to-host is limited to NFS and ping (`GUEST_HOST_PORTS` adds
  ports, `GUEST_HOST_FILTER=0` disables it); and a packet arriving on a TAP with
  a source outside the VM range is dropped, so a guest cannot spoof past any of
  it. Services on the host itself are unaffected by the LAN block — those are
  input, not forward. The guest→host allowance is 2049 only, on the basis that
  NFSv4 needs no portmapper; if a mount ever fails against a host whose
  `nfs-utils` disagrees, `GUEST_HOST_PORTS=2049,111` is the escape hatch.
- **IPv6 is disabled on the TAP.** The `fc-nat` rules are `ip`-family only, so a
  link-local address on the host end of the TAP would be an unfiltered path from
  the guest to any host service bound to `::` — around the guest→host filtering
  entirely. `start-vm.sh` sets `net.ipv6.conf.<tap>.disable_ipv6=1` before
  bringing the device up, and warns if a link-local address survives anyway.
  Nothing here uses IPv6: the /30, the NAT and the NFS mount are all IPv4.
- **Guest SSH host keys are verified.** The scripts use a repo-local `.known_hosts`
  with `StrictHostKeyChecking=accept-new`: an unseen key is recorded, a
  *changed* one is refused. Host keys are baked into the image, so they are
  stable across boots; `update-firecracker.sh images` deletes `.known_hosts`
  when it rebuilds, since the rebuild regenerates them.
- Guest internet egress needs four things, all handled by `start-vm.sh` (each was
  a real failure mode on Fedora): the host routes (`net.ipv4.ip_forward=1`,
  persisted to `/etc/sysctl.d/99-fc-agents.conf`), masquerade by **source subnet**
  leaving via the uplink (nft), the TAP bound to the **same firewalld zone as the
  uplink interface** + intra-zone forwarding (`--add-forward`) — firewalld
  rejects cross-zone forwarding even when our own nft chains accept — and a
  **default route in the guest** (the CI `fcnet-setup.sh` ships none; the `agent`
  step patches it in).
- `./update-firecracker.sh agent` operates on the extracted `squashfs-root/`
  tree and rebuilds the ext4 from it — any state accumulated in the previous
  ext4 (e.g. a newer claude pulled by the auto-updater) is discarded by design,
  keeping rebuilds reproducible. The apt/dpkg state stripped from the shipped
  image lives on in `squashfs-root/` (the strip runs on a hardlink staging copy),
  so re-running `agent` stays a fast idempotent no-op for the apt part. Re-run
  `agent` after every `images` rebuild. The flip side still holds: `agent` never
  removes anything the previous run put into `squashfs-root/` — converting a tree
  built by an older script version (e.g. one with git) requires
  `./update-firecracker.sh images --force` (fresh extract; plain `images`
  skips if versions match) followed by `agent`.
- The guest ext4 is persistent across guest reboots (e.g. claude's self-updates
  survive), but not an `images`/`agent` rebuild. It ships no working package
  manager: the image is built appliance-style — packages are installed in the
  build chroot only, via `AGENT_APT_PKGS` in `update-firecracker.sh`.
- The CI rootfs ships an empty `/etc/resolv.conf`; the `agent` step bakes
  working nameservers (`1.1.1.1`, `8.8.8.8`) into the image. Without it nothing
  resolves in the guest.
- **The `agent` step hardens the guest image.** The upstream CI rootfs allows SSH
  password authentication and ships root with an *empty* password field in
  `/etc/shadow`, guarded only by `PermitEmptyPasswords no`; the build turns
  password auth off (`sshd_config.d/10-fc-agents.conf`) and locks the account.
  Pubkey login is unaffected by a locked password. It also masks `rpcbind`,
  which `nfs-common` pulls in and which otherwise listens on `0.0.0.0:111` —
  NFSv4 only ever talks to 2049.
- **Downloads are checksum-verified.** The firecracker tarball is checked against
  the `.sha256` file upstream publishes, and a mismatch is fatal. The CI
  kernel/rootfs and `claude.ai/install.sh` publish no checksums, so their hashes
  are recorded in `image-pins.lock` (committed) on first fetch and checked
  afterwards — for the CI artifacts a later change is fatal, since a dated CI
  key is immutable; for the installer it is reported and re-pinned, since it
  legitimately changes. `STRICT_PINS=1` makes everything fatal,
  `ALLOW_UNVERIFIED=1` relaxes the first case. This does not protect a first
  fetch; see [THREAT-MODEL.md](docs/THREAT-MODEL.md).
