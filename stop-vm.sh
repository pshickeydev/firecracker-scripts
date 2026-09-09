#!/usr/bin/env bash
# stop-vm.sh — cleanly stop a VM started by start-vm.sh.
#
# Usage: ./stop-vm.sh [VM_ID]   (default 0)
#
# Tries SendCtrlAltDel first (clean shutdown), then kills firecracker and tears
# down the host TAP + NAT rules created by start-vm.sh.
set -euo pipefail

VM_ID="${VM_ID:-${1:-0}}"   # env wins over positional arg, matching start-vm.sh
# VM_ID drives every derived value (socket, TAP, /30, MAC); ids above 63 would
# overflow 172.16.0.0/24. 10# guards against bash treating "08" as a bad octal.
if ! [[ "$VM_ID" =~ ^[0-9]+$ ]] || (( 10#$VM_ID > 63 )); then
  echo "VM_ID must be an integer in 0..63 (got: '$VM_ID')" >&2
  exit 1
fi
VM_ID=$((10#$VM_ID))
# API sockets live in FC_SOCKET_DIR (default /tmp); API_SOCKET overrides the full path.
SOCKET_DIR="${FC_SOCKET_DIR:-/tmp}"
API_SOCKET="${API_SOCKET:-$SOCKET_DIR/firecracker-vm${VM_ID}.sock}"
TAP="fc${VM_ID}"

echo "==> VM ${VM_ID}: requesting clean shutdown (SendCtrlAltDel)"
if [ -S "$API_SOCKET" ]; then
  curl -s --max-time 5 --unix-socket "$API_SOCKET" -X PUT 'http://localhost/actions' \
    -H 'Content-Type: application/json' \
    -d '{"action_type":"SendCtrlAltDel"}' 2>/dev/null && echo || echo "  (no response, forcing)"
fi

# Give the guest a moment to halt, then force-kill firecracker if still alive.
sleep 2
# -xf: exact full-command-line match, so a wrapper shell (e.g. an agent's
# bash -c) that merely mentions this command can't be mistaken for the VM.
# The .sock suffix still keeps the pattern from prefix-matching other VMs (vm1 vs vm10).
if pgrep -xf "firecracker --api-sock $API_SOCKET" >/dev/null; then
  echo "==> VM ${VM_ID}: firecracker still alive, SIGKILL"
  pkill -9 -xf "firecracker --api-sock $API_SOCKET" 2>/dev/null || true
fi
rm -f "$API_SOCKET"

# Tear down host-side networking.
echo "==> VM ${VM_ID}: tearing down $TAP"
# Release the firewalld zone binding start-vm.sh created for the TAP (both
# runtime + permanent), if any.
if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
  FW_ZONE="$(sudo firewall-cmd --get-zone-of-interface="$TAP" 2>/dev/null || true)"
  if [ -n "$FW_ZONE" ]; then
    sudo firewall-cmd --zone="$FW_ZONE" --remove-interface="$TAP" >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --zone="$FW_ZONE" --remove-interface="$TAP" >/dev/null 2>&1 || true
  fi
fi
sudo ip link del "$TAP" 2>/dev/null || true
# We leave the fc-nat table in place (harmless; reused by other VMs / next boot).

echo "==> VM ${VM_ID}: stopped"
