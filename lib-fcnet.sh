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

# --- ssh key ------------------------------------------------------------------

# The key that reaches VM <id>: its own if it has one, else the shared repo key
# (a shared key means one guest holds root on every guest).
# SSH_KEY in the environment always wins.
fc_ssh_key() { # <vm_id>
  local id="$1" per_vm
  if [ -n "${SSH_KEY:-}" ]; then echo "$SSH_KEY"; return; fi
  per_vm="$FC_DIR/guest-vm${id}.id_rsa"
  if [ -f "$per_vm" ]; then echo "$per_vm"; else echo "$FC_DIR/guest.id_rsa"; fi
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

# Refuse to NFS-export the toolchain itself: that hands the guest write access
# to the scripts the host runs under sudo, plus the kernel, rootfs and guest SSH
# key — an escape that needs no hypervisor bug. Deliberately no override env
# var. Guest-bound repo subdirs (anthropic-config/, claude-sessions/) stay
# exportable.
fc_reject_toolchain_export() { # <resolved-dir>
  local dir="$1" fcdir prefix f
  fcdir="$(realpath -m "$FC_DIR")"
  # dir == the toolchain dir, or an ancestor of it, exports the toolchain.
  # Prefix-compare (not a case glob) so pattern chars can't false-match; strip
  # the trailing slash so "/" itself is caught.
  prefix="${dir%/}"
  if [ "$dir" = "$fcdir" ] || [ "${fcdir#"$prefix"/}" != "$fcdir" ]; then
    fc_die "refusing to export $dir: it is (or contains) the toolchain directory $fcdir.
    That gives the guest write access to start-vm.sh / share-dir.sh / stop-vm.sh
    (which the host runs under sudo), to the kernel and rootfs every VM boots,
    and to the guest SSH key. Point this at the work tree instead, e.g.
        SHARE_DIR=~/work/actual-project ./start-vm.sh
    Repo subdirectories meant for the guest (anthropic-config/, claude-sessions/)
    are still fine to share."
  fi
  # A copy or a sibling checkout is exactly as dangerous as the real thing.
  for f in "$dir"/guest.id_rsa "$dir"/guest-vm*.id_rsa; do
    [ -e "$f" ] || continue
    fc_die "refusing to export $dir: it contains a guest SSH private key ($(basename "$f")),
    which is root on the guests. Move the key out, or export a subdirectory."
  done
  if [ -e "$dir/start-vm.sh" ] && [ -e "$dir/lib-fcnet.sh" ]; then
    fc_die "refusing to export $dir: it looks like a copy of this toolchain
    (start-vm.sh + lib-fcnet.sh). The guest would be able to rewrite scripts the
    host runs under sudo. Export the work tree instead."
  fi
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

# --- rootfs safety ------------------------------------------------------------

# Is this image already attached to a running VM?
#
# Two VMs on one writable rootfs corrupt ext4 (independent page caches, journals
# and allocation bitmaps) and share a read-write code path underneath the
# inter-VM isolation. Refuse to boot instead. fuser is authoritative when
# present; without it, ask each live Firecracker API socket (GET /vm/config)
# what drives it has. Paths compared resolved. Prints the reason and returns 0
# when in use; 1 when free or unanswerable.
fc_rootfs_in_use() { # <image>
  local img="$1" resolved sock cfg p
  resolved="$(readlink -f "$img" 2>/dev/null || echo "$img")"

  if command -v fuser >/dev/null 2>&1 && fuser -s "$resolved" 2>/dev/null; then
    echo "another process has $resolved open (fuser)"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq   >/dev/null 2>&1 || return 1
  for sock in "$(fc_socket_dir)"/firecracker-vm*.sock /tmp/firecracker-vm*.sock; do
    [ -S "$sock" ] || continue
    [ "$sock" = "${API_SOCKET:-}" ] && continue
    cfg="$(curl -sf --max-time 1 --unix-socket "$sock" http://localhost/vm/config 2>/dev/null)" || continue
    # read, not word-split: a path containing a space must still match (missing
    # an in-use image is the dangerous direction).
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ "$(readlink -f "$p" 2>/dev/null || echo "$p")" = "$resolved" ]; then
        echo "the VM on $sock has $resolved attached"
        return 0
      fi
    done < <(printf '%s' "$cfg" | jq -r '[.. | .path_on_host? // empty] | .[]' 2>/dev/null)
  done
  return 1
}

# --- egress allowlist ---------------------------------------------------------

# The fc-nat table is GLOBAL and rebuilt on every start/stop, so the allowlist
# must be remembered (here in FC_DIR, like .fw-forward-added) or stopping any
# VM would silently restore unrestricted egress for the others. Cleared by
# stop-vm.sh when the last VM goes. Line 1: allow spec; line 2: DNS spec.
fc_egress_state_file() { echo "${FC_EGRESS_STATE:-$FC_DIR/.fc-egress-policy}"; }

# Env wins over remembered state, and an explicitly EMPTY GUEST_EGRESS_ALLOW
# means "turn it off" rather than "not specified" — hence +x, not :-.
fc_egress_spec() {
  local f
  if [ -n "${GUEST_EGRESS_ALLOW+x}" ]; then printf '%s\n' "$GUEST_EGRESS_ALLOW"; return; fi
  f="$(fc_egress_state_file)"
  [ -r "$f" ] || return 0
  sed -n '1p' "$f"
}

fc_egress_dns_spec() {
  local f
  if [ -n "${GUEST_EGRESS_DNS+x}" ]; then printf '%s\n' "$GUEST_EGRESS_DNS"; return; fi
  f="$(fc_egress_state_file)"
  if [ -r "$f" ]; then
    local line2; line2="$(sed -n '2p' "$f")"
    [ -n "$line2" ] && { printf '%s\n' "$line2"; return; }
  fi
  echo "1.1.1.1,8.8.8.8"   # matches the resolv.conf baked into the guest image
}

# Called by start-vm.sh before applying the ruleset: the policy this VM started
# with is what the next teardown rebuilds.
fc_egress_persist() {
  local f; f="$(fc_egress_state_file)"
  if [ -z "${GUEST_EGRESS_ALLOW+x}" ]; then return 0; fi   # not specified: leave state alone
  if [ -z "$GUEST_EGRESS_ALLOW" ]; then
    [ -e "$f" ] && echo "==> host: egress allowlist explicitly cleared (was: $(sed -n '1p' "$f"))"
    rm -f "$f"
    return 0
  fi
  ( umask 077; printf '%s\n%s\n' "$GUEST_EGRESS_ALLOW" "$(fc_egress_dns_spec)" >"$f" )
}

fc_egress_forget() { rm -f "$(fc_egress_state_file)"; }

# Resolve an allow spec (hostnames, IPv4 addrs or CIDRs, comma/space separated)
# into a deduplicated list of IPv4 literals. Hostnames are resolved HERE, when
# the ruleset is built: for CDN-fronted names the set rotates, so this controls
# where a guest may dial, not whether an allowed name keeps working. A name
# that does not resolve is skipped with a warning — fails CLOSED, because
# anything not in the set is dropped.
fc_egress_allow_addrs() { # <spec>
  local spec="${1:-}" e ips
  local -a out=()
  [ -n "$spec" ] || return 0
  for e in ${spec//,/ }; do
    case "$e" in
      *[![:alnum:].:_/-]*) fc_die "GUEST_EGRESS_ALLOW: '$e' is not a hostname, IPv4 address or CIDR" ;;
    esac
    if [[ "$e" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
      out+=("$e")
      continue
    fi
    command -v getent >/dev/null 2>&1 || fc_die "GUEST_EGRESS_ALLOW needs getent to resolve '$e'"
    ips="$(getent ahostsv4 "$e" 2>/dev/null | awk '{print $1}' | sort -u)"
    if [ -z "$ips" ]; then
      echo "warning: GUEST_EGRESS_ALLOW: '$e' did not resolve — the guest will NOT reach it" >&2
      continue
    fi
    # shellcheck disable=SC2206  # intentional split: one address per line
    out+=($ips)
  done
  if [ "${#out[@]}" -eq 0 ]; then
    echo "warning: GUEST_EGRESS_ALLOW resolved to no addresses — the guest gets NO egress" >&2
    return 0
  fi
  printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' '
}

# Resolvers the guest may reach on port 53 while the allowlist is active —
# without them, no allowed hostname is reachable by name. Literals only.
fc_egress_dns_addrs() { # <spec>
  local spec="${1:-}" e
  local -a out=()
  for e in ${spec//,/ }; do
    [[ "$e" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] \
      || fc_die "GUEST_EGRESS_DNS must be IPv4 addresses or CIDRs (got: '$e')"
    out+=("$e")
  done
  [ "${#out[@]}" -gt 0 ] || return 0
  printf '%s\n' "${out[@]}" | sort -u | tr '\n' ' '
}

# An allowlist entry inside RFC1918/CGNAT is dropped by the "no guest->LAN"
# rule ABOVE the allowlist rules, so allowing it looks like it works and does
# nothing. Warn rather than let it read as effective.
fc_warn_private_egress() { # <addr>...
  local a priv=""
  [ "${GUEST_LAN_ACCESS:-0}" != "1" ] || return 0
  for a in "$@"; do
    case "$a" in
      10.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|\
      100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) priv="$priv $a" ;;
    esac
  done
  [ -n "$priv" ] || return 0
  echo "warning: these allowlisted addresses are RFC1918/CGNAT:$priv" >&2
  echo "    the 'no guest->LAN' rule drops them before the allowlist is consulted." >&2
  echo "    Add GUEST_LAN_ACCESS=1 if the guest really should reach your LAN." >&2
}

# Emit an nft named-set definition. `flags interval` so CIDRs and plain
# addresses share one set; an empty set + the default-deny rule means "no
# egress" — fail-closed.
fc_nft_set() { # <name> <addr>...
  local name="$1"; shift
  local elems=""
  [ "$#" -gt 0 ] && elems="$(printf '%s, ' "$@" | sed 's/, $//')"
  printf '\tset %s {\n\t\ttype ipv4_addr\n\t\tflags interval\n' "$name"
  [ -n "$elems" ] && printf '\t\telements = { %s }\n' "$elems"
  printf '\t}\n'
}

# Rebuild the fc-nat table atomically. Replaces the whole table in one
# transaction, so concurrent VMs never see a window without NAT.
#
# Policy:
#   - guests reach the internet (masqueraded), and nothing else by default
#   - GUEST_EGRESS_ALLOW=<hostnames/addrs> narrows that to an allowlist and
#     drops the rest (default: unset — unrestricted egress). Remembered in
#     .fc-egress-policy so stop-vm.sh's rebuild keeps it
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
  local taps tapset="" rules_fwd="" chain_input="" sets="" ports tmp
  local allow_addrs="" dns_addrs="" egress_spec=""
  # Env wins, else the remembered policy (see fc_egress_state_file).
  egress_spec="$(fc_egress_spec)"
  taps="$(fc_live_taps)"
  if [ -n "$taps" ]; then
    tapset="{ $(printf '"%s", ' $taps | sed 's/, $//') }"
  fi

  ports="$(fc_guest_host_ports)"

  # Opt-in: off unless a policy is set, so the default ruleset is unchanged.
  if [ -n "$egress_spec" ]; then
    allow_addrs="$(fc_egress_allow_addrs "$egress_spec")"
    dns_addrs="$(fc_egress_dns_addrs "$(fc_egress_dns_spec)")"
    # shellcheck disable=SC2086  # intentional split into addresses
    fc_warn_private_egress $allow_addrs
    # shellcheck disable=SC2086  # intentional split into set elements
    # Trailing newline is part of the literal: keeps the ruleset byte-identical
    # when the allowlist is off.
    sets="$(fc_nft_set egress_allow $allow_addrs)
$(fc_nft_set egress_dns $dns_addrs)
"
  fi

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
  # Allowlist rules go before the blanket accept; the default-deny is what
  # makes the allowlist a control. DNS matched on resolver address so port 53
  # cannot be used as a tunnel to an arbitrary host.
  if [ -n "$egress_spec" ]; then
    rules_fwd+="		ip saddr $FC_SUBNET ip daddr @egress_dns udp dport 53 counter accept comment \"egress allowlist: DNS\"
		ip saddr $FC_SUBNET ip daddr @egress_dns tcp dport 53 counter accept comment \"egress allowlist: DNS\"
		ip saddr $FC_SUBNET ip daddr @egress_allow counter accept comment \"egress allowlist\"
		ip saddr $FC_SUBNET counter drop comment \"egress allowlist: default deny\"
"
  else
    rules_fwd+="		ip saddr $FC_SUBNET counter accept
"
  fi
  rules_fwd+="		ip daddr $FC_SUBNET ct state established,related counter accept"

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
${sets}	chain postrouting {
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
  if [ -n "$egress_spec" ]; then
    echo "==> host: egress allowlist active — guests reach only: ${allow_addrs:-<nothing>}"
    echo "    (resolved now from: $egress_spec; DNS allowed to: ${dns_addrs:-<nothing>})"
  fi
}
