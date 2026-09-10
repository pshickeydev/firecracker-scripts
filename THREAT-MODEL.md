# Threat model

These scripts run coding agents inside disposable microVMs, on a workstation,
against live host directories and live Anthropic credentials. That shape
decides what is worth defending and what is not, so this document states the
boundaries plainly, lists what is deliberately *not* defended, and records the
work that is planned but not done.

## What the boundaries are

| Boundary | Enforced by | Holds against |
|---|---|---|
| guest kernel ↔ host kernel | KVM + Firecracker's device model | a compromised process in the guest |
| guest ↔ guest | nftables (`fc-nat`), per-VM NFS export scoping | one VM reading another's workspace or credentials |
| guest ↔ host services | nftables input chain (NFS + ping only) + IPv6 disabled on the TAP | a guest reaching sshd, rpcbind, or anything else on the host |
| guest ↔ your LAN | nftables forward chain: RFC1918 blocked | a guest pivoting to other machines on your network |
| host files | NFS export scope + `root_squash` + `anonuid` | a guest touching anything outside the directories you shared |

The realistic adversary is **not** someone with a KVM escape. It is a *prompt
injection*: content in a repository, an issue tracker, or a web page that the
agent reads and acts on. Such an attacker already has legitimate code execution
inside the guest. Everything above is about limiting what that buys them.

## What is deliberately not defended

**Anything inside a shared directory is guest-writable, and you run it.**
`share-dir.sh` exports read-write with `anonuid` set to your uid, so the agent
writes host files as you — that is the entire point. If the shared tree
contains something the host later executes (`Makefile`, `.git/hooks/*`,
`package.json` scripts, `.envrc`, or these scripts themselves), a guest that
writes it gets code execution on the host the next time you run it. Share the
project you are working on, not your home directory and not this repo.

**A compromised session can exfiltrate the Anthropic refresh token.** The
credentials are NFS-mounted into the guest because they must be a single shared
copy (refresh tokens rotate). The guest has unrestricted outbound internet
access, because agents need the API and package registries. Those two facts
together mean the token is reachable and sendable. It is scoped to its own
`fc-agents` profile to bound the damage; the response to a suspected compromise
is to revoke that profile, not to hope it did not happen.

**The VMM is not jailed** — see *Planned work* below.

**The build chroot trusts what it downloads.** `update-firecracker.sh agent`
runs `apt` and the Claude Code installer as root in a chroot that has the
host's `/proc`, `/dev` and `/sys` bind-mounted. Root in that chroot is
host-root-equivalent. Checksums (below) reduce the chance of getting the wrong
bytes, but the build step trusts the upstream publisher by design.

**First fetch is trust-on-first-use** for artifacts with no published checksum.

## Integrity of downloads

| Artifact | Check |
|---|---|
| `firecracker` release tarball | upstream `.sha256.txt`, mismatch is fatal |
| CI kernel + rootfs (S3) | no upstream checksum; pinned in `image-pins.lock` on first fetch, mismatch afterwards is **fatal** (a dated CI key is immutable) |
| `claude.ai/install.sh` | no upstream checksum; pinned in `image-pins.lock`, a change is **reported and re-pinned** (it legitimately changes). `STRICT_PINS=1` makes it fatal |

`image-pins.lock` is committed. Set `ALLOW_UNVERIFIED=1` only to work around a
publisher who has stopped shipping checksums.

## Guest image hardening

`update-firecracker.sh agent` applies these to the image it builds:

- `PasswordAuthentication no`, `PermitRootLogin prohibit-password`, and root's
  password locked. The upstream CI rootfs ships root with an **empty** password
  field, guarded only by `PermitEmptyPasswords no`.
- `rpcbind` masked. NFSv4 uses port 2049 only, but installing `nfs-common`
  leaves rpcbind listening on `0.0.0.0:111`. Verified not to affect
  `mount -t nfs4`.
- No package manager (apt/dpkg state stripped) and no git, as before.

## Host state, and how to remove it

Runtime state is torn down by `stop-vm.sh`, including the firewalld
intra-zone-forwarding relaxation once the last VM stops (`.fw-forward-added`
records that it was ours to undo). What survives on purpose:

```bash
sudo rm /etc/sysctl.d/99-fc-agents.conf     # ip_forward=1
sudo rm /etc/exports.d/fc-agents.exports    # or ./share-dir.sh --unmount ...
sudo exportfs -ra
sudo systemctl disable --now nfs-server     # only if nothing else uses it
sudo rm /usr/local/bin/firecracker*         # the VMM itself
```

## Planned work

**Run Firecracker under the jailer.** Today the VMM runs as your user with only
its default seccomp filters, so a Firecracker or virtio 0-day lands with access
to `$HOME`, `guest.id_rsa`, and `anthropic-config/`. The jailer (shipped in the
same release tarball) would `pivot_root` it into a directory holding nothing but
a kernel image, a rootfs image and two device nodes, drop to an unprivileged
uid, and apply cgroup limits.

Sketch of the change:

```bash
sudo jailer --id vm0 --exec-file /usr/local/bin/firecracker \
    --uid "$(id -u)" --gid "$(id -g)" \
    --cgroup-version 2 --cgroup memory.max=... --cgroup pids.max=... \
    --daemonize --new-pid-ns \
    -- --api-sock /run/firecracker.socket
```

It is not done because it is invasive relative to its expected payoff:

- API paths become jail-relative (`/vmlinux`, `/rootfs.ext4`), so the kernel and
  rootfs must be staged into `<chroot>/root` — by hardlink, to keep guest writes
  landing in `ubuntu-latest.ext4`, which requires the jail base to sit on the
  same filesystem as the images.
- The socket path moves and `pgrep -xf "firecracker --api-sock …"` stops
  matching (the jailer injects `--id`/`--start-time-us`), so `stop-vm.sh` and
  `list-vms.sh` need a new liveness handle — `<jail>/firecracker.pid` under
  `--new-pid-ns`.
- Firecracker must then be started as root.

`--netns` is deliberately excluded from that plan: it would need a veth pair per
VM to keep the host side routable for NFS, and the nftables rules already
partition guest-to-guest traffic far more cheaply.
