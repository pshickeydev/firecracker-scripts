#!/usr/bin/env bash
# auth-login.sh — mint Anthropic platform credentials on the host for in-VM agents.
#
# Usage: ./auth-login.sh [extra `ant auth login` args]
#   e.g. ./auth-login.sh --workspace-id <id>
#
# Wraps the anthropic platform CLI (ant):
#   ANTHROPIC_CONFIG_DIR=<repo>/anthropic-config ant auth login --profile fc-agents
#
# Why a dedicated profile + repo-local config dir:
# - Claude Code in the guest reads the same profile files natively
#   (ANTHROPIC_PROFILE=fc-agents), refreshes tokens itself via the client_id
#   stored in the profile, and adds the required oauth-2025-04-20 beta header.
# - The config dir is shared into the VM over NFS (see share-dir.sh), so there
#   is exactly ONE copy of the credentials. Refresh tokens can ROTATE on
#   renewal; two copies would orphan each other. Never `scp` these files.
# - Keeping the guest on its own profile means host-side `ant` usage can never
#   compete for (and rotate away) the guest's refresh token.
#
# anthropic-config/ contains live refresh tokens — it is gitignored; treat as secret.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_DIR="${FC_DIR:-$SCRIPT_DIR}"
PROFILE="${AGENT_PROFILE:-fc-agents}"
CONFIG_DIR="${ANTHROPIC_CONFIG_DIR:-$FC_DIR/anthropic-config}"

# --- locate (or install) ant --------------------------------------------------

ANT_BIN="$(command -v ant 2>/dev/null || true)"
if [ -z "$ANT_BIN" ] && [ -x "$HOME/go/bin/ant" ]; then
  ANT_BIN="$HOME/go/bin/ant"
fi

if [ -z "$ANT_BIN" ]; then
  echo "==> ant not found — installing via go (github.com/anthropics/anthropic-cli)"
  command -v go >/dev/null 2>&1 || {
    echo "go (>=1.22) is required to install ant; install it or put 'ant' on PATH" >&2
    exit 1
  }
  GOBIN="${GOBIN:-$HOME/go/bin}" go install github.com/anthropics/anthropic-cli/cmd/ant@latest
  ANT_BIN="${GOBIN:-$HOME/go/bin}/ant"
fi

# --- login --------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

echo "==> logging in (profile '$PROFILE', config dir: $CONFIG_DIR)"
echo "    a browser window will open for the Anthropic OAuth flow"
ANTHROPIC_CONFIG_DIR="$CONFIG_DIR" "$ANT_BIN" auth login --profile "$PROFILE" "$@"

echo
echo "==> verifying"
ANTHROPIC_CONFIG_DIR="$CONFIG_DIR" "$ANT_BIN" auth status || true

cat <<EOF

==> Next steps (per session):
  1. SHARE_DIR=<your-workspace> ./start-vm.sh          # boots VM + NFS-mounts it at /workspace
  2. ./share-dir.sh 0 '$CONFIG_DIR' /root/.config/anthropic   # share the credentials (once)
  3. (optional) mkdir -p $FC_DIR/claude-sessions && ./share-dir.sh 0 '$FC_DIR/claude-sessions' /root/.claude
       # persists session transcripts to the host instead of the guest's ext4 rootfs
  4. ssh -i $FC_DIR/guest.id_rsa -o UserKnownHostsFile=$FC_DIR/.known_hosts root@172.16.0.2
       cd /workspace && ANTHROPIC_PROFILE=$PROFILE claude

    anthropic-config/ holds live refresh tokens: never commit it, never copy it
    into the VM by hand — always mount it over NFS so there is one shared copy.
EOF
