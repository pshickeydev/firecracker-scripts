#!/usr/bin/env bash
# update-firecracker.sh — fetch/update the Firecracker binary + guest kernel + rootfs.
#
# Usage:
#   ./update-firecracker.sh binary     # update the firecracker binary from GitHub Releases
#   ./update-firecracker.sh images     # update the guest kernel + Ubuntu rootfs from the CI S3 bucket
#   ./update-firecracker.sh agent       # turn the extracted rootfs into an agent image
#                                      # (DNS fix, git/rg/nfs-common, Claude Code, 2 GiB ext4)
#   ./update-firecracker.sh all        # binary + images (default)
#   ./update-firecracker.sh images --force   # rebuild the rootfs even if versions match
#
# The binary update installs to /usr/local/bin and needs sudo.
# The image update writes to this repo's dir and needs sudo for mkfs.ext4/chown.
# The agent step chroots into the extracted rootfs and needs sudo for mounts/chroot.
#
# Images, keys, and logs are all kept inside FC_DIR (this repo) and are
# .gitignored — nothing here touches ~/.ssh or personal keys.

set -euo pipefail

# Default FC_DIR to this script's directory so the repo is self-contained.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
ARCH="$(uname -m)"
BIN_INSTALL_DIR="${BIN_INSTALL_DIR:-/usr/local/bin}"
S3="https://s3.amazonaws.com/spec.ccfc.min"
GITHUB_RELEASES="https://github.com/firecracker-microvm/firecracker/releases"
# A dedicated SSH keypair lives inside FC_DIR (gitignored). It is NOT a personal
# key — it only authenticates into the firecracker guest rootfs we build here.
SSH_KEY="$FC_DIR/guest.id_rsa"
FORCE=0

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need curl; need jq; need wget; need unsquashfs; need mkfs.ext4; need ssh-keygen; need tar; need file; need grep

# --- helpers ----------------------------------------------------------------

installed_binary_version() {
  # e.g. "v1.16.1"; empty if not installed
  "${BIN_INSTALL_DIR}/firecracker" --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || true
}

latest_binary_version() {
  # follow the /releases/latest redirect to get the tag name
  basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "${GITHUB_RELEASES}/latest")"
}

installed_kernel_version() {
  # e.g. "6.18.44"; empty if none. Resolves the vmlinux-latest symlink first.
  local p="$FC_DIR/vmlinux-latest"
  [ -L "$p" ] && p="$(readlink -f "$p")"
  [ -f "$p" ] || p="$(ls "$FC_DIR"/vmlinux-* 2>/dev/null | grep -v latest | tail -1)"
  [ -n "$p" ] && basename "$p" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
}

# Resolve the latest dated CI build prefix, e.g. firecracker-ci/20260826-xxxx-0/
latest_ci_prefix() {
  curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
    | grep -oP '(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)' \
    | sort | tail -1
}

latest_kernel_key() { # echo the S3 key for the newest vmlinux
  local prefix="$1"
  curl -fsSL "$S3?list-type=2&prefix=${prefix}${ARCH}/vmlinux-" \
    | grep -oP "(?<=<Key>)(${prefix}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V | tail -1
}

latest_ubuntu_key() { # echo the S3 key for the newest ubuntu rootfs
  local prefix="$1"
  curl -fsSL "$S3?list-type=2&prefix=${prefix}${ARCH}/ubuntu-" \
    | grep -oP "(?<=<Key>)(${prefix}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
    | sort -V | tail -1
}

ensure_guest_key() {
  # Generate a dedicated SSH keypair in FC_DIR if one doesn't exist.
  # This key is gitignored and only used to log into the guest rootfs we build.
  if [ ! -f "$SSH_KEY" ]; then
    echo "==> Generating dedicated guest SSH keypair at $SSH_KEY"
    ssh-keygen -q -f "$SSH_KEY" -N "" -C "firecracker-guest"
    chmod 600 "$SSH_KEY"
  fi
}

# --- agent subcommand ---------------------------------------------------------
# Turns squashfs-root/ (from the `images` step) into an image ready for agent
# sessions: working DNS, git + nfs-common via apt, a static ripgrep binary, the
# stable Claude Code binary, and a 2 GiB rootfs so guest-side installs have
# headroom.
AGENT_APT_PKGS=(git nfs-common)
AGENT_ROOT=""  # global: the EXIT trap below must not reference locals

agent_umount_binds() {
  # Drop any /proc /dev /sys bind-mounts left in the guest tree (a previous
  # crashed run counts too: they would leak the host's /proc into the image).
  [ -n "$AGENT_ROOT" ] && [ -d "$AGENT_ROOT" ] || return 0
  sudo umount "$AGENT_ROOT/proc" 2>/dev/null || true
  sudo umount "$AGENT_ROOT/dev"  2>/dev/null || true
  sudo umount "$AGENT_ROOT/sys"  2>/dev/null || true
}

update_agent() {
  local root="$FC_DIR/squashfs-root"
  [ -d "$root" ] || { echo "no squashfs-root in $FC_DIR — run './update-firecracker.sh images' first" >&2; exit 1; }
  AGENT_ROOT="$root"
  trap agent_umount_binds EXIT

  local version ext4
  version="$(grep -oP '(?<=VERSION_ID=\")[0-9.]+' "$root/etc/os-release" 2>/dev/null || true)"
  [ -n "$version" ] || version="24.04"
  ext4="$FC_DIR/ubuntu-$version.ext4"

  # Outbound internet: the CI fcnet-setup.sh assigns the /30 address from the
  # MAC but installs NO default route, so the guest can only reach the host.
  # Append a route step: gateway = the /30's host end (guest IP with the last
  # octet decremented), matching start-vm.sh's VM_ID convention (guest .2 of
  # each /30, host .1).
  echo "==> agent: patching fcnet-setup.sh to add a default route (CI image ships none)"
  if ! sudo grep -q 'set_default_route' "$root/usr/local/bin/fcnet-setup.sh"; then
    sudo tee -a "$root/usr/local/bin/fcnet-setup.sh" >/dev/null <<'FCNET'

# --- appended by update-firecracker.sh (agent step) -----------------------
# CI image ships no default route: without one the guest can't reach DNS or
# the internet (only the host on its /30). Gateway = the /30's host end,
# i.e. this device's IP with the last octet decremented.
set_default_route() {
    devs=$(ls /sys/class/net | grep -v lo)
    for dev in $devs; do
        mac_ip=$(ip link show dev $dev \
            | grep link/ether \
            | grep -Po "(?<=06:00:)([0-9a-f]{2}:?){4}")
        [ -n "$mac_ip" ] || continue
        ip=$(printf "%d.%d.%d.%d" $(echo "0x${mac_ip}" | sed "s/:/ 0x/g"))
        ip route replace default via "${ip%.*}.$((${ip##*.} - 1))" dev "$dev"
    done
}
set_default_route
FCNET
  fi

  # 1. DNS: the CI rootfs ships an EMPTY /etc/resolv.conf — nothing resolves
  #    in the guest (apt, installers, API calls) until this is fixed.
  echo "==> agent: writing guest /etc/resolv.conf (was empty)"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee "$root/etc/resolv.conf" >/dev/null

  # /tmp modes: unsquashfs does not preserve the 1777 sticky bit (it extracts as
  # 755) and /var/tmp is missing entirely — apt can't create temp files without
  # these, and the running guest needs a proper /tmp anyway.
  # Same story for apt's own (empty) work dirs, which the CI image pruned.
  echo "==> agent: fixing /tmp permissions + apt work dirs (unsquashfs prunes these)"
  sudo install -d -m 1777 "$root/tmp" "$root/var/tmp"
  sudo install -d "$root/var/cache/apt/archives/partial" "$root/var/lib/apt/lists/partial"

  # The CI rootfs is heavily pruned: no /var/log, no /var/cache, and NO dpkg
  # status database (only lock files). apt therefore treats the image as empty
  # and resolves the full dependency closure (~100 core packages) for the three
  # packages we ask for, unpacking them over the existing tree. Fine for a
  # disposable image — dpkg just needs its dirs + an empty (valid) status file.
  echo "==> agent: creating dpkg work dirs + empty status db (CI image ships none)"
  sudo install -d "$root/var/log" "$root/var/log/apt"
  sudo install -d "$root/var/lib/dpkg/info" "$root/var/lib/dpkg/updates" "$root/var/lib/dpkg/triggers"
  sudo test -f "$root/var/lib/dpkg/status" || sudo touch "$root/var/lib/dpkg/status"

  # 2. chroot: host x86_64 -> guest x86_64, plain chroot works. Bind the
  #    kernel filesystems; apt and the claude installer both expect them.
  echo "==> agent: chroot apt-get update + install: ${AGENT_APT_PKGS[*]}"
  agent_umount_binds
  sudo mount --bind /proc "$root/proc"
  sudo mount --bind /dev  "$root/dev"
  sudo mount --bind /sys  "$root/sys"

  # Run commands in the guest tree with a clean root env. env -u SUDO_*:
  # `sudo chroot` leaks SUDO_USER et al., and the claude installer refuses to
  # run as root when it thinks it's under sudo. HOME must be /root or the
  # installer lands in the (host) caller's home inside the guest tree.
  chroot_env() {
    sudo chroot "$root" env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND \
      HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      DEBIAN_FRONTEND=noninteractive "$@"
  }

  chroot_env apt-get update
  chroot_env apt-get install -y --no-install-recommends "${AGENT_APT_PKGS[@]}"
  # 3. Claude Code native installer (stable channel). It bundles its own
  #    runtime — the guest needs no Node.js.
  echo "==> agent: running the Claude Code native installer (stable) in the chroot"
  chroot_env bash -c 'curl -fsSL https://claude.ai/install.sh | bash -s stable'
  # claude's layout: ~/.local/bin/claude is a SYMLINK to
  # /root/.local/share/claude/versions/<v>. The symlink target is a
  # guest-absolute path, so it dangles when seen from the host tree — check the
  # versioned dir (the real ~300 MB binary) and the symlink, not `test -x`.
  sudo test -d "$root/root/.local/share/claude/versions" || {
    echo "claude not installed under $root/root/.local/share/claude/versions" >&2
    exit 1
  }
  sudo test -L "$root/root/.local/bin/claude" || {
    echo "claude launcher symlink missing: $root/root/.local/bin/claude" >&2
    exit 1
  }

  echo "==> agent: verifying the stable-channel pin + putting claude on PATH"
  # `claude install stable` writes {"autoUpdatesChannel":"stable"} itself;
  # only intervene if it's missing or wrong.
  sudo mkdir -p "$root/root/.claude"
  if ! sudo cat "$root/root/.claude/settings.json" 2>/dev/null \
       | jq -e '.autoUpdatesChannel == "stable"' >/dev/null; then
    local tmp; tmp="$(mktemp)"
    if sudo cat "$root/root/.claude/settings.json" 2>/dev/null \
         | jq '. + {autoUpdatesChannel:"stable"}' >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      sudo cp "$tmp" "$root/root/.claude/settings.json"
    else
      printf '{ "autoUpdatesChannel": "stable" }\n' | sudo tee "$root/root/.claude/settings.json" >/dev/null
    fi
    rm -f "$tmp"
  fi
  # Non-interactive ssh shells skip ~/.bashrc, so symlink claude onto the
  # default PATH (matters for share-dir.sh and one-shot ssh commands).
  sudo ln -sfn /root/.local/bin/claude "$root/usr/local/bin/claude"

  # 4. ripgrep: static musl binary fetched by the host — deliberately NOT via
  #    apt, so the only thing pulling packages is what has no static build
  #    (git, mount.nfs).
  echo "==> agent: installing ripgrep (static musl build)"
  local rgver rgdir
  rgver="$(curl -fsSL https://api.github.com/repos/BurntSushi/ripgrep/releases/latest | jq -r '.tag_name')"
  rgdir="$(mktemp -d)"
  curl -fsSL -o "$rgdir/rg.tgz" \
    "https://github.com/BurntSushi/ripgrep/releases/download/$rgver/ripgrep-$rgver-x86_64-unknown-linux-musl.tar.gz"
  tar -xzf "$rgdir/rg.tgz" -C "$rgdir"
  sudo install -m 755 "$rgdir/ripgrep-$rgver-x86_64-unknown-linux-musl/rg" "$root/usr/bin/rg"
  rm -rf "$rgdir"
  echo "    rg $rgver -> /usr/bin/rg"

  # 5. The binds MUST come off before mkfs.ext4 -d, or the host's /proc ends
  #    up inside the image we build next.
  agent_umount_binds
  trap - EXIT

  # 6. Rebuild the ext4, grown from 1 GiB to 2 GiB for guest-side installs.
  #    NOTE: this discards any state in the previous ext4 (e.g. packages
  #    installed over SSH) — by design, to keep rebuilds reproducible.
  #    Refuse to rewrite the image under a running VM (mkfs on a live backing
  #    file corrupts the guest).
  if command -v fuser >/dev/null 2>&1 && fuser -s "$ext4" 2>/dev/null; then
    echo "refusing: $ext4 is in use (a VM is running off it) — ./stop-vm.sh first" >&2
    exit 1
  fi
  echo "==> agent: rebuilding $ext4 (2 GiB)"
  rm -f "$ext4"
  truncate -s 2G "$ext4"
  sudo mkfs.ext4 -q -d "$root" -F "$ext4"
  ln -sfn "ubuntu-$version.ext4" "$FC_DIR/ubuntu-latest.ext4"

  echo "==> agent: done — guest image ready:"
  ls -la "$FC_DIR/ubuntu-latest.ext4"
}

# --- subcommands ------------------------------------------------------------

update_binary() {
  echo "==> Checking firecracker binary..."
  local current latest
  current="$(installed_binary_version)"
  latest="$(latest_binary_version)"
  echo "    installed: ${current:-<none>}"
  echo "    latest:    $latest"
  if [ -n "$current" ] && [ "$current" = "$latest" ] && [ "$FORCE" = 0 ]; then
    echo "    already up to date; skipping (use --force to reinstall)"
    return 0
  fi

  local tmpdir; tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  local tgz="$tmpdir/firecracker-${latest}-${ARCH}.tgz"
  echo "==> Downloading firecracker-${latest}-${ARCH}.tgz"
  curl -fSL -o "$tgz" "${GITHUB_RELEASES}/download/${latest}/firecracker-${latest}-${ARCH}.tgz"
  tar -xzf "$tgz" -C "$tmpdir"

  local src="$tmpdir/release-${latest}-${ARCH}/firecracker-${latest}-${ARCH}"
  [ -f "$src" ] || { echo "binary not found in archive: $src" >&2; exit 1; }

  echo "==> Installing to ${BIN_INSTALL_DIR}/ (needs sudo)"
  # Install under a versioned name so multiple versions can coexist (rollback),
  # and point the stable 'firecracker' name at it. We do NOT touch any
  # pre-existing firecracker-v symlink here — that's managed separately.
  sudo install -m755 "$src" "${BIN_INSTALL_DIR}/firecracker-${latest}-${ARCH}"
  sudo ln -sfn "firecracker-${latest}-${ARCH}" "${BIN_INSTALL_DIR}/firecracker"

  echo "==> Installed:"
  "${BIN_INSTALL_DIR}/firecracker" --version
  echo "    (versioned binary: firecracker-${latest}-${ARCH})"
}

update_images() {
  echo "==> Checking guest kernel + rootfs..."
  local prefix kernel_key ubuntu_key ubuntu_version
  prefix="$(latest_ci_prefix)"
  [ -n "$prefix" ] || { echo "could not list CI bucket" >&2; exit 1; }
  echo "    latest CI build: $prefix"

  kernel_key="$(latest_kernel_key "$prefix")"
  ubuntu_key="$(latest_ubuntu_key "$prefix")"
  [ -n "$kernel_key" ] || { echo "no kernel found in CI bucket" >&2; exit 1; }
  [ -n "$ubuntu_key" ] || { echo "no ubuntu rootfs found in CI bucket" >&2; exit 1; }
  ubuntu_version="$(basename "$ubuntu_key" .squashfs | grep -oE '[0-9]+\.[0-9]+')"

  local latest_kernel_ver; latest_kernel_ver="$(echo "$kernel_key" | grep -oE 'vmlinux-[0-9]+\.[0-9]+\.[0-9]+' | cut -d- -f2)"
  local current_kernel; current_kernel="$(installed_kernel_version)"
  echo "    kernel:    ${current_kernel:-<none>} -> $latest_kernel_ver"
  echo "    rootfs:   ubuntu-$ubuntu_version"

  if [ -n "$current_kernel" ] && [ "$current_kernel" = "$latest_kernel_ver" ] && [ "$FORCE" = 0 ]; then
    echo "    kernel already up to date; skipping images (use --force to rebuild)"
    return 0
  fi

  mkdir -p "$FC_DIR"

  echo "==> Downloading kernel ($kernel_key)"
  wget -q -O "$FC_DIR/vmlinux-$latest_kernel_ver" "$S3/$kernel_key"
  file "$FC_DIR/vmlinux-$latest_kernel_ver"

  echo "==> Downloading rootfs ($ubuntu_key)"
  wget -q -O "$FC_DIR/ubuntu-$ubuntu_version.squashfs.upstream" "$S3/$ubuntu_key"

  echo "==> Unsquashing + patching SSH key + building ext4"
  # The previous run chowned squashfs-root to root:root (for mkfs.ext4 -d), so a
  # user-level rm can't delete it. Use sudo to clear it.
  sudo rm -rf "$FC_DIR/squashfs-root"
  (cd "$FC_DIR" && unsquashfs "ubuntu-$ubuntu_version.squashfs.upstream" >/dev/null)

  # Use the dedicated guest keypair (generated if missing). Never touches ~/.ssh.
  ensure_guest_key
  mkdir -p "$FC_DIR/squashfs-root/root/.ssh"
  cp "$SSH_KEY.pub" "$FC_DIR/squashfs-root/root/.ssh/authorized_keys"

  sudo chown -R root:root "$FC_DIR/squashfs-root"
  local ext4="$FC_DIR/ubuntu-$ubuntu_version.ext4"
  # Refuse to rewrite the image under a running VM (same guard as the agent step).
  if command -v fuser >/dev/null 2>&1 && fuser -s "$ext4" 2>/dev/null; then
    echo "refusing: $ext4 is in use (a VM is running off it) — ./stop-vm.sh first" >&2
    exit 1
  fi
  rm -f "$ext4"
  truncate -s 1G "$ext4"
  sudo mkfs.ext4 -q -d "$FC_DIR/squashfs-root" -F "$ext4"

  # Convenience symlinks so start-vm.sh defaults track the latest versions
  # without the caller needing to know the exact version numbers.
  ln -sfn "vmlinux-$latest_kernel_ver" "$FC_DIR/vmlinux-latest"
  ln -sfn "ubuntu-$ubuntu_version.ext4" "$FC_DIR/ubuntu-latest.ext4"
  # guest.id_rsa is the canonical key name; ubuntu-latest.id_rsa points at it
  # for compatibility with older start-vm.sh defaults.
  ln -sfn "guest.id_rsa" "$FC_DIR/ubuntu-latest.id_rsa"

  echo "==> Images ready:"
  ls -la "$FC_DIR/vmlinux-latest" "$FC_DIR/ubuntu-latest.ext4" "$FC_DIR/ubuntu-latest.id_rsa"
}

# --- arg parse --------------------------------------------------------------

ACTION="${1:-all}"
# allow --force anywhere in the arg list
for a in "$@"; do [ "$a" = "--force" ] && FORCE=1; done
# strip --force from ACTION if it was the first arg
[ "$ACTION" = "--force" ] && ACTION="all"

case "$ACTION" in
  binary)  update_binary ;;
  images)  update_images ;;
  agent)   update_agent ;;
  all)     update_binary; update_images ;;
  *)
    echo "usage: $0 {binary|images|agent|all} [--force]" >&2
    exit 2
    ;;
esac

echo
echo "==> update-firecracker.sh: done"
