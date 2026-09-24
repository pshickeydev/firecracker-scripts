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
# Host side:  adds "<hostdir> <guest-ip>/32(rw,no_subtree_check,root_squash,anonuid=<you>,anongid=<you>,fsid=N)"
#            to /etc/exports.d/fc-agents.exports, re-exports, and (if firewalld
#            is active) allows NFS (2049/tcp) from that ONE guest.
#
#            The export is scoped to the single VM being shared with, not to the
#            172.16.0.0/24 range: every VM is its own trust domain, and a
#            subnet-wide export would let any VM mount every other VM's
#            workspace — including anthropic-config/, which holds live refresh
#            tokens. A directory shared with several VMs gets one client entry
#            per VM on the same line, which is how NFS expresses that.
#
#            root_squash + anonuid/anongid: the guest is root-only, but guest
#            root does NOT become host root on the export — it acts as YOUR
#            host uid/gid. You get full read/write to your own files, and every
#            file created during a session (workspace edits, .claude/ project
#            dirs, token refreshes in anthropic-config) is owned by you on
#            the host — no sudo needed to clean up, and a smaller blast
#            radius than no_root_squash.
#
#            Refused outright: the toolchain directory (or any ancestor, or any
#            copy carrying a guest SSH key) — the guest would be able to rewrite
#            scripts the host runs under sudo, and to backdoor the rootfs and
#            kernel every future VM boots. Guest-bound repo subdirs
#            (anthropic-config/, claude-sessions/) remain shareable.
# Guest side: over the existing SSH path: mkdir + mount -t nfs4 172.16.0.x:<hostdir>.
#            Refuses if the mountpoint is already a mountpoint of a DIFFERENT
#            source (see the guest-mount section) — that would silently
#            validate the old mount as the new share.
#
# --unmount finds the guest mount by NFS source (HOST_IP:dir), so the
# guest mountpoint argument is optional for it and may be omitted even when
# the share was mounted somewhere other than the default /workspace.
#
# NFS is stateless, so stop-vm.sh needs no changes; use --unmount to retire an
# export cleanly. The nfs-server service stays enabled (shared by every VM).
# --unmount also works when the guest is unreachable (stopped or crashed):
# there is no mount left to remove on that side, but the export entry and the
# per-guest firewalld rule are retired anyway — nothing else would remove them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
# shellcheck source=lib-fcnet.sh
source "$SCRIPT_DIR/lib-fcnet.sh"

EXPORTS_FILE="/etc/exports.d/fc-agents.exports"
# Guest root acts as the invoking host user on the export (see header comment).
EXPORT_UID="$(id -u)"
EXPORT_GID="$(id -g)"
EXPORT_OPTS="rw,no_subtree_check,root_squash,anonuid=$EXPORT_UID,anongid=$EXPORT_GID"

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
VM_ID="$(fc_validate_vm_id "${ARGS[0]}")" || exit 1
HOST_IP="$(fc_host_ip "$VM_ID")"
GUEST_IP="$(fc_guest_ip "$VM_ID")"
CLIENT="${GUEST_IP}/32"
# This VM's key if it has one, else the shared key (SSH_KEY env wins — see
# fc_ssh_key).
SSH_KEY="$(fc_ssh_key "$VM_ID")"

DIR="${ARGS[1]}"
if [ "$UNMOUNT" = 1 ]; then
  # --unmount: the path is a lookup key into /etc/exports, not something to
  # read. The directory may have been deleted since it was shared — the export
  # entry and firewalld rule must still be retireable (see the go section),
  # so realpath -m (no existence requirement), and no -d check.
  DIR="$(realpath -m "$DIR")"
else
  [ -d "$DIR" ] || { echo "host directory not found: $DIR" >&2; exit 1; }
  DIR="$(readlink -f "$DIR")"
fi
# /etc/exports has no quoting: a path with a space would export its PARENT, and
# to an extra bogus "client" besides. Refuse rather than silently over-share.
fc_reject_unsafe_path "$DIR" "host directory"
# Toolchain-export guard. Share path only: --unmount must stay able
# to retire pre-guard exports.
if [ "$UNMOUNT" != 1 ]; then
  fc_reject_toolchain_export "$DIR"
fi
MNT="${ARGS[2]:-/workspace}"
case "$MNT" in /*) ;; *) echo "guest_mntpoint must be absolute: $MNT" >&2; exit 1 ;; esac
fc_reject_unsafe_path "$MNT" "guest mountpoint"
TAP="$(fc_tap "$VM_ID")"

FW_RULE="rule family=ipv4 source address=${CLIENT} port port=2049 protocol=tcp accept"
FW_RULE_LEGACY="rule family=ipv4 source address=${FC_SUBNET} port port=2049 protocol=tcp accept"

fc_ssh_opts
guest() { # run a command in the guest over the repo's dedicated SSH key
  ssh -i "$SSH_KEY" "${FC_SSH_OPTS[@]}" root@"$GUEST_IP" "$@"
}

guest_alive() { guest true </dev/null >/dev/null 2>&1; }

# --- host-side helpers --------------------------------------------------------

export_line() { # echo the current line for $DIR, if any
  sudo test -f "$EXPORTS_FILE" || return 0
  sudo awk -v d="$DIR" '$1==d {print; exit}' "$EXPORTS_FILE" 2>/dev/null || true
}

next_fsid() { # max existing fsid + 1 — a line COUNT would collide after unmounts
  local max=""
  if sudo test -f "$EXPORTS_FILE"; then
    max="$(sudo grep -oP 'fsid=\K[0-9]+' "$EXPORTS_FILE" 2>/dev/null | sort -n | tail -1)"
  fi
  [ -n "$max" ] || max=99999
  echo $(( max + 1 ))
}

write_exports() { # <tmpfile> — install atomically, or drop the file if empty
  local tmp="$1"
  if [ -s "$tmp" ]; then
    sudo install -m 644 -o root -g root "$tmp" "$EXPORTS_FILE"
  else
    sudo rm -f "$EXPORTS_FILE"
  fi
  rm -f "$tmp"
}

fw_zone() { # zone the TAP is bound to (start-vm.sh binds it to the uplink's
  # zone) — the 2049 rich rule must live THERE, or guest->host NFS is blocked
  # on hosts where the uplink's zone != default zone. Fallback: default zone.
  local z
  z="$(sudo firewall-cmd --get-zone-of-interface="$TAP" 2>/dev/null || true)"
  [ -n "$z" ] && { echo "$z"; return; }
  sudo firewall-cmd --get-default-zone 2>/dev/null || echo public
}

firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1
}

prune_stale_exports() { # drop entries whose host directory no longer exists
  # (keeps exportfs -ra from choking on dirs deleted between sessions)
  sudo test -f "$EXPORTS_FILE" || return 0
  local tmp; tmp="$(mktemp)"
  sudo cat "$EXPORTS_FILE" | while read -r d rest; do
    [ -n "$d" ] || continue
    if [ ! -d "$d" ]; then
      echo "==> host: pruning stale export: $d (directory no longer exists)" >&2
      continue
    fi
    printf '%s %s\n' "$d" "$rest"
  done > "$tmp"
  if ! sudo cmp -s "$EXPORTS_FILE" "$tmp" 2>/dev/null; then
    write_exports "$tmp"
  else
    rm -f "$tmp"
  fi
}

# Rebuild the client list for $DIR: keep other VMs' entries, replace ours, and
# drop any legacy subnet-wide entry written by an older share-dir.sh.
rebuild_clients() { # <existing-line> <fsid> -> echoes the new line
  local line="$1" fsid="$2" tok first=1
  local -a keep=()
  for tok in $line; do
    if [ "$first" = 1 ]; then first=0; continue; fi   # field 1 is the path
    case "$tok" in
      "${CLIENT}("*)      continue ;;   # ours — replaced below
      "${FC_SUBNET}("*)
        echo "==> host: narrowing legacy subnet-wide export of $DIR ($FC_SUBNET -> per-VM)" >&2
        echo "    other VMs sharing this directory must re-run ./share-dir.sh" >&2
        continue ;;
      *) keep+=("$tok") ;;
    esac
  done
  keep+=("${CLIENT}(${EXPORT_OPTS},fsid=${fsid})")
  printf '%s %s\n' "$DIR" "${keep[*]}"
}

host_export() {
  if ! command -v exportfs >/dev/null 2>&1; then
    echo "missing exportfs — install nfs-utils first (sudo dnf install nfs-utils)" >&2
    exit 1
  fi
  echo "==> host: exporting $DIR to $CLIENT only ($EXPORTS_FILE)"
  sudo mkdir -p /etc/exports.d
  prune_stale_exports

  local existing fsid newline tmp
  existing="$(export_line)"
  if [ -n "$existing" ]; then
    fsid="$(printf '%s\n' "$existing" | grep -oP 'fsid=\K[0-9]+' | head -1 || true)"
  fi
  [ -n "${fsid:-}" ] || fsid="$(next_fsid)"
  newline="$(rebuild_clients "$existing" "$fsid")"

  tmp="$(mktemp)"
  if [ -n "$existing" ]; then
    sudo awk -v d="$DIR" -v r="$newline" '{print ($1==d) ? r : $0}' "$EXPORTS_FILE" >"$tmp"
  else
    { sudo test -f "$EXPORTS_FILE" && sudo cat "$EXPORTS_FILE"; printf '%s\n' "$newline"; } >"$tmp" 2>/dev/null \
      || printf '%s\n' "$newline" >"$tmp"
  fi
  write_exports "$tmp"

  # nfs-server must be up for exportfs to program the kernel's export table.
  systemctl is-active --quiet nfs-server 2>/dev/null || sudo systemctl enable --now nfs-server
  sudo exportfs -ra

  # firewalld: this guest must be able to reach the NFS port. Runtime-only and
  # per-guest: a permanent subnet-wide rule outlives every VM that needed it.
  if firewalld_active; then
    local zone; zone="$(fw_zone)"
    if sudo firewall-cmd --zone="$zone" --query-rich-rule "$FW_RULE_LEGACY" >/dev/null 2>&1; then
      echo "==> host: removing legacy subnet-wide NFS rule from firewalld (zone '$zone')"
      sudo firewall-cmd --zone="$zone" --remove-rich-rule "$FW_RULE_LEGACY" >/dev/null 2>&1 || true
      sudo firewall-cmd --permanent --zone="$zone" --remove-rich-rule "$FW_RULE_LEGACY" >/dev/null 2>&1 || true
    fi
    if ! sudo firewall-cmd --zone="$zone" --query-rich-rule "$FW_RULE" >/dev/null 2>&1; then
      echo "==> host: allowing NFS (2049/tcp) from $CLIENT in firewalld (zone '$zone')"
      sudo firewall-cmd --zone="$zone" --add-rich-rule "$FW_RULE" >/dev/null
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
  local existing tmp remaining
  existing="$(export_line)"
  if [ -n "$existing" ]; then
    echo "==> host: removing $CLIENT from the export of $DIR"
    # Drop only OUR client entry; other VMs sharing this dir keep theirs.
    remaining="$(printf '%s\n' "$existing" | tr ' ' '\n' | tail -n +2 \
                 | grep -v "^${CLIENT}(" || true)"
    tmp="$(mktemp)"
    if [ -n "$remaining" ]; then
      local newline; newline="$DIR $(printf '%s ' $remaining | sed 's/ $//')"
      sudo awk -v d="$DIR" -v r="$newline" '{print ($1==d) ? r : $0}' "$EXPORTS_FILE" >"$tmp"
    else
      echo "    (last client for this directory — dropping the export entirely)"
      sudo awk -v d="$DIR" '$1 != d' "$EXPORTS_FILE" >"$tmp" || true
    fi
    write_exports "$tmp"
    sudo exportfs -ra
  fi

  # Drop this guest's firewalld rule once nothing is exported to it any more.
  if firewalld_active; then
    if ! sudo grep -qF "${CLIENT}(" "$EXPORTS_FILE" 2>/dev/null; then
      local zone; zone="$(fw_zone)"
      if sudo firewall-cmd --zone="$zone" --query-rich-rule "$FW_RULE" >/dev/null 2>&1; then
        echo "==> host: removing NFS rule for $CLIENT from firewalld (zone '$zone')"
        sudo firewall-cmd --zone="$zone" --remove-rich-rule "$FW_RULE" >/dev/null 2>&1 || true
      fi
    fi
  fi
  # nfs-server stays enabled: it is shared by every VM.
}

# --- go -----------------------------------------------------------------------

if [ "$UNMOUNT" = 1 ]; then
  if guest_alive; then
    # Find the actual mountpoint(s) by NFS SOURCE, not by the (possibly
    # defaulted) MNT argument: shares are routinely mounted somewhere other
    # than /workspace (e.g. /root/.claude), and a bare `--unmount <VM> <dir>`
    # would otherwise default to /workspace, miss the real mount, and drop the
    # export out from under a still-live guest mount. An explicitly passed
    # MNT is included too (covers mounts whose recorded source differs).
    SRC="$HOST_IP:$DIR"
    declare -A TARGETS=() # tgt -> its actual nfs4 source (may differ from SRC
    #                      # when matched via an explicitly passed MNT)
    # findmnt -rn separates columns with a space (not a tab) — split on
    # both so either output format parses.
    while IFS=$' \t' read -r tgt src; do
      [ -n "${tgt:-}" ] || continue
      if [ "$src" = "$SRC" ] || { [ -n "${ARGS[2]:-}" ] && [ "$tgt" = "$MNT" ]; }; then
        TARGETS["$tgt"]="$src"
      fi
    done < <(guest "findmnt -rn -t nfs4 -o TARGET,SOURCE" </dev/null 2>/dev/null || true)
    if [ "${#TARGETS[@]}" -gt 0 ]; then
      # Deepest paths first, so nested mounts unmount cleanly. while-read (not
      # for-in) so a target containing whitespace is not word-split.
      while read -r tgt; do
        echo "==> guest: unmounting ${TARGETS["$tgt"]} from $tgt"
        guest "umount '$tgt'" </dev/null || {
          echo "umount failed (busy?). Processes holding it:" >&2
          guest "grep '$tgt' /proc/*/cwd /proc/*/root 2>/dev/null" </dev/null || true
          exit 1
        }
      done < <(printf '%s\n' "${!TARGETS[@]}" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
    else
      echo "==> guest: no NFS mount of $SRC found (nothing to do)"
    fi
  else
    # Unreachable guest (stopped or crashed): nothing holds a mount any more,
    # but the host-side export and firewalld rule would linger forever —
    # --unmount is the only script path that removes them, and it must not
    # require resurrecting the VM to do its job.
    echo "==> guest: VM $VM_ID not reachable at $GUEST_IP — retiring the host side only" >&2
    echo "    (a stopped or crashed guest keeps no mount; its export entry and" >&2
    echo "     firewalld rule are being removed now)" >&2
  fi
  host_unexport
  echo "==> done: $DIR no longer shared with VM $VM_ID"
  exit 0
fi

if ! guest_alive; then
  echo "VM $VM_ID not reachable at $GUEST_IP — start it with ./start-vm.sh $VM_ID first" >&2
  exit 1
fi

host_export

# --- guest mount --------------------------------------------------------------

if ! guest "test -x /sbin/mount.nfs -o -x /usr/sbin/mount.nfs"; then
  echo "guest has no mount.nfs — the image predates the nfs-common install or wasn't" >&2
  echo "built by the agent step. Rebuild it: ./update-firecracker.sh agent (the guest" >&2
  echo "ships no working package manager, so it can't be installed at runtime)" >&2
  exit 1
fi

if guest "mountpoint -q '$MNT'"; then
  # "Already a mountpoint" is only a no-op if it is OUR export. A different
  # NFS source (or any other filesystem) mounted there means a second host
  # dir is being pointed at a path an existing share already occupies — and
  # the write test below would silently validate the OLD mount and report
  # THIS share as live. Refuse instead, and suggest --unmount, which finds
  # the real mountpoint by source so no path guessing is needed.
  CUR_SRC="$(guest "findmnt -rn -t nfs4 -o SOURCE --target '$MNT'" </dev/null 2>/dev/null || true)"
  if [ "$CUR_SRC" = "$HOST_IP:$DIR" ]; then
    echo "==> guest: $MNT already mounts $CUR_SRC (leaving it as-is)"
  else
    echo "refusing: $MNT is already a mountpoint of ${CUR_SRC:-<not an NFSv4 mount>}," >&2
    echo "    not $HOST_IP:$DIR. Retire the existing share first — --unmount finds" >&2
    echo "    its guest mountpoint(s) by source, no argument guessing needed:" >&2
    if [ -n "$CUR_SRC" ]; then
      echo "        ./share-dir.sh --unmount $VM_ID '${CUR_SRC#*:}'" >&2
    else
      echo "        (whatever is mounted at $MNT is not one of this script's NFS" >&2
      echo "         shares — unmount it inside the guest by hand)" >&2
    fi
    exit 1
  fi
else
  echo "==> guest: mounting $HOST_IP:$DIR at $MNT"
  guest "mkdir -p '$MNT' && mount -t nfs4 '$HOST_IP:$DIR' '$MNT'"
fi

# Verify read-write (also proves the anonuid mapping works for guest root).
guest "touch '$MNT/.fc-share-test' && rm -f '$MNT/.fc-share-test'" || {
  echo "mount succeeded but the write test failed — check root_squash/anonuid on the export" >&2
  exit 1
}

echo "==> done: $DIR is live in VM $VM_ID at $MNT"
