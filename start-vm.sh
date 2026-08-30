#!/usr/bin/env bash
# start-vm.sh — boot a Firecracker microVM with networking, ready for SSH/agent use.
#
# Usage: ./start-vm.sh [VM_ID]    (VM_ID is a small integer, default 0)
#
# Each VM gets its own API socket, TAP device, and /30 subnet derived from VM_ID,
# so you can run several concurrently.
#
# Layout (all under this repo's dir unless overridden via env):
#   vmlinux-latest     -> guest kernel (symlink, managed by update-firecracker.sh)
#   ubuntu-latest.ext4 -> guest rootfs (symlink)
#   guest.id_rsa       -> SSH key matching root's authorized_keys (gitignored)
#
# Networking convention (matches the guest's fcnet-setup.sh):
#   MAC   06:00:AC:10:00:{02 + VM_ID*4}   ->   guest IP 172.16.0.{2 + VM_ID*4}/30
#   host TAP fc<id> gets the .1 of that /30, NAT to the host's internet.
set -euo pipefail

# Default FC_DIR to this script's directory so the repo is self-contained.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
VM_ID="${VM_ID:-${1:-0}}"
API_SOCKET="${API_SOCKET:-/tmp/firecracker-vm${VM_ID}.sock}"
LOG_FILE="${FC_DIR}/fc-vm${VM_ID}.log}"
KERNEL="${KERNEL:-$FC_DIR/vmlinux-latest}"
ROOTFS="${ROOTFS:-$FC_DIR/ubuntu-latest.ext4}"
SSH_KEY="${SSH_KEY:-$FC_DIR/guest.id_rsa}"

# Derive networking from VM_ID
GUEST_LAST=$(( 2 + VM_ID * 4 ))
HOST_LAST=$(( GUEST_LAST - 1 ))   # .1 of the /30
GUEST_IP="172.16.0.${GUEST_LAST}"
HOST_IP="172.16.0.${HOST_LAST}"
TAP="fc${VM_ID}"
# MAC: 06:00:AC:10:00:{GG}  -> guest IP 172.16.0.GG  (AC=172, 10=16, 00=0, GG)
MAC_LAST=$(printf "%02x" "$GUEST_LAST")
MAC="06:00:ac:10:00:${MAC_LAST}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need firecracker; need ip; need setsid; need jq; need ping

# Refuse to clobber a running VM with the same id.
if [ -S "$API_SOCKET" ]; then
  if curl -s --max-time 1 --unix-socket "$API_SOCKET" http://localhost/instance-info >/dev/null 2>&1; then
    echo "VM ${VM_ID} is already running (socket $API_SOCKET responds)." >&2
    echo "Use ./stop-vm.sh ${VM_ID} first, or pick a different id." >&2
    exit 1
  fi
  rm -f "$API_SOCKET"
fi

# Sanity-check assets.
[ -f "$KERNEL" ] || { echo "kernel not found: $KERNEL" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS" >&2; exit 1; }
[ -f "$SSH_KEY" ] || { echo "ssh key not found: $SSH_KEY" >&2; exit 1; }

echo "==> VM ${VM_ID}: kernel=$KERNEL rootfs=$ROOTFS"
echo "==> VM ${VM_ID}: tap=$TAP host=$HOST_IP/30 guest=$GUEST_IP/30 mac=$MAC"

# --- Host-side networking (needs root; will prompt for sudo password) ---
# Clean up any stale tap from a previous run.
if ip link show "$TAP" >/dev/null 2>&1; then
  sudo ip link del "$TAP"
fi
sudo ip tuntap add dev "$TAP" mode tap
sudo ip addr add "${HOST_IP}/30" dev "$TAP"
sudo ip link set "$TAP" up
# NAT so the guest can reach the internet.
sudo nft add table ip fc-nat 2>/dev/null || true
# (re)create the masquerade + forward rules; ignore "exists" errors.
sudo nft 'add chain ip fc-nat postrouting { type nat hook postrouting priority 100 ; }' 2>/dev/null || true
sudo nft add rule ip fc-nat postrouting oifname "$TAP" counter masquerade 2>/dev/null || \
  sudo nft add rule ip fc-nat postrouting oifname "$TAP" counter masquerade 2>/dev/null || true
sudo nft 'add chain ip fc-nat forward { type filter hook forward priority 0 ; }' 2>/dev/null || true
sudo nft add rule ip fc-nat forward iifname "$TAP" oifname != "$TAP" counter accept 2>/dev/null || true
sudo nft add rule ip fc-nat forward oifname "$TAP" iifname != "$TAP" counter accept 2>/dev/null || true

# --- Start firecracker, fully detached (immune to Ctrl+Z / terminal close) ---
echo "==> VM ${VM_ID}: starting firecracker (log: $LOG_FILE)"
rm -f "$LOG_FILE"
setsid firecracker --api-sock "$API_SOCKET" >"$LOG_FILE" 2>&1 </dev/null &
disown

# Wait for the API socket to appear.
for _ in $(seq 1 50); do
  [ -S "$API_SOCKET" ] && curl -s --max-time 1 --unix-socket "$API_SOCKET" http://localhost/instance-info >/dev/null 2>&1 && break
  sleep 0.1
done
if ! [ -S "$API_SOCKET" ]; then
  echo "firecracker failed to start; see $LOG_FILE" >&2
  exit 1
fi

# api: build JSON safely with jq so paths/args can't break out of the payload.
api() { # path <json-from-jq -n>
  local path="$1" body="$2"
  curl -s --unix-socket "$API_SOCKET" -X PUT "http://localhost${path}" \
    -H 'Content-Type: application/json' -d "$body"
  echo
}

echo "==> VM ${VM_ID}: configuring"
BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off nomodules random=1 i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd root=/dev/vda rw"
api /boot-source "$(jq -cn --arg k "$KERNEL" --arg a "$BOOT_ARGS" \
  '{kernel_image_path:$k, boot_args:$a}')"
api /drives/root "$(jq -cn --arg p "$ROOTFS" \
  '{drive_id:"root", path_on_host:$p, is_root_device:true, is_read_only:false}')"
api /machine-config '{"vcpu_count":1, "mem_size_mib":512}'
# Network interface — MAC drives the guest's auto-IP via fcnet-setup.sh.
api /network-interfaces/eth0 "$(jq -cn --arg t "$TAP" --arg m "$MAC" \
  '{iface_id:"eth0", host_dev_name:$t, guest_mac:$m}')"

echo "==> VM ${VM_ID}: starting (boot log: tail -f $LOG_FILE)"
api /actions '{"action_type":"InstanceStart"}'

# Wait briefly for the guest to bring up its interface, then try ping.
echo "==> VM ${VM_ID}: waiting for guest $GUEST_IP to respond..."
START=$SECONDS
for _ in $(seq 1 60); do
  if ping -c1 -W1 "$GUEST_IP" >/dev/null 2>&1; then
    echo "==> VM ${VM_ID}: guest is up ($GUEST_IP) after ~$((SECONDS - START))s"
    break
  fi
  sleep 1
done

cat <<EOF

================ VM ${VM_ID} ready ================
  serial console log : tail -f $LOG_FILE
  api socket          : $API_SOCKET
                       curl --unix-socket $API_SOCKET http://localhost/instance-info | jq
  ssh in              : ssh -i $SSH_KEY root@$GUEST_IP
  stop                : ./stop-vm.sh $VM_ID
====================================================
EOF
