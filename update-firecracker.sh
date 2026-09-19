#!/usr/bin/env bash
# update-firecracker.sh — fetch/update the Firecracker binary + guest kernel + rootfs.
#
# Usage:
#   ./update-firecracker.sh binary     # update the firecracker binary from GitHub Releases
#   ./update-firecracker.sh images     # update the guest kernel + Ubuntu rootfs from the CI S3 bucket
#   ./update-firecracker.sh agent       # turn the extracted rootfs into an agent image
#                                      # (DNS fix, nfs-common, Claude Code, 2 GiB ext4,
#                                      #  apt state stripped — no working package manager
#                                      #  in the running guest)
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
need sha256sum

# --- integrity ---------------------------------------------------------------
#
# Everything this script installs into the guest — and the VMM itself — arrives
# over the network. Two different situations, handled differently:
#
#  * The Firecracker release publishes a .sha256 next to each artifact.
#    Those are fetched and checked, and a mismatch is fatal.
#
#  * The Firecracker CI kernel/rootfs and the Claude Code installer publish no
#    checksums at all, so there is nothing to verify against on a first fetch.
#    Their hashes are instead recorded in image-pins.lock (committed) and
#    checked on every later run. That does not protect the first fetch, but it
#    does catch an artifact changing underneath a fixed name afterwards, and it
#    makes the trust assumption visible in the repo instead of implicit.
PINS_FILE="${PINS_FILE:-$FC_DIR/image-pins.lock}"

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

verify_sha256() { # <file> <sha256-url> <label>
  local expected got
  expected="$(curl -fsSL "$2" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$expected" ]; then
    if [ "${ALLOW_UNVERIFIED:-0}" = 1 ]; then
      echo "    !! no published checksum for $3 — proceeding (ALLOW_UNVERIFIED=1)" >&2
      return 0
    fi
    echo "no published checksum found for $3 ($2)" >&2
    echo "refusing to install an unverified binary; set ALLOW_UNVERIFIED=1 to override" >&2
    exit 1
  fi
  got="$(sha256_of "$1")"
  if [ "$got" != "$expected" ]; then
    echo "CHECKSUM MISMATCH for $3" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $got" >&2
    exit 1
  fi
  echo "    sha256 verified against upstream: $3"
}

pin_lookup() { # <key> -> recorded hash, or empty
  [ -f "$PINS_FILE" ] || return 0
  awk -v k="$1" '$2==k {print $1; exit}' "$PINS_FILE"
}

pin_record() { # <key> <hash>
  local tmp; tmp="$(mktemp)"
  [ -f "$PINS_FILE" ] && awk -v k="$1" '$2!=k' "$PINS_FILE" >"$tmp"
  printf '%s  %s\n' "$2" "$1" >>"$tmp"
  sort -k2 "$tmp" -o "$tmp"
  mv "$tmp" "$PINS_FILE"
}

pin_check() { # <file> <key> <strict|warn>
  local got expected
  got="$(sha256_of "$1")"
  expected="$(pin_lookup "$2")"
  if [ -z "$expected" ]; then
    pin_record "$2" "$got"
    echo "    pinned on first fetch: $2"
    echo "      sha256 $got  (commit image-pins.lock to hold it)"
    return 0
  fi
  if [ "$got" = "$expected" ]; then
    echo "    sha256 matches the pin: $2"
    return 0
  fi
  if [ "$3" = strict ] || [ "${STRICT_PINS:-0}" = 1 ]; then
    echo "PIN MISMATCH for $2" >&2
    echo "  pinned: $expected" >&2
    echo "  actual: $got" >&2
    echo "This artifact is published under a fixed name and should never change." >&2
    echo "Investigate before proceeding; delete its line from $PINS_FILE to re-pin." >&2
    exit 1
  fi
  echo "!!  CONTENT CHANGED since it was pinned: $2" >&2
  echo "      pinned: $expected" >&2
  echo "      actual: $got" >&2
  echo "    This one is expected to change over time, so the new hash is being" >&2
  echo "    recorded and the build continues. Use STRICT_PINS=1 to make it fatal." >&2
  pin_record "$2" "$got"
}

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
# sessions: working DNS, nfs-common via apt, the stable Claude Code binary, and
# a 2 GiB rootfs so Claude Code's versioned self-updates have headroom.
# Deliberately NO git in the guest — this limits Claude Code's rewind capability
# inside the microVM (documented in the README). Also no ripgrep: Claude Code
# ships its own and uses it for the Grep tool, so a separate rg was redundant.
#
# Package installation is build-time ONLY: after installing, all apt/dpkg state
# is stripped from the shipped image (upstream-style appliance — see the strip
# step below), so the running guest has no working package manager. To add a
# package, put it in AGENT_APT_PKGS and re-run this step.
# busybox-static is build-time only: copied into the initrd, then stripped
# from the shipped rootfs so the guest gains no multi-call shell.
AGENT_APT_PKGS=(nfs-common busybox-static)
AGENT_ROOT=""    # global: the EXIT trap below must not reference locals
AGENT_STAGE=""   # global: staged hardlink copy the ext4 is built from

# A layer (or copy) only means anything against the base it was created over.
# Rebuilding does not delete them (they hold session state), so warn about
# stale ones — like the .known_hosts reset does for host keys.
warn_stale_layers() {
  local f
  local -a stale=()
  # One glob: vm[0-9]*.ext4 already covers vm0-layer.ext4 as well as vm0.ext4.
  for f in "$FC_DIR"/vm[0-9]*.ext4; do
    [ -e "$f" ] || continue
    stale+=("$(basename "$f")")
  done
  [ "${#stale[@]}" -gt 0 ] || return 0
  echo
  echo "==> NOTE: these per-VM images predate the base image just built:"
  printf '      %s\n' "${stale[@]}"
  echo "    They overlay (or copy) the OLD base. Start those VMs with RESET_LAYER=1,"
  echo "    or delete the files — after copying out anything worth keeping. A VM's"
  echo "    journal lives in its layer, under upper/var/log/journal."
}

# --- overlay-root initrd ------------------------------------------------------
# ROOTFS_MODE=overlay attaches the shared base read-only plus a per-VM writable
# layer. Assembling a root from two devices has to happen before init, which is
# what an initramfs is for: a gzipped cpio holding one static busybox (deleted
# from the shipped rootfs) and the /init below.
build_overlay_initrd() { # <tree-containing-busybox> <out.img>
  local tree="$1" out="$2" bb="" cand stage applets missing=""
  need cpio; need gzip
  for cand in usr/bin/busybox bin/busybox usr/sbin/busybox sbin/busybox; do
    if sudo test -x "$tree/$cand"; then bb="$tree/$cand"; break; fi
  done
  [ -n "$bb" ] || {
    echo "busybox not found under $tree — is busybox-static in AGENT_APT_PKGS?" >&2
    exit 1
  }

  stage="$(mktemp -d)"
  mkdir -p "$stage"/bin "$stage"/proc "$stage"/sys "$stage"/dev \
           "$stage"/base "$stage"/layer "$stage"/newroot
  sudo cp "$bb" "$stage/bin/busybox"
  sudo chown -R "$(id -u):$(id -g)" "$stage"
  chmod 755 "$stage/bin/busybox"

  # Verify the applets /init needs are compiled in before shipping an image
  # that cannot boot (switch_root missing = hang in the initramfs every time).
  applets="$("$stage/bin/busybox" --list 2>/dev/null || true)"
  for cand in sh mount umount mkdir cat sleep switch_root; do
    printf '%s\n' "$applets" | grep -qx "$cand" || missing="$missing $cand"
  done
  [ -z "$missing" ] || {
    rm -rf "$stage"
    echo "the image's busybox lacks applets needed by the overlay initrd:$missing" >&2
    exit 1
  }
  printf '%s\n' "$applets" | grep -qx findfs \
    || echo "    note: this busybox has no findfs — /init falls back to /dev/vdb for the layer"

  cat >"$stage/init" <<'INIT'
#!/bin/busybox sh
# /init — assemble the guest root from the read-only base (/dev/vda) plus this
# VM's writable layer (/dev/vdb), then switch_root to systemd. Must run as PID 1
# from an initramfs: / cannot be pivoted onto an overlay once systemd started.

BB=/bin/busybox

log() { echo "initrd: $*"; }

# Park the VM on failure rather than panicking: panic=1 would reboot in a
# loop and scroll the reason off the serial log.
fail() {
    log "FATAL: $*"
    log "hint: the base is mounted read-only, and a read-only mount cannot"
    log "      replay an ext4 journal — 'e2fsck -fy <base>.ext4' on the host"
    log "      with every VM stopped is the usual fix."
    log "this VM is parked; stop it with ./stop-vm.sh <id>"
    while :; do $BB sleep 60; done
}

# Get a mount out of the initramfs tree. Try both spellings of move (`-o move`
# is busybox's); a lazy detach is equally fine — overlayfs keeps its own
# reference to both layers.
relocate() { # <from> <to>
    $BB mount -o move "$1" "$2" 2>/dev/null && return 0
    $BB mount --move  "$1" "$2" 2>/dev/null && return 0
    if $BB umount -l "$1" 2>/dev/null; then
        log "note: $1 was lazily detached instead of moved to $2"
        return 0
    fi
    log "warning: $1 stayed in the initramfs tree; switch_root skips mount"
    log "         points when it clears the old root, so this is untidy, not fatal"
    return 0
}

$BB mkdir -p /proc /sys /dev /base /layer /newroot
$BB mount -t proc     proc     /proc 2>/dev/null
$BB mount -t sysfs    sysfs    /sys  2>/dev/null
$BB mount -t devtmpfs devtmpfs /dev  2>/dev/null

# The layer is found by LABEL (not device order); /dev/vdb is a sound fallback
# since the base is always added first.
LAYER="$($BB findfs LABEL=fc-layer 2>/dev/null)"
[ -n "$LAYER" ] || LAYER=/dev/vdb

# The base is whatever firecracker named as the root device.
BASE=/dev/vda
for arg in $($BB cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        root=*) BASE="${arg#root=}" ;;
    esac
done
case "$BASE" in
    LABEL=*|UUID=*) BASE="$($BB findfs "$BASE" 2>/dev/null)" ;;
esac
[ -n "$BASE" ] || BASE=/dev/vda
[ "$BASE" != "$LAYER" ] || fail "base and layer are the same device ($BASE)"

log "base=$BASE (read-only)  layer=$LAYER (read-write)"
$BB mount -t ext4 -o ro "$BASE" /base || fail "could not mount $BASE read-only"
# Deliberately no nosuid/noexec: this becomes the guest's /, and the image
# ships a suid mount.nfs that share-dir.sh depends on.
$BB mount -t ext4 "$LAYER" /layer || fail "could not mount $LAYER read-write"

$BB mkdir -p /layer/upper /layer/work
$BB mount -t overlay overlay \
    -o lowerdir=/base,upperdir=/layer/upper,workdir=/layer/work /newroot \
    || fail "could not assemble the overlay root"

[ -x /newroot/sbin/init ] || fail "no /sbin/init in the assembled root"

# overlayfs pins both layers, so relocate them into the new root (/mnt/fc-base
# also exposes the pristine base from inside the guest). Never fatal.
$BB mkdir -p /newroot/mnt/fc-base /newroot/mnt/fc-layer
relocate /base  /newroot/mnt/fc-base
relocate /layer /newroot/mnt/fc-layer

$BB umount /dev  2>/dev/null
$BB umount /sys  2>/dev/null
$BB umount /proc 2>/dev/null
exec $BB switch_root /newroot /sbin/init

# Only reached if exec failed; falling off the end would panic into a reboot
# loop.
fail "switch_root did not take — the assembled root is unusable"
INIT
  chmod 755 "$stage/init"

  # -R 0:0 so the archive says root owns everything regardless of who built it.
  ( cd "$stage" && find . -print0 \
      | cpio --null --create --format=newc -R 0:0 --quiet ) | gzip -9 >"$out"
  rm -rf "$stage"
  [ -s "$out" ] || { echo "failed to build $out" >&2; exit 1; }
  echo "==> agent: overlay initrd: $out ($(du -h "$out" | cut -f1))"
}

agent_umount_binds() {
  # Drop any /proc /dev /sys bind-mounts left in the guest tree (a previous
  # crashed run counts too: they would leak the host's /proc into the image).
  [ -n "$AGENT_ROOT" ] && [ -d "$AGENT_ROOT" ] || return 0
  sudo umount "$AGENT_ROOT/proc" 2>/dev/null || true
  sudo umount "$AGENT_ROOT/dev"  2>/dev/null || true
  sudo umount "$AGENT_ROOT/sys"  2>/dev/null || true
}

agent_cleanup() {
  agent_umount_binds
  [ -n "$AGENT_STAGE" ] && sudo rm -rf "$AGENT_STAGE" 2>/dev/null || true
}

update_agent() {
  local root="$FC_DIR/squashfs-root"
  [ -d "$root" ] || { echo "no squashfs-root in $FC_DIR — run './update-firecracker.sh images' first" >&2; exit 1; }
  AGENT_ROOT="$root"
  trap agent_cleanup EXIT

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
  # and resolves the full dependency closure (~100 core packages) for the few
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
  # Fetched to a file and hashed rather than piped straight into a shell, so
  # the exact script that ran is pinned in image-pins.lock and a change is
  # reported instead of passing through unseen. (It runs as root in the chroot,
  # which has the host's /dev and /proc bind-mounted — see THREAT-MODEL.md.)
  echo "==> agent: running the Claude Code native installer (stable) in the chroot"
  local inst; inst="$(mktemp)"
  curl -fsSL -o "$inst" https://claude.ai/install.sh
  pin_check "$inst" "https://claude.ai/install.sh" warn
  sudo install -m 755 "$inst" "$root/tmp/claude-install.sh"
  rm -f "$inst"
  chroot_env bash /tmp/claude-install.sh stable
  sudo rm -f "$root/tmp/claude-install.sh"
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

  # 4. Guest hardening. The guest is reached only across its point-to-point TAP
  #    using the repo's dedicated keypair, so nothing here costs us anything we
  #    use — it just removes surface that the CI rootfs leaves switched on.
  echo "==> agent: hardening the guest (sshd, root password, rpcbind)"
  #    sshd: the CI image allows password auth, and ships root with an EMPTY
  #    password field in /etc/shadow. Only PermitEmptyPasswords=no stands
  #    between that and a passwordless root login. Turn password auth off and
  #    lock the account; pubkey auth is unaffected by a locked password.
  sudo install -d -m 755 "$root/etc/ssh/sshd_config.d"
  sudo tee "$root/etc/ssh/sshd_config.d/10-fc-agents.conf" >/dev/null <<'SSHD'
# Written by update-firecracker.sh (agent step).
# The guest is reached over its /30 TAP with the repo's dedicated keypair only.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
  chroot_env passwd -l root >/dev/null 2>&1 \
    || sudo sed -i 's/^root::/root:!:/' "$root/etc/shadow"
  #    rpcbind: NFSv4 talks to port 2049 and nothing else, but installing
  #    nfs-common pulls rpcbind in and it listens on 0.0.0.0:111 (tcp+udp).
  #    Masking it is verified not to affect `mount -t nfs4`.
  sudo install -d -m 755 "$root/etc/systemd/system"
  sudo ln -sfn /dev/null "$root/etc/systemd/system/rpcbind.service"
  sudo ln -sfn /dev/null "$root/etc/systemd/system/rpcbind.socket"
  #    sysctls: modules_disabled was previously observed set at runtime by
  #    nothing in this repo — set it for real. Safe: the image ships no
  #    /lib/modules (everything the guest uses is built into the kernel).
  #    dmesg_restrict is correct the moment not everything runs as root.
  sudo install -d -m 755 "$root/etc/sysctl.d"
  sudo tee "$root/etc/sysctl.d/99-fc-agents-hardening.conf" >/dev/null <<'SYSCTL'
# Written by update-firecracker.sh. modules_disabled is one-way; this image
# ships no modules, so nothing is given up.
kernel.modules_disabled = 1
kernel.dmesg_restrict = 1
SYSCTL
  #    debugfs publishes kernel internals and is read by nothing here. Masking
  #    the unit beats debugfs=off, which would fail the mount and leave the
  #    guest degraded for the same nothing.
  sudo ln -sfn /dev/null "$root/etc/systemd/system/sys-kernel-debug.mount"
  #    Make the journal persistent: under overlay mode it lands in the VM's
  #    layer, which outlives the guest and is readable from the host.
  sudo install -d -m 755 "$root/etc/systemd/journald.conf.d"
  sudo tee "$root/etc/systemd/journald.conf.d/10-fc-agents.conf" >/dev/null <<'JOURNALD'
# Written by update-firecracker.sh (agent step).
[Journal]
Storage=persistent
SystemMaxUse=128M
JOURNALD
  #    Layer mountpoints for the overlay initrd (it mkdir's them as a fallback;
  #    the CI rootfs ships no /mnt at all).
  sudo install -d -m 755 "$root/mnt" "$root/mnt/fc-base" "$root/mnt/fc-layer"

  # 5. The binds MUST come off before mkfs.ext4 -d, or the host's /proc ends
  #    up inside the image we build next.
  agent_umount_binds

  # 6. Strip the package-manager state so the shipped image — like the
  #    upstream CI rootfs — has NO working apt. The chroot install above
  #    necessarily populates apt/dpkg state in the tree: ~51 MB of apt
  #    lists, a dpkg status database, and apt/dpkg logs and caches.
  #    Upstream's build (tools/functions in firecracker) sidesteps this by
  #    copying only bin/etc/home/lib/root/sbin/usr into the shipped tree
  #    (all of /var is dropped) and emptying resolv.conf, so its guests
  #    ship apt as inert binaries. We must keep DNS (Claude Code needs the
  #    API + the stable-channel auto-updater), so DNS alone can't be the
  #    kill switch: we remove everything that makes apt *functional* —
  #    /etc/apt (sources + keyrings: `apt-get update` fetches nothing,
  #    `apt-get install` can't locate any package), the apt lists, the
  #    dpkg database, and apt/dpkg logs and caches.
  #    The strip runs on a hardlink staging copy, NOT on squashfs-root:
  #    the build tree keeps its dpkg status so re-runs of this step are
  #    fast idempotent no-ops, while the shipped image stays stateless.
  echo "==> agent: stripping apt/dpkg state from the image (no package manager in the guest)"
  # Sweep staging dirs leaked by runs that died hard (kill -9 / power loss:
  # the EXIT trap only covers failures the shell can catch). PIDs encoded in
  # the names let a live concurrent run's stage survive.
  local stale
  for stale in "$FC_DIR"/.agent-stage.*; do
    [ -e "$stale" ] || continue   # glob didn't match — nothing to sweep
    kill -0 "${stale##*.}" 2>/dev/null || sudo rm -rf "$stale"
  done
  AGENT_STAGE="$FC_DIR/.agent-stage.$$"
  sudo rm -rf "$AGENT_STAGE"
  sudo cp -al "$root" "$AGENT_STAGE"
  sudo rm -rf "$AGENT_STAGE/etc/apt" \
              "$AGENT_STAGE/var/lib/apt" \
              "$AGENT_STAGE/var/cache" \
              "$AGENT_STAGE/var/log" \
              "$AGENT_STAGE/var/lib/ucf" \
              "$AGENT_STAGE/var/lib/python"
  # ripgrep used to be installed here before we learned Claude Code bundles its
  # own. Drop it from the shipped image so a re-run actually removes it: this
  # step never deletes from squashfs-root, so a tree built by an older version
  # would otherwise keep carrying /usr/bin/rg until an `images --force`.
  sudo rm -f "$AGENT_STAGE/usr/bin/rg"
  # dpkg: empty the database dir entirely (upstream ships it empty; the
  # lock files are dpkg's own artifacts, not needed by anything at runtime).
  [ -d "$AGENT_STAGE/var/lib/dpkg" ] \
    && sudo find "$AGENT_STAGE/var/lib/dpkg" -mindepth 1 -delete || true
  # sanity: refuse to ship an image that could still resolve or fetch packages
  sudo test ! -e "$AGENT_STAGE/etc/apt/sources.list" || {
    echo "strip failed: /etc/apt/sources.list still present" >&2; exit 1; }
  sudo test ! -e "$AGENT_STAGE/var/lib/dpkg/status" || {
    echo "strip failed: /var/lib/dpkg/status still present" >&2; exit 1; }
  sudo test ! -e "$AGENT_STAGE/var/lib/apt/lists" || {
    echo "strip failed: apt lists still present" >&2; exit 1; }

  # 6b. Overlay-root initrd, built from the BUILD tree (which still has
  #     busybox); busybox is then dropped from the staged copy. rm only unlinks
  #     the stage's name — squashfs-root keeps its hardlink, so re-runs are no-ops.
  echo "==> agent: building the overlay-root initrd"
  build_overlay_initrd "$root" "$FC_DIR/initrd-overlay.img"
  sudo rm -f "$AGENT_STAGE/usr/bin/busybox" "$AGENT_STAGE/bin/busybox"

  # 6c. The strip removed /var/log; recreate the journal dir. Read the gid from
  #     the image's /etc/group — the host's systemd-journal gid differs.
  local jgid
  jgid="$(sudo awk -F: '/^systemd-journal:/ {print $3}' "$root/etc/group" 2>/dev/null || true)"
  [ -n "$jgid" ] || jgid=0
  sudo install -d -m 755  -o 0 -g 0      "$AGENT_STAGE/var/log"
  sudo install -d -m 2755 -o 0 -g "$jgid" "$AGENT_STAGE/var/log/journal"

  # 7. Rebuild the ext4, grown from 1 GiB to 2 GiB — headroom for Claude
  #    Code's versioned self-updates (each downloaded release is ~300 MB),
  #    not for package installs: the guest ships no working package manager.
  #    NOTE: this discards any state in the previous ext4 (e.g. a newer
  #    claude downloaded by the auto-updater) — by design, to keep rebuilds
  #    reproducible.
  #    Refuse to rewrite the image under a running VM (mkfs on a live backing
  #    file corrupts the guest).
  if command -v fuser >/dev/null 2>&1 && fuser -s "$ext4" 2>/dev/null; then
    echo "refusing: $ext4 is in use (a VM is running off it) — ./stop-vm.sh first" >&2
    exit 1
  fi
  echo "==> agent: rebuilding $ext4 (2 GiB)"
  rm -f "$ext4"
  truncate -s 2G "$ext4"
  sudo mkfs.ext4 -q -d "$AGENT_STAGE" -F "$ext4"
  sudo rm -rf "$AGENT_STAGE"; AGENT_STAGE=""
  ln -sfn "ubuntu-$version.ext4" "$FC_DIR/ubuntu-latest.ext4"

  trap - EXIT
  echo "==> agent: done — guest image ready:"
  ls -la "$FC_DIR/ubuntu-latest.ext4"
  warn_stale_layers
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
  local url="${GITHUB_RELEASES}/download/${latest}/firecracker-${latest}-${ARCH}.tgz"
  echo "==> Downloading firecracker-${latest}-${ARCH}.tgz"
  curl -fSL -o "$tgz" "$url"
  # Upstream publishes <artifact>.sha256.txt next to every release asset.
  verify_sha256 "$tgz" "${url}.sha256.txt" "firecracker-${latest}-${ARCH}.tgz"
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

  # The CI bucket publishes no checksums, so these are pinned on first fetch and
  # verified afterwards. A dated CI key is immutable upstream: if the bytes
  # behind one change, that is worth stopping for, hence strict.
  echo "==> Downloading kernel ($kernel_key)"
  wget -q -O "$FC_DIR/vmlinux-$latest_kernel_ver" "$S3/$kernel_key"
  file "$FC_DIR/vmlinux-$latest_kernel_ver"
  pin_check "$FC_DIR/vmlinux-$latest_kernel_ver" "$kernel_key" strict

  echo "==> Downloading rootfs ($ubuntu_key)"
  wget -q -O "$FC_DIR/ubuntu-$ubuntu_version.squashfs.upstream" "$S3/$ubuntu_key"
  pin_check "$FC_DIR/ubuntu-$ubuntu_version.squashfs.upstream" "$ubuntu_key" strict

  echo "==> Unsquashing + patching SSH key + building ext4"
  # The previous run chowned squashfs-root to root:root (for mkfs.ext4 -d), so a
  # user-level rm can't delete it. Use sudo to clear it.
  sudo rm -rf "$FC_DIR/squashfs-root"
  (cd "$FC_DIR" && unsquashfs "ubuntu-$ubuntu_version.squashfs.upstream" >/dev/null)

  # Use the dedicated guest keypair (generated if missing). Never touches ~/.ssh.
  ensure_guest_key
  mkdir -p "$FC_DIR/squashfs-root/root/.ssh"
  cp "$SSH_KEY.pub" "$FC_DIR/squashfs-root/root/.ssh/authorized_keys"

  # A fresh extract brings fresh SSH host keys, so every trust-on-first-use
  # entry the scripts recorded is now stale. Drop the file instead of leaving
  # the next ssh to fail with a host-key-changed warning.
  rm -f "$FC_DIR/.known_hosts"

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
  warn_stale_layers
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
