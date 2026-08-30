# firecracker-scripts

Opinionated wrapper scripts for running [Firecracker](https://github.com/firecracker-microvm/firecracker) microVMs with networking, SSH access, and easy updates — the minimal tooling for running agent sessions (or any headless workload) inside firecracker VMs on a Linux + KVM host.

Four scripts, no runtime dependencies beyond standard Linux tools:

| Script | What it does |
|---|---|
| `prereqs.sh` | Checks the host for KVM, TUN, `nft`, `jq`, etc. Run this first on a new machine. |
| `update-firecracker.sh` | Fetches/updates the `firecracker` binary and the guest kernel + Ubuntu rootfs. |
| `start-vm.sh` | Boots a networked microVM, prints the `ssh` command. Supports multiple concurrent VMs. |
| `stop-vm.sh` | Cleanly shuts a VM down and tears down its host networking. |

Everything the scripts download or build — kernels, rootfs images, the guest SSH key, logs — lives inside this repo directory and is gitignored. Nothing touches `~/.ssh` or personal keys.

## Prerequisites

- **Linux x86_64** with **KVM** (`/dev/kvm` readable+writable by you) and the **TUN** module (`/dev/net/tun`)
- **nftables** (`nft`) for guest NAT — the scripts use nftables, not iptables
- A few standard tools: `curl`, `jq`, `wget`, `ip`, `setsid`, `ping`, `tar`, `file`, `unsquashfs` (squashfs-tools), `mkfs.ext4` (e2fsprogs), `ssh-keygen`
- `sudo` for: installing the firecracker binary, creating TAP devices, NAT rules, and building the ext4 rootfs

Run the check:

```bash
./prereqs.sh
```

On a minimal Fedora, install the obvious gaps with:

```bash
sudo dnf install squashfs-tools e2fsprogs nftables jq wget
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

## Run a VM

```bash
# boot VM 0 (default) — creates TAP fc0, guest gets 172.16.0.2
./start-vm.sh

# ssh in
ssh -i guest.id_rsa root@172.16.0.2

# stop it
./stop-vm.sh
```

### Multiple concurrent VMs

Each VM id gets its own API socket, TAP device, and /30 subnet:

```bash
./start-vm.sh 0   # guest 172.16.0.2  (TAP fc0)
./start-vm.sh 1   # guest 172.16.0.6  (TAP fc1)
./start-vm.sh 2   # guest 172.16.0.10 (TAP fc2)
```

### How the guest IP is assigned (no DHCP needed)

The CI rootfs ships with a `fcnet-setup.sh` that derives the guest IP from the interface MAC: `06:00:ac:10:00:GG` → `172.16.0.GG`. `start-vm.sh` sets the MAC accordingly, so the guest auto-configures its address on boot with no DHCP server.

### Environment overrides

All paths are env-overridable for testing or non-default layouts:

```bash
FC_DIR=/some/other/dir ./start-vm.sh
BIN_INSTALL_DIR=~/.local/bin ./update-firecracker.sh binary
API_SOCKET=/run/fc-vm0.sock ./start-vm.sh
KERNEL=/path/to/vmlinux ROOTFS=/path/to/rootfs.ext4 SSH_KEY=/path/to/key ./start-vm.sh
```

## Layout

```
firecracker-scripts/
├── prereqs.sh
├── update-firecracker.sh
├── start-vm.sh
├── stop-vm.sh
├── README.md
└── .gitignore
```

After `./update-firecracker.sh`, the repo directory also contains (all gitignored):

```
vmlinux-<version>          # guest kernel
ubuntu-<version>.ext4      # guest rootfs (with guest.id_rsa.pub in authorized_keys)
ubuntu-<version>.squashfs.upstream
guest.id_rsa / .pub        # dedicated SSH keypair (gitignored)
vmlinux-latest             # -> vmlinux-<version>
ubuntu-latest.ext4         # -> ubuntu-<version>.ext4
ubuntu-latest.id_rsa       # -> guest.id_rsa
fc-vm*.log                 # per-VM serial console logs
```

## Notes

- The firecracker binary is installed to `/usr/local/bin/firecracker-<tag>-<arch>` with a stable `firecracker` symlink pointing at it.
- Firecracker's serial console goes to `fc-vm<ID>.log` — `tail -f` it to watch boot. For interactive access, use SSH (the scripts launch firecracker detached with stdin from `/dev/null`, so the serial console is read-only by design).
- Networking uses a hardcoded `172.16.0.0/24` range. Each VM's `/30` subnet and TAP name are derived from `VM_ID` inside `start-vm.sh` (`GUEST_IP`, `HOST_IP`, `TAP`, and the MAC are computed, not env-overridable). If the `172.16.0.0/24` range collides with another network on your host, edit the derivation in `start-vm.sh`.
