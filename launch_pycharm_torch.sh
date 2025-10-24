#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
shopt -s inherit_errexit || true  # best-effort on older bash

clear

# ------------ error handling (diagnostics + graceful cleanup) ------------
on_err() {
  local rc=$? line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  printf '\n%s[ ERROR ]%s rc=%s line=%s cmd=%q\n' "$RED$BLD" "$RST" "$rc" "$line" "$cmd" >&2
  # peek at recent remote logs if available
  ssh -q torch-compute 'tail -n 40 /scratch/$USER/.jb/salloc.out 2>/dev/null || true' >&2
  ssh -q torch-compute 'tail -n 60 /scratch/$USER/.jb/backend.log 2>/dev/null || true' >&2
  cleanup
  exit "$rc"
}
trap 'on_err' ERR
trap 'cleanup; exit 1' INT TERM

### BEGIN: SETUP OUTPUT COLORS ###

if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  BLD=$'\e[1m'; RST=$'\e[0m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYA=$'\e[36m'
else
  BLD=; RST=; RED=; GRN=; YEL=; BLU=; MAG=; CYA=
fi

### END: SETUP OUTPUT COLORS ###


### BEGIN: FUNCTIONS ###

cleanup() {
  # Be forgiving during cleanup
  set +e

  # Prefer the caller's LOCAL_PORT, else fall back to default
  local port="${LOCAL_PORT:-7777}"

  # End existing Slurm job(s) best-effort
  ssh -q torch-compute 'scancel -u "$USER"' || true

  # Kill any lingering salloc processes that may hold file handles
  ssh -q torch-compute 'pkill -u "$USER" salloc' || true

  # Brief wait for processes to fully terminate and release file handles
  sleep 1

  # Reset .jb on scratch (best-effort, suppress NFS lock file errors)
  ssh -q torch-compute 'rm -rf /scratch/$USER/.jb 2>/dev/null; mkdir -p /scratch/$USER/.jb' || true

  # kill local SSH tunnels
  pkill -f "ssh -N -f -L ${port}:127.0.0.1:" >/dev/null 2>&1 || true
  pkill -f "ssh .*torch-compute.* -N -f -L"  >/dev/null 2>&1 || true

  # belt-and-suspenders
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -a -c ssh -t 2>/dev/null | xargs -r kill -9 || true
  fi

  set -e
}

# Tiny SSH wrapper: retries + short timeouts
ssh_try() {
  local rc=0 delay=1
  for _ in 1 2 3 4 5; do
    ssh -q \
      -o ConnectTimeout=6 -o ConnectionAttempts=1 \
      -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
      -o ControlMaster=no \
      torch-compute "$@" && return 0
    rc=$?; sleep "$delay"; (( delay<8 && (delay*=2) ))
  done
  return "$rc"
}

# Port probe by argument
probe_listen() {
  local port="$1"
  ( : <"/dev/tcp/127.0.0.1/$port" ) >/dev/null 2>&1 && return 0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq '(^|[^0-9])('"$port"')$' && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

_fetch_status() {
  ssh_try 'squeue -h -u "$USER" --name '"$JOB_NAME"' -o "%i %T %R" 2>/dev/null | head -n1' \
    | grep -v 'slurm_load_jobs error' \
    | awk '{print $1" "$2, substr($0, index($0,$3))}'
}

_print_wait_line() {
  local state="${1-}" reason="${2-}"
  # \r carriage return + ESC[K clear-to-EOL
  if [[ -n "$state" ]]; then
    printf "\r\033[KWaiting for allocation: \e[1;33m%s\e[0m%s" \
      "$state" "${reason:+ — $reason}"
  else
    printf "\r\033[KWaiting for allocation: \e[1;33mstarting\e[0m"
  fi
}

# ---- Input sanitizers ----

_strip_ctrl() { printf '%s' "$1" | tr -d '\001-\037\177'; }

_sanitize_printable() {
  local var="$1"
  local val="${!var}"
  val="$(_strip_ctrl "$val")"
  printf -v "$var" '%s' "$val"
}

_ensure_int() {
  local var="$1"
  local val="${!var}"
  val="$(_strip_ctrl "$val")"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf -v "$var" '%s' "$val"
    return 0
  else
    printf -v "$var" '%s' ""
    return 1
  fi
}

_ensure_port() {
  local var="$1"
  local val="${!var}"
  val="$(_strip_ctrl "$val")"
  if [[ "$val" =~ ^[0-9]+$ ]] && (( val>=1 && val<=65535 )); then
    printf -v "$var" '%s' "$val"
    return 0
  else
    printf -v "$var" '%s' ""
    return 1
  fi
}

### --- /dev/tty-driven prompt helpers ---
if [[ -t 0 && -r /dev/tty && -w /dev/tty ]]; then
  exec 3<> /dev/tty
else
  echo "No interactive TTY available; cannot prompt." >&2
  exit 2
fi

_tty_clear_prev_and_current() { printf '\033[1G\033[2K\033[1A\033[2K\033[1G' >&3; }
_tty_println() { printf '%s\n' "$*" >&3; }
_get_cols() {
  local cols
  cols=$(stty size <&3 2>/dev/null | awk '{print $2}')
  [[ -n "$cols" ]] && printf '%s' "$cols" || printf '80'
}

_prompt() {
  # $1 = prompt, $2 = default, $3 = var name to set
  local _msg="$1" _def="$2" _var="$3" _ans cols max
  cols="$(_get_cols)"; max=$(( cols > 4 ? cols - 2 : 78 ))
  if (( ${#_msg} >= max )); then _msg="${_msg:0:max-2}… "; fi

  # Don't clear previous lines - just print the prompt
  printf '%s' "$_msg" >&3

  # Read with explicit error handling
  if IFS= read -r -u 3 _ans || [[ -n "$_ans" ]]; then
    _ans="$(_strip_ctrl "${_ans-}")"
    if [[ -n "$_ans" ]]; then
      printf -v "$_var" '%s' "$_ans"
    else
      printf -v "$_var" '%s' "$_def"
    fi
    return 0
  else
    printf '\n%sError: Failed to read input. Using default: %s%s\n' "$RED" "$_def" "$RST" >&3
    printf -v "$_var" '%s' "$_def"
    return 1
  fi
}

### END: FUNCTIONS ###


### BEGIN: INPUT PROCESSING - SETUP ###

# Locations #
SSH_CONFIG="$HOME/.ssh/config"
PREFS_FILE="/tmp/torch_last_job_prefs_$$"

# Initialize all variables to empty
TIME_HOURS=""
PARTITION=""
CPUS=""
RAM=""
GPU=""
REMOTE_PORT=""
LOCAL_PORT=""
CONTAINER_PATH=""
PY_BACKEND_VER=""

### END: INPUT PROCESSING - SETUP ###


### BEGIN: CLEAN UP AFTER PREVIOUS SESSION ###

printf "${BLU}${RED}... Cleaning up after previous session ...${RST}\n\n"
cleanup

### END: CLEAN UP AFTER PREVIOUS SESSION ###


### BEGIN: LOAD PREFERENCES AND PROMPT ###

printf "${BLD}${CYA}\n[ Compute Node Resource Request ]\n${RST}\n"

# Load preferences from remote (fail fast with short timeout)
PREFS_LOADED=false
if ssh -q -o ConnectTimeout=3 -o ConnectionAttempts=1 torch-compute 'test -f /scratch/$USER/.config/torch/last_job_prefs && cat /scratch/$USER/.config/torch/last_job_prefs' > "$PREFS_FILE" 2>/dev/null; then
  if [[ -f "$PREFS_FILE" && -r "$PREFS_FILE" && -s "$PREFS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$PREFS_FILE" || true
    printf "Loaded saved preferences from /scratch/\$USER/.config/torch/last_job_prefs\n\n"
    PREFS_LOADED=true
  fi
fi

if [[ "$PREFS_LOADED" == false ]]; then
  # Try to determine if we can connect at all
  if ssh -q -o ConnectTimeout=3 -o ConnectionAttempts=1 torch-compute 'exit 0' 2>/dev/null; then
    printf "No preferences file found. One will be created after this session.\n\n"
  else
    printf "${YEL}Warning: Could not connect to torch-compute to load preferences.${RST}\n\n"
  fi
fi

# Build prompt strings
if [[ -n "$TIME_HOURS" ]]; then
  PROMPT_TIME="Job duration in hours (last: $TIME_HOURS): "
else
  PROMPT_TIME="Job duration in hours: "
fi

if [[ -n "$PARTITION" ]]; then
  PROMPT_PARTITION="Slurm partition (last: $PARTITION): "
else
  PROMPT_PARTITION="Slurm partition: "
fi

if [[ -n "$CPUS" ]]; then
  PROMPT_CPUS="Number of CPUs (last: $CPUS): "
else
  PROMPT_CPUS="Number of CPUs: "
fi

if [[ -n "$RAM" ]]; then
  PROMPT_RAM="RAM (last: $RAM): "
else
  PROMPT_RAM="RAM: "
fi

if [[ -n "$GPU" ]]; then
  PROMPT_GPU="GPU? (last: $GPU): "
else
  PROMPT_GPU="GPU?: "
fi

if [[ -n "$REMOTE_PORT" ]]; then
  PROMPT_REMOTE_PORT="Remote port for backend (last: $REMOTE_PORT): "
else
  PROMPT_REMOTE_PORT="Remote port for backend: "
fi

if [[ -n "$LOCAL_PORT" ]]; then
  PROMPT_LOCAL_PORT="Local forwarded port (last: $LOCAL_PORT): "
else
  PROMPT_LOCAL_PORT="Local forwarded port: "
fi

if [[ -n "$CONTAINER_PATH" ]]; then
  PROMPT_CONTAINER="Container SIF path (last: $CONTAINER_PATH): "
else
  PROMPT_CONTAINER="Container SIF path: "
fi

# Prompt loops with validation
while true; do
  _prompt "$PROMPT_TIME" "$TIME_HOURS" TIME_HOURS
  if [[ -z "$TIME_HOURS" ]]; then
    printf "${RED}Time hours is required. Please enter a value.${RST}\n" >&3
    continue
  fi
  if ! _ensure_int TIME_HOURS; then
    printf "${RED}Invalid number. Please enter a valid integer.${RST}\n" >&3
    continue
  fi
  break
done

while true; do
  _prompt "$PROMPT_PARTITION" "$PARTITION" PARTITION
  if [[ -z "$PARTITION" ]]; then
    printf "${RED}Partition is required. Please enter a value.${RST}\n" >&3
    continue
  fi
  _sanitize_printable PARTITION
  break
done

while true; do
  _prompt "$PROMPT_CPUS" "$CPUS" CPUS
  if [[ -z "$CPUS" ]]; then
    printf "${RED}Number of CPUs is required. Please enter a value.${RST}\n" >&3
    continue
  fi
  if ! _ensure_int CPUS; then
    printf "${RED}Invalid number. Please enter a valid integer.${RST}\n" >&3
    continue
  fi
  break
done

while true; do
  _prompt "$PROMPT_RAM" "$RAM" RAM
  if ! [[ "$RAM" =~ ^[0-9]+$ ]]; then
    printf "${RED}RAM must be an integer number of gigabytes (e.g., 16).${RST}\n" >&2
    continue
  fi
  _sanitize_printable RAM
  break
done

while true; do
  _prompt "$PROMPT_GPU" "$GPU" GPU
  if [[ -z "$GPU" ]]; then
    printf "${RED}GPU selection is required. Please enter 'yes' or 'no'.${RST}\n" >&3
    continue
  fi
  _sanitize_printable GPU
  # Validate yes/no
  if [[ "$GPU" != "yes" && "$GPU" != "no" ]]; then
    printf "${RED}Please enter 'yes' or 'no'.${RST}\n" >&3
    continue
  fi
  break
done

while true; do
  _prompt "$PROMPT_REMOTE_PORT" "$REMOTE_PORT" REMOTE_PORT
  if [[ -z "$REMOTE_PORT" ]]; then
    printf "${RED}Remote port is required. Please enter a value.${RST}\n" >&3
    continue
  fi
  if ! _ensure_port REMOTE_PORT; then
    printf "${RED}Invalid port. Please enter a number between 1 and 65535.${RST}\n" >&3
    continue
  fi
  break
done

while true; do
  _prompt "$PROMPT_LOCAL_PORT" "$LOCAL_PORT" LOCAL_PORT
  if [[ -z "$LOCAL_PORT" ]]; then
    printf "${RED}Local port is required. Please enter a value.${RST}\n" >&3
    continue
  fi
  if ! _ensure_port LOCAL_PORT; then
    printf "${RED}Invalid port. Please enter a number between 1 and 65535.${RST}\n" >&3
    continue
  fi
  break
done

while true; do
  _prompt "$PROMPT_CONTAINER" "$CONTAINER_PATH" CONTAINER_PATH
  if [[ -z "$CONTAINER_PATH" ]]; then
    printf "${RED}Container SIF path is required. Please enter a value.${RST}\n" >&3
    continue
  fi
  _sanitize_printable CONTAINER_PATH
  break
done

### END: LOAD PREFERENCES AND PROMPT ###


### BEGIN: CHECK FOR PYCHARM BACKEND ###

printf "${BLD}${CYA}\n[ Checking for PyCharm Backend ]\n${RST}\n"

printf "Connecting to torch-compute and searching for PyCharm installations...\n"

PYCHARM_BACKENDS=$(ssh_try 'find /scratch/$USER -maxdepth 2 -type d -name "pycharm-*" 2>/dev/null | sed "s|.*/pycharm-||" | sort -V' || echo "")

if [[ -z "$PYCHARM_BACKENDS" ]]; then
  printf "${RED}No PyCharm backends found in /scratch/\$USER${RST}\n"
  printf "Please install PyCharm backend first.\n"
  exit 1
fi

printf "Connection successful.\n"

# Count and display backends
BACKEND_COUNT=$(echo "$PYCHARM_BACKENDS" | wc -l)
printf "Found %d PyCharm backend(s): %s\n" "$BACKEND_COUNT" "$(echo "$PYCHARM_BACKENDS" | tr '\n' ' ')"

# Get the latest version as default
LATEST_BACKEND=$(echo "$PYCHARM_BACKENDS" | tail -n1)

# Use last value if available, otherwise use latest
if [[ -n "$PY_BACKEND_VER" ]]; then
  DEFAULT_BACKEND="$PY_BACKEND_VER"
  PROMPT_BACKEND="PyCharm backend version [latest: $LATEST_BACKEND] (last: $PY_BACKEND_VER): "
else
  DEFAULT_BACKEND="$LATEST_BACKEND"
  PROMPT_BACKEND="PyCharm backend version [$LATEST_BACKEND]: "
fi

while true; do
  _prompt "$PROMPT_BACKEND" "$DEFAULT_BACKEND" PY_BACKEND_VER
  if [[ -z "$PY_BACKEND_VER" ]]; then
    printf "${RED}PyCharm backend version is required.${RST}\n" >&3
    continue
  fi
  _sanitize_printable PY_BACKEND_VER
  break
done

### END: CHECK FOR PYCHARM BACKEND ###


### BEGIN: SLURM REQUEST ###

printf "${BLD}${CYA}\n[ Requesting Compute Node ]${RST}\n\n"

JB="$HOME/.jb"
mkdir -p "$JB"

# Generate a unique job name
JOB_NAME="pycharm-$(date +%s)-$$"

# Save job name locally
printf '%s\n' "$JOB_NAME" > "$JB/job_name"

# Create preferences content
PREFS_CONTENT="TIME_HOURS=$TIME_HOURS
PARTITION=$PARTITION
CPUS=$CPUS
RAM=$RAM
GPU=$GPU
REMOTE_PORT=$REMOTE_PORT
LOCAL_PORT=$LOCAL_PORT
CONTAINER_PATH=$CONTAINER_PATH
PY_BACKEND_VER=$PY_BACKEND_VER"

# Save to remote scratch
printf '%s\n' "$PREFS_CONTENT" | ssh_try 'mkdir -p /scratch/$USER/.config/torch && cat > /scratch/$USER/.config/torch/last_job_prefs'

printf "${BLD}Saved preferences to remote: /scratch/\$USER/.config/torch/last_job_prefs${RST}\n"

# Clean up local temp file
rm -f "$PREFS_FILE"

# Persist remote metadata to remote /scratch/$USER/.jb
ssh_try 'JB="/scratch/$USER/.jb"; mkdir -p "$JB"; printf "%s\n" "'"$JOB_NAME"'" > "$JB/job_name"'

# Remote script: requests allocation + saves job info
printf "Submitting allocation request to Slurm...\n"

# First, ensure the directory exists and is writable
ssh_try 'mkdir -p /scratch/$USER/.jb && touch /scratch/$USER/.jb/test && rm /scratch/$USER/.jb/test' || {
  printf "${RED}Error: Cannot create or write to /scratch/\$USER/.jb${RST}\n"
  exit 1
}

# Record job name
ssh_try 'printf "%s" "'"$JOB_NAME"'" > /scratch/$USER/.jb/job_name'

# Submit the allocation using a simpler approach
ssh_try "cd /scratch/\$USER/.jb && cat > submit_job.sh" <<'SUBMIT_SCRIPT'
#!/bin/bash
set -x  # Debug mode
SCR="/scratch/$USER"
JB="$SCR/.jb"

# Log start
echo "=== Starting job submission at $(date) ===" > "$JB/salloc.out"
echo "JOB_NAME=$JOB_NAME" >> "$JB/salloc.out"
echo "CPUS=$CPUS RAM=$RAM PARTITION=$PARTITION TIME=$TIME_HOURS GPU=$GPU" >> "$JB/salloc.out"

# Build and run salloc
RAM_MB=$(( RAM * 1000 ))
salloc_cmd="salloc --cpus-per-task=$CPUS --mem=$RAM_MB"
if [[ "$PARTITION" != "any" ]]; then
  salloc_cmd="$salloc_cmd --partition=$PARTITION"
fi
salloc_cmd="$salloc_cmd --time=${TIME_HOURS}:00:00 --job-name=$JOB_NAME"
if [[ "$GPU" == "yes" ]]; then
  salloc_cmd="$salloc_cmd --gres=gpu:1"
fi

echo "Running: $salloc_cmd" >> "$JB/salloc.out"

# Run salloc in background
$salloc_cmd bash -c "
  echo \${SLURM_NODELIST:-NONE} > $JB/node
  sleep infinity
" >> "$JB/salloc.out" 2>&1 &

echo "Background PID: $!" >> "$JB/salloc.out"
SUBMIT_SCRIPT

# Make it executable and run it
ssh_try "chmod +x /scratch/\$USER/.jb/submit_job.sh"

# Export variables and run the script
ssh_try "cd /scratch/\$USER/.jb && nohup env \
  JOB_NAME='$JOB_NAME' \
  CPUS='$CPUS' \
  RAM='$RAM' \
  PARTITION='$PARTITION' \
  TIME_HOURS='$TIME_HOURS' \
  GPU='$GPU' \
  bash submit_job.sh > submit.log 2>&1 &"

# Give it a moment to start
sleep 3

# Check if the submission worked
INITIAL_CHECK=$(ssh_try 'squeue -h -u "$USER" --name '"$JOB_NAME"' 2>&1' || echo "FAILED")
if [[ "$INITIAL_CHECK" == "FAILED" || -z "$INITIAL_CHECK" ]]; then
  printf "${YEL}Warning: No job found in queue immediately after submission.${RST}\n"
  printf "Checking logs for errors:\n"
  ssh_try 'cat /scratch/$USER/.jb/salloc.out 2>/dev/null' >&2 || printf "  salloc.out not found\n" >&2
  ssh_try 'cat /scratch/$USER/.jb/submit.log 2>/dev/null' >&2 || printf "  submit.log not found\n" >&2
else
  printf "${GRN}Job submitted successfully!${RST}\n\n"
fi

# Poll for node assignment
NODE=""
STATE="" REASON="" _last_state="" _last_reason=""

for _ in {1..180}; do
  out="$(ssh_try 'cat /scratch/$USER/.jb/node 2>/dev/null' || true)" || true
  NODE="$(printf '%s' "$out" | tr -d '[:space:]')"

  # Prefer direct %i %T %R; if empty (or error suppressed), keep last known
  status="$(_fetch_status || true)"
  if [[ -n "$status" ]]; then
    JOB_ID="${status%% *}"
    rest="${status#* }"
    STATE="${rest%% *}"
    REASON="${rest#* }"
    [[ "$REASON" == "$STATE" ]] && REASON=""
    _last_state="$STATE"
    _last_reason="$REASON"
  else
    STATE="${_last_state:-}"
    REASON="${_last_reason:-}"
  fi

  _print_wait_line "$STATE" "$REASON"

  [[ -n "$NODE" ]] && break
  sleep 1
done
printf "\n"

if [[ -z "$NODE" ]]; then
  printf "${RED}No node assigned (timeout).${RST}\n"
  ssh_try 'tail -n 40 /scratch/$USER/.jb/salloc.out 2>/dev/null' >&2 || true
  exit 1
fi

printf "Node assigned: ${BLD}${YEL}%s${RST}\n" "$NODE"

# Ensure we have JOB_ID recorded and persisted
if [[ -z "${JOB_ID:-}" ]]; then
  JOB_ID="$(ssh_try 'squeue -h -u "$USER" --name '"$JOB_NAME"' -o %i | head -n1')" || true
fi
if [[ -z "${JOB_ID:-}" ]]; then
  printf "${RED}Failed to resolve job id for %s${RST}\n" "$JOB_NAME"
  ssh_try 'tail -n 40 /scratch/$USER/.jb/salloc.out 2>/dev/null' >&2 || true
  exit 1
fi
ssh_try 'echo '"$JOB_ID"' > /scratch/$USER/.jb/job_id' || true
printf "Allocation ID: ${BLD}${YEL}%s${RST}\n" "$JOB_ID"

# --- Overwrite torch-compute HostName in ~/.ssh/config ---
if [[ "$NODE" == *.* ]]; then
  FQDN="$NODE"
else
  FQDN="${NODE}.hpc.nyu.edu"
fi

# Ensure torch-compute stanza exists
if ! grep -q '^Host[[:space:]]\+torch-compute' "$SSH_CONFIG"; then
  {
    echo
    echo "Host torch-compute"
    echo "  User edk202"
    echo "  ProxyJump greene-login"
    echo "  PubkeyAuthentication yes"
    echo "  IdentitiesOnly yes"
    echo "  ServerAliveInterval 30"
    echo "  ServerAliveCountMax 6"
    echo "  StrictHostKeyChecking accept-new"
    echo "  UserKnownHostsFile ~/.ssh/known_hosts"
    echo "  LogLevel QUIET"
    echo "  HostName $FQDN"
  } >> "$SSH_CONFIG"
fi

# Replace any existing HostName line inside that stanza (BSD/GNU portable)
if ! sed -i.bak -E "/^Host[[:space:]]+torch-compute$/,/^Host[[:space:]]/ s|^([[:space:]]*HostName).*|\1 $FQDN|" "$SSH_CONFIG" 2>/dev/null; then
  perl -0777 -pe '
    if(s/^Host\s+torch-compute\b.*?(?=^Host\s|\z)/$&/ms){
      s/^(\s*HostName).*/$1 '"$FQDN"'/m
    }' -i.bak -- "$SSH_CONFIG"
fi

printf "Updated ~/.ssh/config: torch-compute -> %s\n" "$FQDN"

### END: GET COMPUTE NODE ###


### BEGIN: START BACKEND INSIDE CONTAINER ###

ssh -q torch-compute env \
CONTAINER_PATH="$CONTAINER_PATH" \
PY_BACKEND_VER="$PY_BACKEND_VER" \
REMOTE_PORT="$REMOTE_PORT" \
GPU="${GPU:-no}" \
/bin/bash -l <<'REMOTE'
set -Eeuo pipefail
SCR="/scratch/$USER"
JB="$SCR/.jb"
mkdir -p "$JB"

JOB_NAME_REMOTE="$(cat "$JB/job_name" 2>/dev/null || true)"
JOB_ID_REMOTE="$(cat "$JB/job_id" 2>/dev/null || true)"
: "${JOB_NAME_REMOTE:?No job recorded at $JB/job_name; run Step 1 first.}"
: "${JOB_ID_REMOTE:?No job id recorded at $JB/job_id; run Step 1 first.}"

BP="$SCR/pycharm-${PY_BACKEND_VER}/bin/remote-dev-server.sh"
[[ -x "$BP" ]] || { echo "Missing backend: $BP" >&2; exit 2; }

# Singularity args
sing_args=( exec )
[[ "$GPU" == yes ]] && sing_args+=( --nv )

# Env for the container
export APPTAINERENV_JB_REMOTE_DEV_SCRIPT="$BP"
export APPTAINERENV_REMOTE_PORT="$REMOTE_PORT"
export APPTAINERENV_LC_ALL="C.UTF-8" APPTAINERENV_LANG="C.UTF-8"
export APPTAINERENV_IDEA_SYSTEM_PATH="$JB/system-$JOB_NAME_REMOTE"
export APPTAINERENV_IDEA_LOG_PATH="$JB/logs-$JOB_NAME_REMOTE"

# Launch backend inside the job allocation; log to scratch
nohup srun --jobid "$JOB_ID_REMOTE" --ntasks=1 \
  --output="$JB/slurm-%j.%s.out" \
  --error="$JB/slurm-%j.%s.err" \
  singularity "${sing_args[@]}" "$CONTAINER_PATH" /bin/bash -s >"$JB/start_backend.launcher.log" 2>&1 <<'INC' &
set -Eeuo pipefail
JB_SCRATCH="/scratch/$USER/.jb"
LOG="$JB_SCRATCH/backend.log"; : > "$LOG"
JOIN="$JB_SCRATCH/join_url";  : > "$JOIN" || true
PORT="${REMOTE_PORT:?missing REMOTE_PORT}"
BACKEND="${JB_REMOTE_DEV_SCRIPT:?missing JB_REMOTE_DEV_SCRIPT}"

"$BACKEND" run --listen 127.0.0.1 --port "$PORT" >>"$LOG" 2>&1 &
BPID=$!
echo "$BPID" > "$JB_SCRATCH/backend.pid"

for i in $(seq 1 120); do
  if ss -H -ltn 2>/dev/null | awk -v P=":$PORT$" '$4 ~ P {f=1} END{exit !f}'; then
    echo READY > "$JB_SCRATCH/ready"
    grep -m1 -o 'tcp://[^ ]*' "$LOG" >"$JOIN" 2>/dev/null || true
    break
  fi
  if grep -m1 -o 'tcp://[^ ]*' "$LOG" >"$JOIN" 2>/dev/null; then
    echo READY > "$JB_SCRATCH/ready"
    break
  fi
  sleep 1
done

wait "$BPID"
INC
REMOTE

### END: START BACKEND INSIDE CONTAINER ###


### BEGIN: VERIFY BACKEND (resilient polling) ###

printf "${BLD}${CYA}\n[ Starting Backend ]${RST}\n\n" >&2

JOIN_URL=""
for i in {1..120}; do
  JOIN_URL="$(ssh -q -o ConnectTimeout=3 torch-compute 'grep -ao "tcp://[^[:space:]]*" /scratch/$USER/.jb/backend.log 2>/dev/null | tail -n1' 2>/dev/null || true)"
  if [[ -n "$JOIN_URL" ]]; then
    printf "\n"
    break
  fi
  # Print progress every 5 seconds
  if (( i % 5 == 0 )); then
    printf "\rWaiting for backend to start... %ds" "$i" >&2
  fi
  sleep 1
done

if [[ -z "$JOIN_URL" ]]; then
  printf "${RED}No join link yet.${RST}\n"
  printf "Check logs on torch-compute: ${BLD}/scratch/\$USER/.jb/start_backend.launcher.log${RST} or ${BLD}/scratch/\$USER/.jb/backend.log${RST}\n"
  exit 1
fi

# Rewrite to local forwarded port
JOIN_LOCAL="$(printf '%s\n' "$JOIN_URL" \
  | sed -E "s|^tcp://127\.0\.0\.1:[0-9]+(.*)$|tcp://localhost:${LOCAL_PORT}\1|")"

printf 'Backend ready.\nJoin link acquired.\n'

### END: VERIFY BACKEND ###


### BEGIN: OPEN LOCAL TUNNEL & PRINT JOIN LINK (minimal) ###

# Ensure NODE and JOIN_URL (fallback) are set resiliently
NODE="${NODE:-$(ssh_try 'cat /scratch/$USER/.jb/node 2>/dev/null' || true | tr -d "[:space:]")}"
if [[ -z "${JOIN_URL:-}" ]]; then
  JOIN_URL="$(ssh_try 'grep -ao "tcp://[^[:space:]]*" /scratch/$USER/.jb/backend.log 2>/dev/null | tail -n1' || true)"
fi

# Build JOIN_LOCAL from JOIN_URL by replacing only host+port and preserving the tail
JOIN_LOCAL="$JOIN_URL"
if [[ -n "$JOIN_URL" && "$JOIN_URL" =~ ^tcp://127\.0\.0\.1:[0-9]+(.*)$ ]]; then
  JOIN_LOCAL="tcp://localhost:${LOCAL_PORT}${BASH_REMATCH[1]}"
fi

printf '\n%s[ Creating Tunnel ]%s\n' "$BLD$CYA" "$RST" >&2

if probe_listen "$LOCAL_PORT"; then
  printf '\nLocal port already listening!\n'
else
  printf '\nForwarding localhost:%s -> %s:%s\n' "$LOCAL_PORT" "$NODE" "$REMOTE_PORT"
  ssh -N -f -F "$SSH_CONFIG" -o ExitOnForwardFailure=yes \
      -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" torch-compute
fi

printf '\n%s[ Connection Info ]%s\n' "$BLD$CYA" "$RST"

if [[ -n "${JOIN_LOCAL:-}" ]]; then
  printf '\nGateway Link:\n%s%s%s\n' "$CYA" "$JOIN_LOCAL" "$RST"
elif [[ -n "${JOIN_URL:-}" ]]; then
  printf '\nRemote Link (maps to %s locally):\n%s%s%s\n' "$LOCAL_PORT" "$CYA" "$JOIN_URL" "$RST"
else
  printf '\n%sNo join link yet.%s Check %s/scratch/$USER/.jb/backend.log%s on torch-compute.\n' "$RED" "$RST" "$BLD" "$RST"
fi

printf '\n%sJetBrains Gateway -> "Connect via link" -> paste the link above%s' "$BLU" "$RST"
printf '\nTo close the tunnel later: pkill -f '"'"'ssh -N -f -L %s:127.0.0.1:%s'"'"'\n\n' "$LOCAL_PORT" "$REMOTE_PORT"

### END: OPEN LOCAL TUNNEL & PRINT JOIN LINK ###%