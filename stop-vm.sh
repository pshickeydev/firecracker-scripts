#!/usr/bin/env bash
# stop-vm.sh — cleanly stop a VM started by start-vm.sh.
#
# Usage: ./stop-vm.sh [VM_ID]   (default 0)
#
# Tries SendCtrlAltDel first (clean shutdown), then kills firecracker and tears
# down the host TAP + NAT rules created by start-vm.sh.
set -euo pipefail

VM_ID="${1:-0}"
FC_DIR="${FC_DIR:-$HOME/firecracker}"
API_SOCKET="${API_SOCKET:-/tmp/firecracker-vm${VM_ID}.sock}"
TAP="fc${VM_ID}"
GUEST_LAST=$(( 2 + VM_ID * 4 ))
HOST_LAST=$(( GUEST_LAST - 1 ))

echo "==> VM ${VM_ID}: requesting clean shutdown (SendCtrlAltDel)"
if [ -S "$API_SOCKET" ]; then
  curl -s --max-time 5 --unix-socket "$API_SOCKET" -X PUT 'http://localhost/actions' \
    -H 'Content-Type: application/json' \
    -d '{"action_type":"SendCtrlAltDel"}' 2>/dev/null && echo || echo "  (no response, forcing)"
fi

# Give the guest a moment to halt, then force-kill firecracker if still alive.
sleep 2
if pgrep -af "firecracker --api-sock $API_SOCKET" | grep -qv "bin/bash -c"; then
  echo "==> VM ${VM_ID}: firecracker still alive, SIGKILL"
  pkill -9 -f "firecracker --api-sock $API_SOCKET" 2>/dev/null || true
fi
rm -f "$API_SOCKET"

# Tear down host-side networking.
echo "==> VM ${VM_ID}: tearing down $TAP"
sudo ip link del "$TAP" 2>/dev/null || true
# We leave the fc-nat table in place (harmless; reused by other VMs / next boot).

echo "==> VM ${VM_ID}: stopped"
