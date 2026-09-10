#!/usr/bin/env bash
# lib-fcnet.sh — shared helpers for the firecracker-scripts.
#
# Sourced (never executed) by start-vm.sh, stop-vm.sh, list-vms.sh and
# share-dir.sh, so that the VM-id derivation, the API socket location, the SSH
# options and the host firewall ruleset are defined in exactly one place. Four
# scripts disagreeing about any of those is how a VM ends up unreachable, or a
# teardown leaves rules behind.
#
# Callers set FC_DIR before sourcing.

# The whole VM range. Each VM id owns one /30 out of it (host .1, guest .2).
FC_SUBNET="${FC_SUBNET:-172.16.0.0/24}"
FC_MAX_VM_ID=63

fc_die() { echo "$*" >&2; exit 1; }

# --- vm id + address derivation ----------------------------------------------

# Echo the normalized id, or exit. 10# defuses "08" being read as bad octal.
fc_validate_vm_id() {
  local id="$1"
  if ! [[ "$id" =~ ^[0-9]+$ ]] || (( 10#$id > FC_MAX_VM_ID )); then
    fc_die "VM_ID must be an integer in 0..${FC_MAX_VM_ID} (got: '$id')"
  fi
  echo $((10#$id))
}

fc_guest_ip() { echo "172.16.0.$(( 2 + $1 * 4 ))"; }
fc_host_ip()  { echo "172.16.0.$(( 1 + $1 * 4 ))"; }
fc_tap()      { echo "fc$1"; }

# --- API socket ---------------------------------------------------------------

# Firecracker's API socket is a full control channel: anything that can connect
# to it can attach arbitrary host files as guest drives and dump guest memory.
# Its mode comes from the umask, so /tmp only keeps other users out by accident
# (a 002 umask would make it group-connectable). Put it in a 0700 directory
# instead. FC_SOCKET_DIR still overrides, for callers that need a fixed path.
fc_socket_dir() {
  if [ -n "${FC_SOCKET_DIR:-}" ]; then echo "$FC_SOCKET_DIR"; return; fi
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    echo "$XDG_RUNTIME_DIR/firecracker"
  else
    echo "/tmp/firecracker-$(id -u)"
  fi
}

fc_ensure_socket_dir() {
  local d; d="$(fc_socket_dir)"
  mkdir -p "$d" || fc_die "cannot create socket dir: $d"
  chmod 700 "$d"
  echo "$d"
}

# Resolve the socket for an id. Prefers the current location but falls back to
# the pre-hardening /tmp path, so a VM booted by an older start-vm.sh can still
# be listed and stopped by these scripts rather than being orphaned.
fc_api_socket() {
  local id="$1" sock legacy
  if [ -n "${API_SOCKET:-}" ]; then echo "$API_SOCKET"; return; fi
  sock="$(fc_socket_dir)/firecracker-vm${id}.sock"
  legacy="/tmp/firecracker-vm${id}.sock"
  if [ ! -S "$sock" ] && [ -S "$legacy" ]; then echo "$legacy"; else echo "$sock"; fi
}

# --- ssh ----------------------------------------------------------------------

# Guest host keys are baked into the image at build time, so they are stable
# across boots and identical for every VM built from it: trust-on-first-use in a
# repo-local known_hosts gives real verification without touching ~/.ssh.
# update-firecracker.sh deletes this file when it rebuilds the image, since the
# rebuild regenerates the host keys.
fc_known_hosts() { echo "${FC_KNOWN_HOSTS:-$FC_DIR/.known_hosts}"; }

# Sets the FC_SSH_OPTS array. accept-new records an unseen host key but still
# refuses a CHANGED one, which is the case worth catching (something else
# answering at the guest's address).
fc_ssh_opts() {
  FC_SSH_OPTS=(
    -o "UserKnownHostsFile=$(fc_known_hosts)"
    -o StrictHostKeyChecking=accept-new
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o LogLevel=ERROR
  )
}

# --- path validation ----------------------------------------------------------

# /etc/exports is whitespace-separated with no quoting, so a directory
# containing a space silently exports its PARENT to an extra "client". These
# paths are also interpolated into guest-side shell commands. Refuse anything
# that can't survive both intact.
fc_reject_unsafe_path() {
  local p="$1" what="${2:-path}"
  case "$p" in
    *[[:space:]]*)  fc_die "$what must not contain whitespace (NFS /etc/exports cannot quote it): $p" ;;
    *\'*|*\"*|*\\*) fc_die "$what must not contain quotes or backslashes: $p" ;;
    *'#'*)          fc_die "$what must not contain '#' (comment character in /etc/exports): $p" ;;
  esac
  case "$p" in
    *[![:print:]]*) fc_die "$what must not contain control characters: $p" ;;
  esac
}

# --- host firewall ------------------------------------------------------------

# TAP devices that exist right now. The ruleset is rebuilt from this on every
# start and stop, so it always describes the VMs that actually exist instead of
# accumulating a rule per boot the way repeated `nft add rule` did.
fc_live_taps() {
  ip -o link show 2>/dev/null \
    | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -E '^fc[0-9]+$' | sort -V || true
}

# Validate GUEST_HOST_PORTS and echo it as a clean comma-separated list, ready
# for an nft set literal ({ 2049,111 }). Commas and/or spaces both separate;
# anything non-numeric is fatal. start-vm.sh calls this BEFORE creating the TAP
# (a bad value must not die mid-flight and leave a stray device behind), then
# assigns the result back, so fc_nft_apply's second call is a no-op re-check.
fc_guest_host_ports() {
  local ports="${GUEST_HOST_PORTS:-2049}" p
  local -a valid=()
  for p in ${ports//,/ }; do
    [[ "$p" =~ ^[0-9]+$ ]] || fc_die "GUEST_HOST_PORTS must be integers (got: '$p')"
    valid+=("$p")
  done
  [ "${#valid[@]}" -gt 0 ] || fc_die "GUEST_HOST_PORTS must list at least one port"
  local IFS=,
  echo "${valid[*]}"
}

# Rebuild the fc-nat table atomically. Replaces the whole table in one
# transaction, so concurrent VMs never see a window without NAT.
#
# Policy:
#   - guests reach the internet (masqueraded), and nothing else by default
#   - guest <-> guest is DROPPED: each VM is its own trust domain, and the
#     NFS exports of one must not be mountable by another
#   - guests may not reach RFC1918/CGNAT/link-local destinations, i.e. the
#     host's LAN (GUEST_LAN_ACCESS=1 opts out). Services on the host itself
#     are unaffected by this: those are input, not forward.
#   - guest -> host is limited to NFS + ping (GUEST_HOST_PORTS adds ports,
#     GUEST_HOST_FILTER=0 disables the input chain entirely)
#   - packets from a TAP claiming a source outside the VM range are dropped,
#     so a guest cannot spoof its way past any of the above
fc_nft_apply() {
  local taps tapset="" rules_fwd="" chain_input="" ports tmp
  taps="$(fc_live_taps)"
  if [ -n "$taps" ]; then
    tapset="{ $(printf '"%s", ' $taps | sed 's/, $//') }"
  fi

  ports="$(fc_guest_host_ports)"

  # forward chain
  if [ -n "$tapset" ]; then
    rules_fwd+="		iifname $tapset ip saddr != $FC_SUBNET counter drop comment \"anti-spoof\"
"
  fi
  rules_fwd+="		ip saddr $FC_SUBNET ip daddr $FC_SUBNET counter drop comment \"inter-VM isolation\"
"
  if [ "${GUEST_LAN_ACCESS:-0}" != "1" ]; then
    rules_fwd+="		ip saddr $FC_SUBNET ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } counter drop comment \"no guest->LAN\"
"
  fi
  rules_fwd+="		ip saddr $FC_SUBNET counter accept
		ip daddr $FC_SUBNET ct state established,related counter accept"

  # input chain (guest -> host)
  if [ "${GUEST_HOST_FILTER:-1}" != "0" ]; then
    # Loopback first: the host's own TAP address is a local address, so
    # host-local traffic to it arrives on lo with a source in FC_SUBNET and
    # would otherwise hit the catch-all drop at the bottom of this chain.
    chain_input="	chain input {
		type filter hook input priority 0; policy accept;
		iifname \"lo\" counter accept
"
    if [ -n "$tapset" ]; then
      chain_input+="		iifname $tapset ct state established,related counter accept
		iifname $tapset icmp type { echo-request, echo-reply } counter accept
		iifname $tapset tcp dport { $ports } counter accept
		iifname $tapset counter drop comment \"guest->host: NFS and ping only\"
"
    fi
    chain_input+="		ip saddr $FC_SUBNET counter drop comment \"spoofed guest source, off-TAP\"
	}"
  fi

  tmp="$(mktemp)"
  cat >"$tmp" <<NFT
add table ip fc-nat
delete table ip fc-nat
table ip fc-nat {
	chain postrouting {
		type nat hook postrouting priority 100; policy accept;
		ip saddr $FC_SUBNET ip daddr != $FC_SUBNET counter masquerade
	}
	chain forward {
		type filter hook forward priority 0; policy accept;
$rules_fwd
	}
$chain_input
}
NFT

  # Validate before touching the live ruleset: -c parses without applying, so a
  # syntax error is a clear message here instead of a half-configured host.
  # mktemp, not a predictable /tmp name: a pre-planted symlink there would
  # redirect this stderr into whatever file it pointed at.
  local errf; errf="$(mktemp)"
  if ! sudo nft -c -f "$tmp" 2>"$errf"; then
    echo "nftables ruleset rejected by 'nft -c' (nothing was applied):" >&2
    sed 's/^/    /' "$errf" >&2
    echo "    ruleset was:" >&2
    sed 's/^/    /' "$tmp" >&2
    rm -f "$tmp" "$errf"
    exit 1
  fi
  rm -f "$errf"
  sudo nft -f "$tmp" || { rm -f "$tmp"; fc_die "failed to apply nftables ruleset"; }
  rm -f "$tmp"
}
