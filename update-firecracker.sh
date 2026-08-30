#!/usr/bin/env bash
# update-firecracker.sh — fetch/update the Firecracker binary + guest kernel + rootfs.
#
# Usage:
#   ./update-firecracker.sh binary     # update the firecracker binary from GitHub Releases
#   ./update-firecracker.sh images     # update the guest kernel + Ubuntu rootfs from the CI S3 bucket
#   ./update-firecracker.sh all        # do both (default)
#   ./update-firecracker.sh images --force   # rebuild the rootfs even if versions match
#
# The binary update installs to /usr/local/bin and needs sudo.
# The image update writes to this repo's dir and needs sudo for mkfs.ext4/chown.
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
  rm -rf "$FC_DIR/squashfs-root"
  (cd "$FC_DIR" && unsquashfs "ubuntu-$ubuntu_version.squashfs.upstream" >/dev/null)

  # Use the dedicated guest keypair (generated if missing). Never touches ~/.ssh.
  ensure_guest_key
  mkdir -p "$FC_DIR/squashfs-root/root/.ssh"
  cp "$SSH_KEY.pub" "$FC_DIR/squashfs-root/root/.ssh/authorized_keys"

  sudo chown -R root:root "$FC_DIR/squashfs-root"
  local ext4="$FC_DIR/ubuntu-$ubuntu_version.ext4"
  rm -f "$ext4"
  truncate -s 1G "$ext4"
  sudo mkfs.ext4 -q -d "$FC_DIR/squashfs-root" -F "$ext4"

  # Convenience symlinks so start-vm.sh defaults track the latest versions
  # without the caller needing to know the exact version numbers.
  ln -sfn "vmlinux-$latest_kernel_ver" "$FC_DIR/vmlinux-latest"
  ln -sfn "ubuntu-$ubuntu_version.ext4" "$FC_DIR/ubuntu-latest.ext4"
  ln -sfn "ubuntu-$ubuntu_version.id_rsa" "$FC_DIR/ubuntu-latest.id_rsa"
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
  all)     update_binary; update_images ;;
  *)
    echo "usage: $0 {binary|images|all} [--force]" >&2
    exit 2
    ;;
esac

echo
echo "==> update-firecracker.sh: done"
