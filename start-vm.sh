#!/usr/bin/env bash
# start-vm.sh — boot a Firecracker microVM with networking, ready for SSH/agent use.
#
# Usage: ./start-vm.sh [VM_ID]    (VM_ID is a small integer, default 0)
#
# Each VM gets its own API socket, TAP device, and /30 subnet derived from VM_ID,
# so you can run several concurrently. Each is also its own trust domain: the
# host firewall drops guest-to-guest traffic (see lib-fcnet.sh).
#
# Optional env: SHARE_DIR=<hostdir> mounts <hostdir> into the guest at
# ${SHARE_MNT:-/workspace} over NFS (see share-dir.sh) right after boot.
# Combined with ./share-dir.sh <id> <dir> /root/.config/anthropic and
# ANTHROPIC_PROFILE, this gives a live host workspace + auth for in-VM agents.
# A third ./share-dir.sh <id> <dir> /root/.claude call likewise persists Claude
# Code's session transcripts to the host instead of the guest's ext4 rootfs.
#
# Machine profile: VCPU_COUNT (default 2) and MEM_SIZE_MIB (default 2048) set
# the guest's vCPU and memory. Applied at boot only — change them by restarting
# the VM, not while it runs.
#
# Network policy env (see lib-fcnet.sh for the full ruleset):
#   GUEST_LAN_ACCESS=1   let guests reach RFC1918 destinations (default: blocked)
#   GUEST_HOST_PORTS=... host ports guests may reach (default: 2049, i.e. NFS)
#   GUEST_HOST_FILTER=0  disable guest->host filtering entirely
#   GUEST_EGRESS_ALLOW=api.anthropic.com,registry.npmjs.org,...
#                        allowlist what the guest may reach on the internet and
#                        drop the rest (default: unset — unrestricted egress).
#                        Names are resolved on the host when the ruleset is
#                        built; GUEST_EGRESS_DNS sets the resolvers the guest
#                        may still reach on :53 (default 1.1.1.1,8.8.8.8).
#
# Rootfs isolation:
#   ROOTFS_MODE=auto|overlay|copy|shared    (default: auto)
#     overlay  read-only shared base + this VM's own writable layer (immutable
#              base, so a guest cannot backdoor future boots). Needs
#              initrd-overlay.img from ./update-firecracker.sh agent.
#     copy     this VM's own copy of the base image (reflinked if supported)
#     shared   every VM writes the same image — corrupts ext4; opt in by name
#     auto     overlay if the initrd is there, else copy
#   OVERLAY_SIZE_MIB=2048  layer size, applied at creation (resizing means
#                          RESET_LAYER=1, which discards it)
#   RESET_LAYER=1          discard this VM's writable bytes and start clean
#   PER_VM_KEY=0           reuse the shared guest.id_rsa (not recommended:
#                          one key = root on all guests)
#
# Layout (all under this repo's dir unless overridden via env):
#   vmlinux-latest      -> guest kernel (symlink, managed by update-firecracker.sh)
#   ubuntu-latest.ext4  -> shared base rootfs (symlink; read-only in overlay mode)
#   initrd-overlay.img  -> overlay-root initrd (built by update-firecracker.sh)
#   vm<id>-layer.ext4   -> this VM's writable overlay layer (gitignored)
#   vm<id>.ext4         -> this VM's rootfs copy, in copy mode (gitignored)
#   guest-vm<id>.id_rsa -> this VM's own SSH key, generated on demand (gitignored)
#   guest.id_rsa        -> shared fallback SSH key (gitignored)
#
# Networking convention (matches the guest's fcnet-setup.sh):
#   MAC   06:00:AC:10:00:{02 + VM_ID*4}   ->   guest IP 172.16.0.{2 + VM_ID*4}/30
#   host TAP fc<id> gets the .1 of that /30, NAT to the host's internet.
set -euo pipefail

# Default FC_DIR to this script's directory so the repo is self-contained.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
# shellcheck source=lib-fcnet.sh
source "$SCRIPT_DIR/lib-fcnet.sh"

VM_ID="$(fc_validate_vm_id "${VM_ID:-${1:-0}}")" || exit 1
SOCKET_DIR="$(fc_ensure_socket_dir)"
API_SOCKET="${API_SOCKET:-$SOCKET_DIR/firecracker-vm${VM_ID}.sock}"
LOG_FILE="${FC_DIR}/fc-vm${VM_ID}.log"
KERNEL="${KERNEL:-$FC_DIR/vmlinux-latest}"
ROOTFS="${ROOTFS:-$FC_DIR/ubuntu-latest.ext4}"
# SSH_KEY_FROM_ENV: a caller-supplied SSH_KEY is installed in the guest
# instead of generating a per-VM one (see ensure_per_vm_key).
SSH_KEY_FROM_ENV="${SSH_KEY:+1}"
SSH_KEY="${SSH_KEY:-$FC_DIR/guest.id_rsa}"

# Machine profile. Firecracker requires vcpu_count >= 1 and mem_size_mib to be
# a whole number of MiB; hot-plugging is not supported, so these are fixed at
# boot. Defaults are sized for an in-guest Claude Code session (512 MiB thrashed).
VCPU_COUNT="${VCPU_COUNT:-2}"
MEM_SIZE_MIB="${MEM_SIZE_MIB:-2048}"
if ! [[ "$VCPU_COUNT" =~ ^[0-9]+$ ]] || (( VCPU_COUNT < 1 )); then
  echo "VCPU_COUNT must be an integer >= 1 (got: '$VCPU_COUNT')" >&2
  exit 1
fi
if ! [[ "$MEM_SIZE_MIB" =~ ^[0-9]+$ ]] || (( MEM_SIZE_MIB < 128 )); then
  echo "MEM_SIZE_MIB must be an integer >= 128 (got: '$MEM_SIZE_MIB')" >&2
  exit 1
fi

# Network-policy env: validate before ANY host state is created. fc_nft_apply
# re-validates when it builds the ruleset, but that runs after the TAP is up —
# a bad value there would die mid-flight and leave a stray device behind.
# Assigning the normalized list back also makes the re-check a no-op.
GUEST_HOST_PORTS="$(fc_guest_host_ports)"

# Validate SHARE_DIR up front: share-dir.sh runs only after the VM is up, and
# an unshareable dir (above all the toolchain itself) should fail before any
# host state is created.
if [ -n "${SHARE_DIR:-}" ]; then
  [ -d "$SHARE_DIR" ] || { echo "SHARE_DIR is not a directory: $SHARE_DIR" >&2; exit 1; }
  SHARE_DIR_RESOLVED="$(readlink -f "$SHARE_DIR")"
  fc_reject_unsafe_path "$SHARE_DIR_RESOLVED" "SHARE_DIR"
  fc_reject_toolchain_export "$SHARE_DIR_RESOLVED"
fi

# Derive networking from VM_ID
GUEST_IP="$(fc_guest_ip "$VM_ID")"
HOST_IP="$(fc_host_ip "$VM_ID")"
TAP="$(fc_tap "$VM_ID")"
# MAC: 06:00:AC:10:00:{GG}  -> guest IP 172.16.0.GG  (AC=172, 10=16, 00=0, GG)
MAC_LAST=$(printf "%02x" "${GUEST_IP##*.}")
MAC="06:00:ac:10:00:${MAC_LAST}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need firecracker; need ip; need nft; need sudo; need setsid; need jq; need ping

# Refuse to clobber a running VM with the same id.
# Liveness endpoint: GET /machine-config answers 200 even before configuration.
# (The old /instance-info endpoint is gone from current Firecracker APIs.)
if [ -S "$API_SOCKET" ]; then
  if curl -sf --max-time 1 --unix-socket "$API_SOCKET" http://localhost/machine-config >/dev/null 2>&1; then
    echo "VM ${VM_ID} is already running (socket $API_SOCKET responds)." >&2
    echo "Use ./stop-vm.sh ${VM_ID} first, or pick a different id." >&2
    exit 1
  fi
  rm -f "$API_SOCKET"
fi

# Sanity-check assets (the SSH key is settled below, after the rootfs mode).
[ -f "$KERNEL" ] || { echo "kernel not found: $KERNEL" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS" >&2; exit 1; }

# --- per-VM rootfs isolation --------------------------------------------------
# Two VMs on one writable image corrupt ext4 (independent page caches, journals
# and bitmaps) and share a read-write code path underneath the inter-VM network
# isolation. Every mode below gives a VM its own writable bytes; `shared` (the
# old behavior) must be asked for by name.
ROOTFS_MODE="${ROOTFS_MODE:-auto}"
OVERLAY_SIZE_MIB="${OVERLAY_SIZE_MIB:-2048}"
INITRD="${INITRD:-$FC_DIR/initrd-overlay.img}"
LAYER="$FC_DIR/vm${VM_ID}-layer.ext4"
VM_COPY="$FC_DIR/vm${VM_ID}.ext4"
ROOTFS_BASE="$ROOTFS"   # ROOTFS is rewritten below in copy mode
PER_VM_KEY="${PER_VM_KEY:-1}"

if ! [[ "$OVERLAY_SIZE_MIB" =~ ^[0-9]+$ ]] || (( OVERLAY_SIZE_MIB < 64 )); then
  echo "OVERLAY_SIZE_MIB must be an integer >= 64 (got: '$OVERLAY_SIZE_MIB')" >&2
  exit 1
fi

case "$ROOTFS_MODE" in
  auto)
    if [ -f "$INITRD" ]; then
      ROOTFS_MODE=overlay
    else
      ROOTFS_MODE=copy
      echo "==> VM ${VM_ID}: no overlay initrd at $INITRD — using ROOTFS_MODE=copy"
      echo "    (for a read-only shared base: ./update-firecracker.sh agent)"
    fi
    ;;
  overlay)
    [ -f "$INITRD" ] || {
      echo "ROOTFS_MODE=overlay needs the overlay initrd: $INITRD" >&2
      echo "build it with: ./update-firecracker.sh agent" >&2
      exit 1
    }
    ;;
  copy) ;;
  shared)
    echo "==> VM ${VM_ID}: WARNING — ROOTFS_MODE=shared: this VM writes $ROOTFS directly." >&2
    echo "    A second VM on the same image corrupts it; only the in-use check below guards it." >&2
    ;;
  *)
    echo "ROOTFS_MODE must be auto|overlay|copy|shared (got: '$ROOTFS_MODE')" >&2
    exit 1
    ;;
esac
# A bad initrd fails before /init runs, so the guest cannot report it — panic=1
# would turn it into a reboot loop with no diagnostic. Warn rather than refuse:
# a hand-supplied INITRD= need not be gzip.
if [ "$ROOTFS_MODE" = overlay ] && command -v gzip >/dev/null 2>&1 \
   && ! gzip -t "$INITRD" 2>/dev/null; then
  echo "==> VM ${VM_ID}: warning — $INITRD is not a readable gzip archive." >&2
  echo "    If the guest never reaches systemd, rebuild it: ./update-firecracker.sh agent" >&2
fi

# Only overlay mode makes a filesystem; copy mode just copies one.
if [ "$ROOTFS_MODE" = overlay ]; then need mkfs.ext4; fi
if [ "$PER_VM_KEY" = 1 ]; then need ssh-keygen; fi

# --- writable-image plumbing --------------------------------------------------

IMG_MNT=""
IMG_LOOP=""
img_umount() {
  if [ -n "$IMG_MNT" ]; then
    sudo umount "$IMG_MNT" 2>/dev/null || sudo umount -l "$IMG_MNT" 2>/dev/null || true
    rmdir "$IMG_MNT" 2>/dev/null || true
    IMG_MNT=""
  fi
  if [ -n "$IMG_LOOP" ]; then
    sudo losetup -d "$IMG_LOOP" 2>/dev/null || true
    IMG_LOOP=""
  fi
}
trap img_umount EXIT

# Attach the image to a loop device in two explicit steps: `mount -o loop`
# fails on util-linux 2.39 + kernel 6.x ("Can't open blockdev" — mount holds the
# new loop device exclusively and cannot open it). nosuid/nodev/noexec: we only
# write files through it.
img_mount() { # <image>
  IMG_MNT="$(mktemp -d)"
  IMG_LOOP="$(sudo losetup --find --show "$1" 2>/dev/null)" || IMG_LOOP=""
  if [ -n "$IMG_LOOP" ]; then
    if sudo mount -o nosuid,nodev,noexec "$IMG_LOOP" "$IMG_MNT"; then return 0; fi
  elif sudo mount -o loop,nosuid,nodev,noexec "$1" "$IMG_MNT"; then
    return 0   # no losetup on this host; the combined form worked
  fi
  img_umount
  echo "could not mount $1 — image already attached, or no free loop device?" >&2
  exit 1
}

# This VM's own keypair: a shared key means any guest that reads
# the private half is root on all guests; with the base no longer writable,
# per-VM keys are possible.
ensure_per_vm_key() { # -> prints the private key path
  local key="$FC_DIR/guest-vm${VM_ID}.id_rsa"
  if [ ! -f "$key" ]; then
    echo "==> VM ${VM_ID}: generating this VM's own SSH key ($(basename "$key"))" >&2
    ssh-keygen -q -t ed25519 -f "$key" -N "" -C "firecracker-vm${VM_ID}" >&2 \
      || { echo "ssh-keygen failed for $key" >&2; exit 1; }
    chmod 600 "$key"
  fi
  echo "$key"
}

# Re-applied on every boot (rotating a key = delete it). In overlay mode the
# prefix is the overlay upper dir, so the file shadows the base's shared key.
inject_authorized_key() { # <guest-root-prefix> <pubkey file>
  sudo install -d -m 700 -o root -g root "$1/root"
  sudo install -d -m 700 -o root -g root "$1/root/.ssh"
  sudo install -m 600 -o root -g root "$2" "$1/root/.ssh/authorized_keys"
}

refuse_if_in_use() { # <image> <description>
  local why
  if why="$(fc_rootfs_in_use "$1")"; then
    echo "refusing to boot VM ${VM_ID}: $2 is already in use — $why" >&2
    echo "    Stop the other VM (./stop-vm.sh <id>) or pick another VM id." >&2
    exit 1
  fi
}

# A read-only mount cannot replay a journal, so a dirty base fails late in the
# initrd. Catch it here, where the message can say what to do.
require_clean_base() { # <image>
  command -v dumpe2fs >/dev/null 2>&1 || return 0
  local state
  # Keep internal spaces: the states that matter read "clean", "not clean" and
  # "clean with errors", and only the first is safe to mount read-only.
  state="$(dumpe2fs -h "$1" 2>/dev/null | sed -n 's/^Filesystem state: *//p' \
           | head -1 | sed 's/[[:space:]]*$//')"
  [ -n "$state" ] || return 0
  [ "$state" = "clean" ] && return 0
  echo "refusing to boot VM ${VM_ID}: base image $1 is in state '$state'." >&2
  echo "    It has to be clean to be attached read-only." >&2
  echo "    With every VM stopped, repair it on the host:  e2fsck -fy $1" >&2
  echo "    (this is expected if two VMs ever shared it read-write)" >&2
  exit 1
}

VM_KEY=""
case "$ROOTFS_MODE" in
  overlay)
    BASE="$ROOTFS"
    refuse_if_in_use "$LAYER" "this VM's writable layer ($LAYER)"
    require_clean_base "$BASE"
    if [ "${RESET_LAYER:-0}" = 1 ] && [ -f "$LAYER" ]; then
      echo "==> VM ${VM_ID}: RESET_LAYER=1 — discarding $LAYER"
      rm -f "$LAYER"
    fi
    if [ ! -f "$LAYER" ]; then
      echo "==> VM ${VM_ID}: creating writable layer $LAYER (${OVERLAY_SIZE_MIB} MiB, sparse)"
      truncate -s "${OVERLAY_SIZE_MIB}M" "$LAYER"
      # root_owner=0:0: overlayfs takes the merged root's metadata from the upper
      # dir (a uid-1000 layer would hand the guest a / owned by uid 1000).
      # -L fc-layer: the initrd finds the layer by label, not device order.
      mkfs.ext4 -q -F -L fc-layer -E root_owner=0:0 "$LAYER" || {
        rm -f "$LAYER"; echo "mkfs.ext4 failed on $LAYER" >&2; exit 1; }
    fi
    img_mount "$LAYER"
    sudo install -d -m 755 -o root -g root "$IMG_MNT/upper" "$IMG_MNT/work"
    if [ "$PER_VM_KEY" = 1 ]; then
      if [ -n "$SSH_KEY_FROM_ENV" ]; then VM_KEY="$SSH_KEY"; else VM_KEY="$(ensure_per_vm_key)"; fi
      [ -f "$VM_KEY.pub" ] || { echo "no public half at $VM_KEY.pub to install in the guest" >&2; exit 1; }
      inject_authorized_key "$IMG_MNT/upper" "$VM_KEY.pub"
      SSH_KEY="$VM_KEY"
    fi
    img_umount
    echo "==> VM ${VM_ID}: base $BASE (read-only) + layer $LAYER (read-write)"
    ;;

  copy)
    refuse_if_in_use "$VM_COPY" "this VM's rootfs copy ($VM_COPY)"
    if [ "${RESET_LAYER:-0}" = 1 ] && [ -f "$VM_COPY" ]; then
      echo "==> VM ${VM_ID}: RESET_LAYER=1 — discarding $VM_COPY"
      rm -f "$VM_COPY"
    fi
    if [ ! -f "$VM_COPY" ]; then
      # Copying alongside a read-only user of the base is fine; a shared-mode
      # writer is not — and they are indistinguishable here, so warn.
      if why_base="$(fc_rootfs_in_use "$ROOTFS")"; then
        echo "==> VM ${VM_ID}: warning — copying $ROOTFS while it is open ($why_base)." >&2
        echo "    If a VM is WRITING it, this copy may be inconsistent." >&2
      fi
      echo "==> VM ${VM_ID}: creating $VM_COPY from $ROOTFS (reflink where supported)"
      cp --reflink=auto "$ROOTFS" "$VM_COPY" || {
        rm -f "$VM_COPY"; echo "could not copy $ROOTFS -> $VM_COPY" >&2; exit 1; }
    fi
    if [ "$PER_VM_KEY" = 1 ]; then
      if [ -n "$SSH_KEY_FROM_ENV" ]; then VM_KEY="$SSH_KEY"; else VM_KEY="$(ensure_per_vm_key)"; fi
      [ -f "$VM_KEY.pub" ] || { echo "no public half at $VM_KEY.pub to install in the guest" >&2; exit 1; }
      img_mount "$VM_COPY"
      inject_authorized_key "$IMG_MNT" "$VM_KEY.pub"
      img_umount
      SSH_KEY="$VM_KEY"
    fi
    ROOTFS="$VM_COPY"
    echo "==> VM ${VM_ID}: rootfs $ROOTFS (this VM's own copy)"
    ;;

  shared)
    refuse_if_in_use "$ROOTFS" "the shared rootfs ($ROOTFS)"
    if [ "$PER_VM_KEY" = 1 ] && [ -z "$SSH_KEY_FROM_ENV" ]; then
      echo "==> VM ${VM_ID}: ROOTFS_MODE=shared — not installing a per-VM SSH key" >&2
      echo "    (it would rewrite the image every VM boots from); using the shared key" >&2
    fi
    ;;
esac

# PER_VM_KEY=0 with a per-VM key already on disk: the VM's layer may still
# carry that key's public half from an earlier boot, so the shared key may be
# refused. Say so rather than leave an ssh refusal to be puzzled over.
if [ "$PER_VM_KEY" != 1 ] && [ "$ROOTFS_MODE" != shared ] \
   && [ -f "$FC_DIR/guest-vm${VM_ID}.id_rsa" ]; then
  echo "==> VM ${VM_ID}: note — PER_VM_KEY=0, but guest-vm${VM_ID}.id_rsa exists, and this" >&2
  echo "    VM's layer may still hold its public half from an earlier boot. If ssh is" >&2
  echo "    refused, use that key, or rebuild the layer with RESET_LAYER=1." >&2
fi

case "$ROOTFS_MODE" in
  overlay) ROOTFS_DESC="$BASE (read-only) + $LAYER (this VM's writable overlay)" ;;
  copy)    ROOTFS_DESC="$ROOTFS (this VM's own copy of $ROOTFS_BASE)" ;;
  shared)  ROOTFS_DESC="$ROOTFS (SHARED — every ROOTFS_MODE=shared VM writes it)" ;;
esac

[ -f "$SSH_KEY" ] || { echo "ssh key not found: $SSH_KEY" >&2; exit 1; }

echo "==> VM ${VM_ID}: kernel=$KERNEL rootfs=$ROOTFS_DESC"
echo "==> VM ${VM_ID}: tap=$TAP host=$HOST_IP/30 guest=$GUEST_IP/30 mac=$MAC"

# --- Host-side networking (needs root; will prompt for sudo password) ---
# Clean up any stale tap from a previous run.
if ip link show "$TAP" >/dev/null 2>&1; then
  sudo ip link del "$TAP"
fi
sudo ip tuntap add dev "$TAP" mode tap
# Disable IPv6 on the TAP *before* bringing it up, so it never gets a link-local
# address. Everything here is IPv4 (the /30, the NAT, the NFS mount), and the
# fc-nat rules are ip-family only — so a link-local on this device would be an
# unfiltered path from the guest to any host service bound to ::, straight past
# the guest->host filtering below. The guest keeps its own link-local; with the
# host end gone there is nothing on the other side of it to reach.
sudo sysctl -qw "net.ipv6.conf.${TAP}.disable_ipv6=1" 2>/dev/null || true
sudo ip addr add "${HOST_IP}/30" dev "$TAP"
sudo ip link set "$TAP" up
# Verify: if the sysctl silently failed, say so rather than leaving the guest
# with a quiet way around the input chain.
if [ -n "$(ip -6 addr show dev "$TAP" scope link 2>/dev/null)" ]; then
  echo "==> VM ${VM_ID}: warning — $TAP still has an IPv6 link-local address;" >&2
  echo "    guest->host IPv6 is NOT filtered by the fc-nat rules (ip family only)" >&2
fi
# NAT so the guest can reach the internet.
# 1) The host must route (net.ipv4.ip_forward): firewalld keeps it 0 unless a
#    zone has masquerade, and without it guest packets never even reach the
#    forward/NAT chains. Set it now + persist it (a later firewalld reload
#    would otherwise silently re-disable routing).
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  echo "==> enabling net.ipv4.ip_forward (guest NAT routing)"
  sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi
if [ ! -f /etc/sysctl.d/99-fc-agents.conf ]; then
  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-fc-agents.conf >/dev/null
fi
# 2) nft: rebuild the whole fc-nat table from the TAPs that exist right now.
#    This is a single atomic transaction (and is validated with `nft -c` first),
#    so it can neither leave the host half-configured nor accumulate a
#    duplicate rule per boot. See fc_nft_apply in lib-fcnet.sh for the policy.
# Remember the egress policy: stop-vm.sh rebuilds the global table without
# GUEST_EGRESS_ALLOW in its environment, and stopping one VM must not restore
# unrestricted egress for the others.
fc_egress_persist
echo "==> VM ${VM_ID}: applying host firewall rules (NAT + isolation)"
fc_nft_apply
sudo nft list chain ip fc-nat forward >/dev/null 2>&1 || {
  echo "nftables fc-nat setup failed (missing nft, or sudo not permitted?)" >&2
  exit 1
}

# firewalld (if active) filters FORWARD and would reject forwarded guest
# egress. The fix must put the TAP in the SAME zone as the uplink interface
# (intra-zone forwarding), or firewalld's policy chain rejects fc0 -> uplink
# traffic no matter what our own nft chains accept. NAT itself stays in nft.
#
# Deliberately RUNTIME-ONLY (no --permanent). A TAP is torn down with the VM,
# so a permanent interface binding would outlive the device it names; and
# --add-forward permanently enables intra-zone forwarding for EVERY interface
# in that zone, which is a lasting relaxation of the host's firewall to buy a
# per-session need. stop-vm.sh undoes the forward when the last VM goes away.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  UPLINK="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
  if [ -n "${UPLINK:-}" ] \
     && FW_ZONE="$(sudo firewall-cmd --get-zone-of-interface="$UPLINK" 2>/dev/null)" \
     && [ -n "$FW_ZONE" ]; then
    :  # use the uplink's zone
  else
    FW_ZONE="$(sudo firewall-cmd --get-default-zone)"
  fi
  echo "==> VM ${VM_ID}: firewalld — binding $TAP to zone '$FW_ZONE' + intra-zone forwarding (runtime only)"
  sudo firewall-cmd --zone="$FW_ZONE" --add-interface="$TAP" >/dev/null 2>&1 || true
  # Only enable forwarding if it wasn't already on, and record that WE turned
  # it on so stop-vm.sh knows it is ours to turn back off.
  if ! sudo firewall-cmd --zone="$FW_ZONE" --query-forward >/dev/null 2>&1; then
    if sudo firewall-cmd --zone="$FW_ZONE" --add-forward >/dev/null 2>&1; then
      echo "$FW_ZONE" > "$FC_DIR/.fw-forward-added"
    fi
  fi
fi

# --- Start firecracker, fully detached (immune to Ctrl+Z / terminal close) ---
echo "==> VM ${VM_ID}: starting firecracker (log: $LOG_FILE)"
rm -f "$LOG_FILE"
# umask 077 in the subshell so firecracker creates its API socket — a full
# control channel over this VM — mode 0700, and the serial log (which carries
# whatever the guest prints to its console) is not world-readable.
( umask 077; setsid firecracker --api-sock "$API_SOCKET" >"$LOG_FILE" 2>&1 </dev/null & )

# Wait for the API to come up (socket present AND endpoint responding).
API_UP=0
for _ in $(seq 1 50); do
  if [ -S "$API_SOCKET" ] && curl -sf --max-time 1 --unix-socket "$API_SOCKET" http://localhost/machine-config >/dev/null 2>&1; then
    API_UP=1
    break
  fi
  sleep 0.1
done
if [ "$API_UP" != 1 ]; then
  echo "firecracker failed to start; see $LOG_FILE" >&2
  exit 1
fi

# api: build JSON safely with jq so paths/args can't break out of the payload.
api() { # path <json-from-jq -n>
  local path="$1" body="$2"
  curl -s --max-time 5 --unix-socket "$API_SOCKET" -X PUT "http://localhost${path}" \
    -H 'Content-Type: application/json' -d "$body"
  echo
}

echo "==> VM ${VM_ID}: configuring"
# `nomodules` was never a real kernel parameter — the control it reads like is
# kernel.modules_disabled=1, now set in the image. Dropped. Firecracker appends
# its own pci=off/root=…, which is why /proc/cmdline shows those twice; ours
# stay explicit.
BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off random=1 i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd"
if [ "$ROOTFS_MODE" != overlay ]; then
  # Overlay mode leaves root= to the initrd, which assembles / from two drives.
  BOOT_ARGS="$BOOT_ARGS root=/dev/vda rw"
fi

if [ "$ROOTFS_MODE" = overlay ]; then
  api /boot-source "$(jq -cn --arg k "$KERNEL" --arg a "$BOOT_ARGS" --arg i "$INITRD" \
    '{kernel_image_path:$k, boot_args:$a, initrd_path:$i}')"
  # /dev/vda — shared base, read-only (immutable; guests can't backdoor future
  # boots). /dev/vdb — this VM's layer (the overlay upper). Order matters:
  # the base must be the root device.
  api /drives/root "$(jq -cn --arg p "$BASE" \
    '{drive_id:"root", path_on_host:$p, is_root_device:true, is_read_only:true}')"
  api /drives/layer "$(jq -cn --arg p "$LAYER" \
    '{drive_id:"layer", path_on_host:$p, is_root_device:false, is_read_only:false}')"
else
  api /boot-source "$(jq -cn --arg k "$KERNEL" --arg a "$BOOT_ARGS" \
    '{kernel_image_path:$k, boot_args:$a}')"
  api /drives/root "$(jq -cn --arg p "$ROOTFS" \
    '{drive_id:"root", path_on_host:$p, is_root_device:true, is_read_only:false}')"
fi
api /machine-config "$(jq -cn --argjson v "$VCPU_COUNT" --argjson m "$MEM_SIZE_MIB" \
  '{vcpu_count:$v, mem_size_mib:$m}')"
# Network interface — MAC drives the guest's auto-IP via fcnet-setup.sh.
api /network-interfaces/eth0 "$(jq -cn --arg t "$TAP" --arg m "$MAC" \
  '{iface_id:"eth0", host_dev_name:$t, guest_mac:$m}')"

echo "==> VM ${VM_ID}: starting (boot log: tail -f $LOG_FILE)"
api /actions '{"action_type":"InstanceStart"}'

# Wait briefly for the guest to bring up its interface, then try ping.
echo "==> VM ${VM_ID}: waiting for guest $GUEST_IP to respond..."
START=$SECONDS
GUEST_UP=0
for _ in $(seq 1 60); do
  if ping -c1 -W1 "$GUEST_IP" >/dev/null 2>&1; then
    echo "==> VM ${VM_ID}: guest is up ($GUEST_IP) after ~$((SECONDS - START))s"
    GUEST_UP=1
    break
  fi
  sleep 1
done
if [ "$GUEST_UP" != 1 ]; then
  echo "==> VM ${VM_ID}: guest $GUEST_IP never answered ping after $((SECONDS - START))s" >&2
  echo "    it may still be booting — serial console: tail -f $LOG_FILE" >&2
  echo "    or tear it down with: ./stop-vm.sh ${VM_ID}" >&2
  exit 1
fi

# Optional live host-dir share (NFS). A failure here leaves the VM running;
# share-dir.sh can be retried manually once the cause is fixed.
if [ -n "${SHARE_DIR:-}" ]; then
  SHARE_MNT="${SHARE_MNT:-/workspace}"
  echo "==> VM ${VM_ID}: SHARE_DIR set — mounting $SHARE_DIR at $SHARE_MNT"
  if ! "$SCRIPT_DIR/share-dir.sh" "$VM_ID" "$SHARE_DIR" "$SHARE_MNT"; then
    echo "    (NFS share failed — VM is still up; retry: ./share-dir.sh $VM_ID '$SHARE_DIR' $SHARE_MNT)" >&2
  fi
fi

KNOWN_HOSTS="$(fc_known_hosts)"
cat <<EOF

================ VM ${VM_ID} ready ================
  serial console log : tail -f $LOG_FILE
  rootfs ($ROOTFS_MODE) : $ROOTFS_DESC
  api socket          : $API_SOCKET
                       curl --unix-socket $API_SOCKET http://localhost/machine-config | jq
  ssh in              : ssh -i $SSH_KEY -o UserKnownHostsFile=$KNOWN_HOSTS root@$GUEST_IP
  stop                : ./stop-vm.sh $VM_ID
====================================================
EOF

if [ -n "${SHARE_DIR:-}" ]; then
  cat <<EOF

  workspace (NFS)     : $SHARE_DIR -> ${SHARE_MNT:-/workspace} (live in the guest)
  unshare             : ./share-dir.sh --unmount $VM_ID '$SHARE_DIR' ${SHARE_MNT:-/workspace}
  run claude          : ssh -t -i $SSH_KEY -o UserKnownHostsFile=$KNOWN_HOSTS root@$GUEST_IP
                       then: cd ${SHARE_MNT:-/workspace} && ANTHROPIC_PROFILE=fc-agents IS_SANDBOX=1 claude --dangerously-skip-permissions
EOF
fi
