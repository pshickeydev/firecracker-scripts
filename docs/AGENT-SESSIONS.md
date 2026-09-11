# Agent sessions: Claude Code inside the VM

The point of this repo: run an agent (stable Claude Code) inside a firecracker
microVM, working **live** on a host directory, authenticated with credentials
minted on the host.

Two constraints shape the design:

- **Firecracker has no shared-filesystem device** (no virtio-fs, no 9p — v1.16
  device model). A live host↔guest directory must ride on networking: we use
  **NFSv4** (guest kernel has the client built in; only `mount.nfs` from
  `nfs-common` is needed).
- **Refresh tokens rotate on renewal.** Host and guest must share **one copy**
  of the credentials (the NFS mount provides it), and the guest gets a
  **dedicated auth profile** (`fc-agents`) so host-side usage never rotates
  the guest's token out from under it.

## One-time setup

```bash
# 1. build the agent image: fixes guest DNS (empty resolv.conf in the CI
#    rootfs), installs nfs-common via apt, installs the stable Claude Code
#    binary (it bundles its own runtime — no Node in the guest), pins the
#    stable auto-update channel, hardens sshd + locks root's (empty!)
#    password + masks rpcbind, grows the ext4 to 2 GiB, and then strips the
#    apt/dpkg state so the running image — like the upstream CI rootfs —
#    has no working package manager. No git either — see the caveats below.
./update-firecracker.sh agent

# 2. mint credentials (opens a browser for the Anthropic OAuth flow)
./auth-login.sh
```

`auth-login.sh` wraps:

```bash
ANTHROPIC_CONFIG_DIR=$PWD/anthropic-config ant auth login --profile fc-agents
```

It installs `ant` via `go install github.com/anthropics/anthropic-cli/cmd/ant@latest`
if missing. `anthropic-config/` holds **live refresh tokens** — it is gitignored;
treat it as a secret.

## Per session

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
     # then: cd /workspace && ANTHROPIC_PROFILE=fc-agents IS_SANDBOX=1 claude --dangerously-skip-permissions
```

Why this works:

- Claude Code **natively reads `ant` profiles**: with `ANTHROPIC_PROFILE=fc-agents`
  set, the `user_oauth` profile written by `ant auth login` outranks `/login`.
  Claude Code renews the token itself (using the `client_id` stored in the
  profile config) and adds the required `anthropic-beta: oauth-2025-04-20`
  header — no `ant` binary needed in the guest.
- Because the credentials are NFS-mounted (not copied), renewal writes back
  through to the single shared copy — rotation-safe by construction.
  **Never `scp` these files into a VM.**
- Files created in `/workspace` by the agent are your host files, immediately.

## `--dangerously-skip-permissions` needs `IS_SANDBOX=1`

Claude Code refuses bypass-permissions mode (`--dangerously-skip-permissions`)
when it detects root/sudo privileges. The guest is deliberately root-only —
the NFS `root_squash` + `anonuid` mapping relies on guest root acting as
**your** uid on the host, so the sessions always trip that guard, and a
non-root guest user would break file ownership instead of fixing anything.
The intended escape hatch is `IS_SANDBOX=1`: it tells Claude Code the session
is already confined (the value must be exactly `1`). Here that is simply
true — the microVM is the sandbox, and the guest's only reach into the host
is the NFS export of the directories you shared (see THREAT-MODEL.md:
permission prompts are not relied on as a boundary; the adversary already
has legitimate code execution inside the guest). The docs put it the same
way: `--dangerously-skip-permissions` is sanctioned in "a container, VM, or
the sandbox runtime". The guard gates the mode, not just the CLI flag — a
`bypassPermissions` default in `~/.claude/settings.json` hits the same root
check — so `IS_SANDBOX=1` must be in the environment either way.

The first interactive bypass session also asks a one-time confirmation
dialog before entering the mode; accept it once and it sticks for the
config dir (`--bg` sessions are refused until an interactive session has
accepted it).

**Session transcripts (2b).** Without this mount, Claude Code inside the guest
writes its transcripts to `/root/.claude/projects/*.jsonl` on the guest's own
ext4 rootfs — persistent across guest reboots, but invisible to the host and
lost on the next `images`/`agent` rebuild. Mounting it out to `claude-sessions/`
puts it on the host at `claude-sessions/projects/*/*.jsonl`, same shape as the
native `~/.claude/projects`, so token-usage tooling that reads that layout
(e.g. a cost estimator) can point `--root claude-sessions/projects` at it. It's
gitignored. Unlike `anthropic-config/`, there's no rotation hazard here, so the
same `claude-sessions/` dir can safely be shared to multiple VMs at once — each
session writes its own UUID-named transcript file.

## `share-dir.sh` reference

```bash
./share-dir.sh <VM_ID> <hostdir> [guest_mntpoint]   # default mntpoint: /workspace
./share-dir.sh --unmount <VM_ID> <hostdir> [guest_mntpoint]
```

Host side it manages `/etc/exports.d/fc-agents.exports`
(`rw,no_subtree_check,root_squash,anonuid=<you>,anongid=<you>` — the guest is
root-only, so instead of `no_root_squash` (guest root = host root, and every
session-created file lands `root:root` on the host), guest root acts as
**your uid/gid**: full access to your files, and everything created during a
session — workspace edits, `.claude/` project dirs, token refreshes in
`anthropic-config` — is owned by you, so cleanup never needs sudo),
re-exports with `exportfs -ra`, ensures `nfs-server` is running, prunes entries
whose host directory no longer exists, and — if firewalld is active — allows NFS
(2049/tcp) from that guest's address in the TAP's zone. On Fedora with SELinux
enforcing, exporting a directory under `/home` also enables the
`nfs_home_dirs` boolean. Guest side it mounts `172.16.0.1:<hostdir>` over SSH.

**Each export is scoped to one VM** (`172.16.0.2/32`), not to the
`172.16.0.0/24` range. A subnet-wide export would let any VM mount every other
VM's shares — including `anthropic-config/` and its live refresh tokens. Sharing
one directory with several VMs is still supported and gets one client entry per
VM on the same export line, which is how NFS expresses it:

```
/home/you/project 172.16.0.2/32(rw,...,fsid=100000) 172.16.0.6/32(rw,...,fsid=100000)
```

An entry written by an older `share-dir.sh` (subnet-wide, or `no_root_squash`)
is narrowed in place the next time you share that directory, with a notice —
other VMs already using it must re-run `share-dir.sh` to get their own entry.
If you have files created during earlier `no_root_squash` sessions, fix them once
with `sudo chown -R $USER: <dir>`.

Host directory paths must not contain whitespace, quotes or `#`: `/etc/exports`
has no quoting, so a path with a space would silently export its *parent*.
`share-dir.sh` refuses rather than over-sharing.

`--unmount` tears down both sides, and drops that guest's firewalld rule once
nothing is exported to it any more. Neither side needs to still exist: if the
guest is already unreachable (stopped or crashed), it retires the host side
alone — an unreachable guest holds no mount, but its export entry and rich
rule would otherwise linger with no script path left to remove them — and the
host directory may likewise have been deleted, since for `--unmount` it is only
a lookup key into the exports file. `nfs-server` stays enabled (shared by all
VMs). NFS is stateless, so `stop-vm.sh` needs no changes — a guest with mounted
NFS shares simply keeps working after a host NFS restart.

Caveat: inotify doesn't cross NFS — irrelevant for Claude Code (it inspects
files via bash commands), but don't expect host-side file-watchers to see
guest-side writes.

## Caveats inside the guest

**No git in the guest, so Claude Code's rewind is limited inside the microVM.**
The agent image deliberately ships without git (smaller image, less to install;
the guest is a disposable sandbox). The cost: Claude Code's rewind / checkpoint
capability relies on git to snapshot and restore file state, so without it you
can't reliably rewind to a previous point in a session — treat edits as one-way
inside the VM (or undo them by asking Claude to revert the specific changes). It
also means git commands simply don't work in the guest (`status`/`commit`/`log`
against the shared workspace fail) — do repo operations on the host.

**No separate ripgrep either — Claude Code ships its own.** The `agent` step used
to install a static `rg` into `/usr/bin`. It doesn't any more: Claude Code's
`Grep` tool uses a ripgrep bundled inside its own binary (`USE_BUILTIN_RIPGREP=0`
opts out and falls back to a system `rg`), so the separate copy was never what
the tool actually ran. Dropping it removes a download and ~5 MB from the image.
If you want `rg` on `PATH` for your own shell commands inside the guest, add it
back via the same pattern the step uses for other binaries. Re-running
`./update-firecracker.sh agent` removes `/usr/bin/rg` from images built by an
earlier version.

**No working package manager in the guest — package installation is build-time
only.** The `agent` step installs its packages (`nfs-common`, etc.) inside the
chroot on the host, then strips everything that makes apt functional —
`/etc/apt` (sources + keyrings), the apt lists, the dpkg database, apt/dpkg
logs and caches — before building the ext4. Like the upstream Firecracker CI
rootfs (whose build drops all of `/var` from the shipped tree and empties
resolv.conf, leaving apt as inert binaries), the running guest can neither
locate nor fetch any package: `apt-get install` fails with *Unable to locate
package*, and `apt-get update` has no sources to fetch. To ship git (or anything
else) in the guest, add it to `AGENT_APT_PKGS` in `update-firecracker.sh` and
re-run `./update-firecracker.sh agent` — there is deliberately no way to
install packages at runtime.
