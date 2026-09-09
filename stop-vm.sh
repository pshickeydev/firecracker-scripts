#!/usr/bin/env bash
# stop-vm.sh — cleanly stop a VM started by start-vm.sh.
#
# Usage: ./stop-vm.sh [VM_ID]   (default 0)
#
# Stop is: `systemctl poweroff` over SSH, then verify the halt, then reap.
# The ctrl-alt-del API action is deliberately NOT used — our boot args disable
# i8042 (noaux/nomux/nopnp/dumbkbd, probe fails -22), so it can never reach the
# guest. Halt is verified by two independent signals: the guest kernel's final serial
# line in the boot log (authoritative — proves poweroff.target completed and
# filesystems were unmounted), and, as fallback, a guest that answers no ping
# while its firecracker CPU time stays frozen across consecutive polls.
# On x86 Firecracker there is no power device, so even a *successful* poweroff
# leaves the firecracker process alive: "process exited" is NOT the halt
# signal, which is why the reap step below always runs. It then tears down the
# host TAP + NAT rules created by start-vm.sh.
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

# Derived from VM_ID with the same convention as start-vm.sh, so we can reach
# the guest over SSH for an orderly poweroff.
GUEST_LAST=$(( 2 + VM_ID * 4 ))
GUEST_IP="172.16.0.${GUEST_LAST}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
SSH_KEY="${SSH_KEY:-$FC_DIR/guest.id_rsa}"
# start-vm.sh points firecracker's stdout+stderr (serial console included) here
# and rm -f's it on every boot, so a match below can never be stale from an
# earlier run.
LOG_FILE="${LOG_FILE:-$FC_DIR/fc-vm${VM_ID}.log}"

guest_poweroff() { # ask the guest to halt itself; returns 0 if the request went through
  command -v ssh >/dev/null || return 1
  [ -f "$SSH_KEY" ] || return 1
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$GUEST_IP" \
    'sync; systemctl poweroff' >/dev/null 2>&1
}

# Signal A — authoritative: the guest kernel's final serial line proves
# poweroff.target completed (filesystems unmounted). x86 firecracker has no
# power device, so a successful poweroff prints "System halted instead".
# Deliberately NOT matching "Restarting system" (a reboot is not a halt).
log_halted() {
  [ -r "$LOG_FILE" ] || return 1
  grep -aqE 'reboot: (Power off not available: System halted instead|System halted|Power down)' "$LOG_FILE"
}

# Signal C gate — a live guest (even 100% idle) answers ICMP; a halted guest
# cannot (parked VCPUs = dead virtio-net RX). Distinguishes idle-live from halted.
guest_reachable() {
  command -v ping >/dev/null || return 1   # absent ping -> "not reachable"; the CPU-freeze check still backs the verdict
  ping -c1 -W1 "$GUEST_IP" >/dev/null 2>&1
}

fc_alive() {
  [ -n "$(fc_pid)" ]
}

# Liveness = our firecracker process bound to this exact API socket. A clean
# halt does NOT end it (see header), so this is presence only, not health.
fc_pid() {
  pgrep -xf "firecracker --api-sock $API_SOCKET" 2>/dev/null | head -1
}

HALT_HOW=""            # set by guest_halted: what convinced us
CPU_FROZEN_LAST=""     # poll-to-poll state for the sustained-freeze check

# utime+stime for our firecracker process. Parse after the last ')': comm is
# paren-wrapped and may contain spaces/parens; nothing after comm contains ')'.
cputicks() { # <pid> -> jiffies, rc=1 if unreadable
  local pid="$1" rest
  [ -r "/proc/$pid/stat" ] || return 1
  read -r rest < "/proc/$pid/stat" || return 1
  rest="${rest##*\) }"
  set -- $rest   # intentional word split; fields here are numeric/letters
  [ "$#" -ge 13 ] || return 1
  echo $(( ${12} + ${13} ))
}

# 0 = halted (HALT_HOW says how), 1 = alive/undetermined, 2 = gone.
guest_halted() {
  local pid pid2 t1 t2
  if log_halted; then HALT_HOW="serial log confirms poweroff completed"; return 0; fi
  pid="$(fc_pid)"
  [ -n "$pid" ] || { HALT_HOW="firecracker exited (no serial confirmation — crash/panic possible)"; return 2; }
  if guest_reachable; then CPU_FROZEN_LAST=""; return 1; fi
  t1="$(cputicks "$pid")" || { CPU_FROZEN_LAST=""; return 1; }
  sleep 2
  pid2="$(fc_pid)"
  [ -n "$pid2" ] || { HALT_HOW="firecracker exited mid-check"; return 2; }
  [ "$pid2" = "$pid" ] || { CPU_FROZEN_LAST=""; return 1; }
  t2="$(cputicks "$pid2")" || { CPU_FROZEN_LAST=""; return 1; }
  if [ -z "$t1" ] || [ -z "$t2" ] || (( t2 > t1 )); then CPU_FROZEN_LAST=""; return 1; fi
  if [ -n "$CPU_FROZEN_LAST" ]; then HALT_HOW="guest unreachable + CPU frozen (sustained; no serial confirmation)"; return 0; fi
  CPU_FROZEN_LAST="$SECONDS"
  return 1
}

# Wait up to $1 seconds for halt. 0 = halted/gone (HALT_HOW set), 1 = timeout.
wait_halt() {
  local deadline=$(( SECONDS + $1 )) rc=0
  CPU_FROZEN_LAST=""
  while :; do
    rc=0
    guest_halted || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then return 0; fi
    if (( SECONDS >= deadline )); then return 1; fi
    sleep 1
  done
}

echo "==> VM ${VM_ID}: requesting orderly shutdown (systemctl poweroff over ssh)"
STOP_T0=$SECONDS

if fc_alive; then
  rc=0; guest_halted || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "==> VM ${VM_ID}: guest already halted ($HALT_HOW)"
  elif guest_poweroff; then
    if wait_halt 45; then
      echo "==> VM ${VM_ID}: guest halted cleanly in $(( SECONDS - STOP_T0 ))s ($HALT_HOW)"
    else
      echo "==> VM ${VM_ID}: poweroff accepted but no halt within 45s — killing; rootfs may replay journal on next boot" >&2
    fi
  else
    if wait_halt 8; then
      echo "==> VM ${VM_ID}: ssh errored but guest halted anyway ($HALT_HOW)"
    else
      echo "==> VM ${VM_ID}: ssh unreachable, no halt evidence — killing; clean unmount NOT confirmed" >&2
    fi
  fi
else
  # No firecracker process for this id. Try ssh once anyway: if the VM was
  # started with a renamed API_SOCKET it would otherwise be orphaned here.
  if guest_poweroff; then
    echo "==> VM ${VM_ID}: powered off a guest not tracked by $API_SOCKET"
  else
    echo "==> VM ${VM_ID}: no running VM (socket stale or absent) — cleaning up host side"
  fi
fi

# Reap: firecracker does not exit on its own after a poweroff (see header).
# -xf: exact full-command-line match, so a wrapper shell (e.g. an agent's
# bash -c) that merely mentions this command can't be mistaken for the VM.
# The .sock suffix still keeps the pattern from prefix-matching other VMs (vm1 vs vm10).
if fc_alive; then
  pkill -TERM -xf "firecracker --api-sock $API_SOCKET" 2>/dev/null || true
  for _ in 1 2 3; do
    if ! fc_alive; then break; fi
    sleep 1
  done
  if fc_alive; then pkill -9 -xf "firecracker --api-sock $API_SOCKET" 2>/dev/null || true; fi
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
