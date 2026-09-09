#!/usr/bin/env bash
# share-dir.sh — share a host directory into a running VM, live, over NFSv4.
#
# Usage:
#   ./share-dir.sh <VM_ID> <hostdir> [guest_mntpoint]    # share (default mntpoint /workspace)
#   ./share-dir.sh --unmount <VM_ID> <hostdir> [guest_mntpoint]
#
# Firecracker has no virtio-fs/9p device model, so a live host<->guest shared
# directory rides on networking. NFSv4 is used because the guest kernel has the
# NFSv4 client built in and only needs the mount.nfs helper (installed by
# `update-firecracker.sh agent`).
#
# Host side:  adds "<hostdir> 172.16.0.0/24(rw,no_subtree_check,no_root_squash,fsid=N)"
#            to /etc/exports.d/fc-agents.exports, re-exports, and (if firewalld is
#            active) allows NFS (2049/tcp) from the VM subnet. no_root_squash is
#            required: the guest is root-only, so guest root must act as host
#            root on the export (single-user dev host assumption).
# Guest side: over the existing SSH path: mkdir + mount -t nfs4 172.16.0.x:<hostdir>.
#
# NFS is stateless, so stop-vm.sh needs no changes; use --unmount to retire an
# export cleanly. The firewalld rule and nfs-server service stay enabled (they
# are shared by every VM and harmless).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
SSH_KEY="${SSH_KEY:-$FC_DIR/guest.id_rsa}"
EXPORTS_FILE="/etc/exports.d/fc-agents.exports"
NFS_SUBNET="172.16.0.0/24"
FW_RULE='rule family=ipv4 source address=172.16.0.0/24 port port=2049 protocol=tcp accept'

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }; }
need ssh; need sudo

usage() {
  echo "usage: $0 [--unmount] <VM_ID> <hostdir> [guest_mntpoint]" >&2
  exit 2
}

UNMOUNT=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "--unmount" ]; then UNMOUNT=1; else ARGS+=("$a"); fi
done
[ "${#ARGS[@]}" -ge 2 ] && [ "${#ARGS[@]}" -le 3 ] || usage
VM_ID="${ARGS[0]}"
if ! [[ "$VM_ID" =~ ^[0-9]+$ ]] || (( 10#$VM_ID > 63 )); then
  echo "VM_ID must be an integer in 0..63 (got: '$VM_ID')" >&2
  exit 1
fi
VM_ID=$((10#$VM_ID))
# Same derivation as start-vm.sh: /30 per VM, host gets .1, guest .2.
HOST_IP="172.16.0.$(( VM_ID * 4 + 1 ))"
GUEST_IP="172.16.0.$(( VM_ID * 4 + 2 ))"

DIR="${ARGS[1]}"
[ -d "$DIR" ] || { echo "host directory not found: $DIR" >&2; exit 1; }
DIR="$(readlink -f "$DIR")"
MNT="${ARGS[2]:-/workspace}"
case "$MNT" in /*) ;; *) echo "guest_mntpoint must be absolute: $MNT" >&2; exit 1 ;; esac
TAP="fc${VM_ID}"

guest() { # run a command in the guest over the repo's dedicated SSH key
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o BatchMode=yes root@"$GUEST_IP" "$@"
}

guest_alive() { guest true </dev/null >/dev/null 2>&1; }

# --- host-side helpers --------------------------------------------------------

exported_line_exists() { # exact first-field match, no regex-escaping hazards
  sudo test -f "$EXPORTS_FILE" || return 1
  sudo awk -v d="$DIR" 'index($0,d) != 1 {next} $1==d {found=1} END{exit !found}' "$EXPORTS_FILE"
}

next_fsid() { # max existing fsid + 1 — a line COUNT would collide after unmounts
  local max=""
  if sudo test -f "$EXPORTS_FILE"; then
    max="$(sudo grep -oP 'fsid=\K[0-9]+' "$EXPORTS_FILE" 2>/dev/null | sort -n | tail -1)"
  fi
  [ -n "$max" ] || max=99999
  echo $(( max + 1 ))
}

fw_zone() { # zone the TAP is bound to (start-vm.sh binds it to the uplink's
  # zone) — the 2049 rich rule must live THERE, or guest->host NFS is blocked
  # on hosts where the uplink's zone != default zone. Fallback: default zone.
  local z
  z="$(sudo firewall-cmd --get-zone-of-interface="$TAP" 2>/dev/null || true)"
  [ -n "$z" ] && { echo "$z"; return; }
  sudo firewall-cmd --get-default-zone 2>/dev/null || echo public
}

host_export() {
  if ! command -v exportfs >/dev/null 2>&1; then
    echo "missing exportfs — install nfs-utils first (sudo dnf install nfs-utils)" >&2
    exit 1
  fi
  echo "==> host: exporting $DIR to $NFS_SUBNET ($EXPORTS_FILE)"
  sudo mkdir -p /etc/exports.d
  if ! exported_line_exists; then
    printf '%s %s(rw,no_subtree_check,no_root_squash,fsid=%s)\n' \
      "$DIR" "$NFS_SUBNET" "$(next_fsid)" | sudo tee -a "$EXPORTS_FILE" >/dev/null
  fi
  # nfs-server must be up for exportfs to program the kernel's export table.
  systemctl is-active --quiet nfs-server 2>/dev/null || sudo systemctl enable --now nfs-server
  sudo exportfs -ra

  # firewalld: guests must be able to reach the NFS port.
  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    local zone; zone="$(fw_zone)"
    if ! sudo firewall-cmd --zone="$zone" --query-rich-rule "$FW_RULE" >/dev/null 2>&1; then
      echo "==> host: allowing NFS (2049/tcp) from $NFS_SUBNET in firewalld (zone '$zone')"
      sudo firewall-cmd --zone="$zone" --add-rich-rule "$FW_RULE" >/dev/null
      sudo firewall-cmd --permanent --zone="$zone" --add-rich-rule "$FW_RULE" >/dev/null
    fi
  fi

  # SELinux (Fedora): nfsd reading under /home needs the nfs_home_dirs boolean.
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    case "$DIR" in
      /home/*|/root/*)
        if getsebool nfs_home_dirs 2>/dev/null | grep -q ' off$'; then
          echo "==> host: enabling SELinux nfs_home_dirs (export under /home)"
          sudo setsebool -P nfs_home_dirs on
        fi
        ;;
    esac
  fi
}

host_unexport() {
  if sudo test -f "$EXPORTS_FILE" && exported_line_exists; then
    echo "==> host: removing $DIR from $EXPORTS_FILE"
    local tmp; tmp="$(mktemp)"
    sudo awk -v d="$DIR" '$1 != d' "$EXPORTS_FILE" >"$tmp" || true
    if [ -s "$tmp" ]; then
      sudo install -m 644 -o root -g root "$tmp" "$EXPORTS_FILE"
    else
      sudo rm -f "$EXPORTS_FILE"
    fi
    rm -f "$tmp"
    sudo exportfs -ra
  fi
  # The firewalld rule and nfs-server stay: they're shared by every VM.
}

# --- go -----------------------------------------------------------------------

if ! guest_alive; then
  echo "VM $VM_ID not reachable at $GUEST_IP — start it with ./start-vm.sh $VM_ID first" >&2
  exit 1
fi

if [ "$UNMOUNT" = 1 ]; then
  if guest "mountpoint -q '$MNT'"; then
    echo "==> guest: unmounting $HOST_IP:$DIR from $MNT"
    guest "umount '$MNT'" || {
      echo "umount failed (busy?). Processes holding it:" >&2
      guest "grep '$MNT' /proc/*/cwd /proc/*/root 2>/dev/null" || true
      exit 1
    }
  else
    echo "==> guest: $MNT is not a mountpoint (nothing to do)"
  fi
  host_unexport
  echo "==> done: $DIR no longer shared with VM $VM_ID"
  exit 0
fi

host_export

# --- guest mount --------------------------------------------------------------

if ! guest "test -x /sbin/mount.nfs -o -x /usr/sbin/mount.nfs"; then
  echo "guest has no mount.nfs — run './update-firecracker.sh agent' to rebuild" >&2
  echo "the image with nfs-common, or install it in the guest: apt-get install -y nfs-common" >&2
  exit 1
fi

if guest "mountpoint -q '$MNT'"; then
  echo "==> guest: $MNT is already a mountpoint (leaving it as-is)"
else
  echo "==> guest: mounting $HOST_IP:$DIR at $MNT"
  guest "mkdir -p '$MNT' && mount -t nfs4 '$HOST_IP:$DIR' '$MNT'"
fi

# Verify read-write (also proves no_root_squash works for guest root).
guest "touch '$MNT/.fc-share-test' && rm -f '$MNT/.fc-share-test'" || {
  echo "mount succeeded but the write test failed — check no_root_squash on the export" >&2
  exit 1
}

echo "==> done: $DIR is live in VM $VM_ID at $MNT"
