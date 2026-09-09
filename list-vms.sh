#!/usr/bin/env bash
# list-vms.sh — list firecracker VMs started by start-vm.sh, with live status.
#
# Usage: ./list-vms.sh [VM_ID ...]
#
# With no arguments, scans for API sockets (FC_SOCKET_DIR, default /tmp) and
# reports every VM found. With explicit ids, reports those ids whether or not
# a socket exists (useful for confirming a VM is really gone). With exactly
# one explicit id, API_SOCKET is honored like in start-vm.sh, so a non-default
# socket path can be probed.
#
# Columns: VM  GUEST IP  TAP  FC PID  vCPU  MEM (MB)  STATUS
#
# STATUS is one of:
#   up        firecracker running and guest answers ping
#   running   firecracker running but guest not pinging (booting, or no tap)
#   stale     socket file left behind by a dead process (./stop-vm.sh cleans up)
#   absent    no socket — VM not running

# No -e on purpose: every failure path below is an explicit if/|| check.
set -uo pipefail

SOCKET_DIR="${FC_SOCKET_DIR:-/tmp}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need jq; need pgrep; need ip; need ping

# Collect VM ids: explicit args, or whatever sockets exist.
if [ "$#" -gt 0 ]; then
  ids=("$@")
else
  ids=()
  for sock in "$SOCKET_DIR"/firecracker-vm*.sock; do
    [ -e "$sock" ] || continue
    ids+=("$(basename "$sock" .sock | sed 's/^firecracker-vm//')")
  done
  if [ "${#ids[@]}" -eq 0 ]; then
    echo "No firecracker VMs running (no sockets in $SOCKET_DIR)."
    exit 0
  fi
fi

# With exactly one explicit id, honor a non-default API_SOCKET (as start-vm.sh does).
single_sock=""
if [ "$#" -eq 1 ] && [ -n "${API_SOCKET:-}" ]; then
  single_sock="$API_SOCKET"
fi

printf '%-4s %-14s %-5s %-8s %-5s %-9s %s\n' VM "GUEST IP" TAP "FC PID" VCPU "MEM (MB)" STATUS

for id in "${ids[@]}"; do
  # Sanity-check the id (10# defuses leading zeros like "08").
  if ! [[ "$id" =~ ^[0-9]+$ ]] || (( 10#$id > 63 )); then
    printf '%-4s %-14s %-5s %-8s %-5s %-9s %s\n' "$id" - - - - - "bad id (must be 0..63)"
    continue
  fi
  id=$((10#$id))

  sock="${single_sock:-$SOCKET_DIR/firecracker-vm${id}.sock}"
  guest="172.16.0.$(( 2 + id * 4 ))"
  tap="fc${id}"

  if [ ! -S "$sock" ]; then
    printf '%-4s %-14s %-5s %-8s %-5s %-9s %s\n' "$id" "$guest" "$tap" - - - absent
    continue
  fi

  # One snapshot: a failed fetch means no live process behind the socket.
  # Liveness endpoint: GET /machine-config answers 200 even before
  # configuration (the old /instance-info is gone from current Firecracker APIs).
  if ! config="$(curl -sf --max-time 1 --unix-socket "$sock" http://localhost/machine-config 2>/dev/null)"; then
    printf '%-4s %-14s %-5s %-8s %-5s %-9s %s\n' "$id" "$guest" "$tap" - - - "stale (run ./stop-vm.sh $id)"
    continue
  fi

  # -xf: exact full-command-line match. A loose -f pattern would also hit any
  # shell wrapper (e.g. an agent's bash -c) that merely mentions this command.
  pid="$(pgrep -xf "firecracker --api-sock $sock" | head -1)"
  vcpu="$(jq -r '.vcpu_count // "-"' <<<"$config")"
  mem="$(jq -r '.mem_size_mib // "-"' <<<"$config")"

  if ping -c1 -W1 "$guest" >/dev/null 2>&1; then
    status=up
  elif ! ip link show "$tap" >/dev/null 2>&1; then
    status="running (no $tap)"
  else
    status=running
  fi

  printf '%-4s %-14s %-5s %-8s %-5s %-9s %s\n' "$id" "$guest" "$tap" "${pid:--}" "$vcpu" "$mem" "$status"
done
