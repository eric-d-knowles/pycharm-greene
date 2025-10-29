#!/usr/bin/env bash

# Set working directory to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Local launcher - uploads and runs remote script, then creates tunnel
set -Eeuo pipefail

# Setup colors - professional terminal palette
if [[ -t 1 && -z ${NO_COLOR-} ]]; then
  # Text styles
  BLD=$'\e[1m'    # Bold
  DIM=$'\e[2m'    # Dim
  RST=$'\e[0m'    # Reset

  # Semantic colors
  RED=$'\e[31m'   # Errors
  GRN=$'\e[32m'   # Success
  YEL=$'\e[33m'   # Warnings/Info
  BLU=$'\e[34m'   # Prompts/Labels
  MAG=$'\e[35m'   # Highlights
  CYA=$'\e[36m'   # Headers
  GRY=$'\e[90m'   # Subdued text
else
  BLD=; DIM=; RST=; RED=; GRN=; YEL=; BLU=; MAG=; CYA=; GRY=
fi

SSH_CONFIG="$HOME/.ssh/config"
LOCAL_REMOTE_SCRIPT="remote_launcher_torch.sh"

cleanup() {
  set +e

  # Cancel jobs and kill salloc
  ssh -q torch-login 'scancel -u "$USER" 2>/dev/null' || true
  ssh -q torch-login 'pkill -u "$USER" salloc 2>/dev/null' || true
  sleep 1

  # Clean remote dir
  ssh -q torch-login 'rm -rf /scratch/$USER/.jb 2>/dev/null; mkdir -p /scratch/$USER/.jb' || true

  # Kill local tunnels
  pkill -f "ssh -N -f -L.*torch-compute" 2>/dev/null || true

  set -e
}

trap cleanup INT TERM

clear
printf "${CYA}${BLD}"
printf "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\n"
printf "┃          PyCharm Remote Development Launcher          ┃\n"
printf "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\n"
printf "${RST}\n"

# Cleanup previous session
printf "Cleaning up previous session... "
cleanup
printf "${GRN}✓${RST}\n"

# Disable cleanup trap for normal exit - we want the job to keep running
trap - EXIT

# Upload remote script
printf "Uploading launcher script... "
if [[ ! -f "$LOCAL_REMOTE_SCRIPT" ]]; then
  printf "${RED}✗${RST}\n"
  printf "${RED}Error: Remote script not found at %s${RST}\n" "$LOCAL_REMOTE_SCRIPT"
  exit 1
fi

scp -q "$LOCAL_REMOTE_SCRIPT" torch-login:/tmp/remote_launcher.sh
ssh -q torch-login 'chmod +x /tmp/remote_launcher.sh'
printf "${GRN}✓${RST}\n"

# Run remote script
if ! ssh -t torch-login '/tmp/remote_launcher.sh'; then
  printf "\n${RED}✗${RST} Remote launcher failed\n"
  exit 1
fi

# Fetch session info
printf "\n\n${BLD}Local Startup${RST}\n"
printf "Fetching session info... "
if ! ssh -q torch-login 'cat /scratch/$USER/.jb/session_info' > /tmp/session_info_$$; then
  printf "${RED}✗${RST}\n"
  printf "${RED}Failed to get session info${RST}\n"
  exit 1
fi

# Parse session info
# shellcheck disable=SC1090
source /tmp/session_info_$$
rm -f /tmp/session_info_$$
printf "${GRN}✓${RST}\n"

printf "Updating SSH config... "

FQDN="$NODE"
[[ "$NODE" != *.* ]] && FQDN="${NODE}.hpc.nyu.edu"

if ! grep -q '^Host[[:space:]]\+torch-compute' "$SSH_CONFIG"; then
  cat >> "$SSH_CONFIG" <<CONFIG

Host torch-compute
  User $USER
  ProxyJump torch-login
  PubkeyAuthentication yes
  IdentitiesOnly yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts
  LogLevel QUIET
  HostName $FQDN
CONFIG
else
  # Update HostName
  sed -i.bak -E "/^Host[[:space:]]+torch-compute$/,/^Host[[:space:]]/ s|^([[:space:]]*HostName).*|\1 $FQDN|" "$SSH_CONFIG" 2>/dev/null || \
  perl -0777 -pe 'if(s/^Host\s+torch-compute\b.*?(?=^Host\s|\z)/$&/ms){s/^(\s*HostName).*/$1 '"$FQDN"'/m}' -i.bak -- "$SSH_CONFIG"
fi
printf "${GRN}✓${RST}\n"

# Create tunnel
printf "Creating SSH tunnel... "

ssh -N -f -F "$SSH_CONFIG" -o ExitOnForwardFailure=yes \
  -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" torch-compute
printf "${GRN}✓${RST}\n"

# Generate local join link if JOIN_URL is available
if [[ -n "${JOIN_URL:-}" ]]; then
  JOIN_LOCAL=$(echo "$JOIN_URL" | sed -E "s|^tcp://127\.0\.0\.1:[0-9]+(.*)$|tcp://localhost:${LOCAL_PORT}\1|")

  printf "\n${GRN}CONNECTION READY${RST}\n\n"
  printf "${BLD}Gateway Link:${RST}\n"
  printf "${GRN}%s${RST}\n\n" "$JOIN_LOCAL"
fi
