#!/usr/bin/env bash
# prereqs.sh — check that this host can run Firecracker + these scripts.
#
# Usage: ./prereqs.sh
# Exits 0 if everything is present, 1 if something is missing. Prints a clear
# report so a fresh checkout is easy to diagnose on a new machine.
set -euo pipefail

PASS=0
FAIL=0

check_cmd() { # cmd -- purpose
  local cmd="$1" purpose="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-14s %s\n' "$cmd" "$purpose"
    PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %-14s %s (missing)\n' "$cmd" "$purpose"
    FAIL=$((FAIL + 1))
  fi
}

check_file() { # path -- purpose
  local path="$1" purpose="$2"
  if [ -e "$path" ]; then
    printf '  \033[32m✓\033[0m %-14s %s\n' "$path" "$purpose"
    PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %-14s %s (missing)\n' "$path" "$purpose"
    FAIL=$((FAIL + 1))
  fi
}

check_kvm() {
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    printf '  \033[32m✓\033[0m %-14s readable+writable by you\n' "/dev/kvm"
    PASS=$((PASS + 1))
  elif [ -e /dev/kvm ]; then
    printf '  \033[33m!\033[0m %-14s present but not accessible (add yourself to the kvm group or use sudo)\n' "/dev/kvm"
    FAIL=$((FAIL + 1))
  else
    printf '  \033[31m✗\033[0m %-14s not present (is KVM enabled in your kernel/BIOS?)\n' "/dev/kvm"
    FAIL=$((FAIL + 1))
  fi
}

# Optional checks report but don't gate: the core VM flow works without them.
check_opt() { # cmd -- purpose
  local cmd="$1" purpose="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-14s %s\n' "$cmd" "$purpose"
  else
    printf '  \033[33m!\033[0m %-14s %s (optional — not installed)\n' "$cmd" "$purpose"
  fi
}

echo "Checking prerequisites for firecracker-scripts"
echo
echo "Commands:"
check_cmd firecracker  "Firecracker VMM (install via ./update-firecracker.sh binary)"
check_cmd curl         "HTTP API calls + downloads"
check_cmd jq           "JSON building for the API"
check_cmd ip           "TAP device + address setup"
check_cmd nft          "NAT/masquerade rules (nftables)"
check_cmd setsid       "detached firecracker launch"
check_cmd ping         "guest reachability check"
check_cmd pgrep        "process lookup (list-vms.sh / stop-vm.sh)"
check_cmd pkill        "force-kill firecracker (stop-vm.sh)"
check_cmd wget         "image downloads"
check_cmd unsquashfs   "rootfs extraction (squashfs-tools)"
check_cmd mkfs.ext4    "rootfs image build (e2fsprogs)"
check_cmd ssh-keygen   "guest SSH keypair generation"
check_cmd sha256sum    "download checksum verification (coreutils)"
check_cmd tar          "release archive extraction"
check_cmd file         "image sanity check"
echo
# Agent-session extras (host-dir sharing + auth for in-VM Claude Code).
echo "Agent-session extras (Claude Code in the guest):"
check_cmd ssh         "run commands in the guest (share-dir.sh)"
check_cmd exportfs    "NFS host-dir sharing (nfs-utils)"
check_opt firewall-cmd "firewalld NFS port rules (firewalld)"
check_opt getenforce  "SELinux state (Fedora)"
check_opt go          'installs the `ant` CLI for Anthropic auth (auth-login.sh)'
echo
echo "Kernel + devices:"
check_kvm
check_file /dev/net/tun "TUN/TAP device for guest networking (modprobe tun if missing)"
echo

if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m%s\033[0m: %d check(s) failed, %d passed\n' "FAIL" "$FAIL" "$PASS"
  echo
  echo "Hints:"
  echo "  - install firecracker:     ./update-firecracker.sh binary"
  echo "  - fetch kernel + rootfs:  ./update-firecracker.sh images"
  echo "  - build the agent image: ./update-firecracker.sh agent"
  echo "  - on Fedora:              sudo dnf install squashfs-tools e2fsprogs nftables nfs-utils"
  echo "  - KVM access:             sudo usermod -aG kvm \$USER  (then re-login)"
  echo "  - TUN module:             sudo modprobe tun"
  exit 1
fi

printf '\033[32m%s\033[0m: all %d checks passed\n' "OK" "$PASS"
exit 0
