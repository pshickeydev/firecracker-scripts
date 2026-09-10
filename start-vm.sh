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
# shellcheck source=lib-fcnet.sh
source "$SCRIPT_DIR/lib-fcnet.sh"

VM_ID="$(fc_validate_vm_id "${VM_ID:-${1:-0}}")" || exit 1
SOCKET_DIR="$(fc_ensure_socket_dir)"
API_SOCKET="${API_SOCKET:-$SOCKET_DIR/firecracker-vm${VM_ID}.sock}"
LOG_FILE="${FC_DIR}/fc-vm${VM_ID}.log"
KERNEL="${KERNEL:-$FC_DIR/vmlinux-latest}"
ROOTFS="${ROOTFS:-$FC_DIR/ubuntu-latest.ext4}"
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
BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off nomodules random=1 i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd root=/dev/vda rw"
api /boot-source "$(jq -cn --arg k "$KERNEL" --arg a "$BOOT_ARGS" \
  '{kernel_image_path:$k, boot_args:$a}')"
api /drives/root "$(jq -cn --arg p "$ROOTFS" \
  '{drive_id:"root", path_on_host:$p, is_root_device:true, is_read_only:false}')"
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
                       then: cd ${SHARE_MNT:-/workspace} && ANTHROPIC_PROFILE=fc-agents claude
EOF
fi
