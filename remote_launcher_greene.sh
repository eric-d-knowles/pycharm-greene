#!/usr/bin/env bash
# Remote launcher script - runs entirely on torch-greene
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

# Box drawing
BOX_H="━"; BOX_V="┃"; BOX_TL="┏"; BOX_TR="┓"; BOX_BL="┗"; BOX_BR="┛"

# Paths
SCR="/scratch/$USER"
JB="$SCR/.jb"
CONFIG_DIR="$SCR/.config/greene"
PREFS_FILE="$CONFIG_DIR/last_job_prefs"

mkdir -p "$JB" "$CONFIG_DIR"

# Output helpers
_header() {
  printf "\n${BLD}%s${RST}\n" "$1"
}

_success() {
  printf "  ${GRN}✓${RST} %s\n" "$1"
}

_info() {
  printf "  %s\n" "$1"
}

_warning() {
  printf "  ${YEL}!${RST} %s\n" "$1"
}

_error() {
  printf "  ${RED}✗${RST} %s\n" "$1"
}

# Input helpers
_strip_ctrl() { printf '%s' "$1" | tr -d '\001-\037\177'; }

_prompt() {
  local msg="$1" def="$2" var="$3" ans
  printf "%s " "$msg"
  if IFS= read -r ans; then
    ans="$(_strip_ctrl "${ans-}")"
    if [[ -n "$ans" ]]; then
      printf -v "$var" '%s' "$ans"
    else
      printf -v "$var" '%s' "$def"
    fi
  else
    printf -v "$var" '%s' "$def"
  fi
}

# Load preferences
TIME_HOURS="" PARTITION="" CPUS="" RAM="" GPU=""
REMOTE_PORT="" LOCAL_PORT="" CONTAINER_PATH="" PY_BACKEND_VER=""

if [[ -f "$PREFS_FILE" && -r "$PREFS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$PREFS_FILE" 2>/dev/null || true
fi

# Prompt for inputs
printf "${RST}\n"
printf "${BLD}Resource Configuration${RST}\n"

while true; do
  _prompt "Job duration (hours)${TIME_HOURS:+ ${GRY}[$TIME_HOURS]${RST}}: " "$TIME_HOURS" TIME_HOURS
  [[ -n "$TIME_HOURS" && "$TIME_HOURS" =~ ^[0-9]+$ ]] && break
  _error "Must be an integer"
done

while true; do
  _prompt "Partition${PARTITION:+ ${GRY}[$PARTITION]${RST}}: " "${PARTITION:-any}" PARTITION
  [[ -n "$PARTITION" ]] && break
done

while true; do
  _prompt "CPUs${CPUS:+ ${GRY}[$CPUS]${RST}}: " "$CPUS" CPUS
  [[ -n "$CPUS" && "$CPUS" =~ ^[0-9]+$ ]] && break
  _error "Must be an integer"
done

while true; do
  _prompt "Memory (GB)${RAM:+ ${GRY}[$RAM]${RST}}: " "$RAM" RAM
  [[ -n "$RAM" && "$RAM" =~ ^[0-9]+$ ]] && break
  _error "Must be an integer"
done

while true; do
  _prompt "GPU${GPU:+ ${GRY}[$GPU]${RST}} (yes/no): " "${GPU:-no}" GPU
  [[ "$GPU" == "yes" || "$GPU" == "no" ]] && break
  _error "Enter 'yes' or 'no'"
done

while true; do
  _prompt "Remote port${REMOTE_PORT:+ ${GRY}[$REMOTE_PORT]${RST}}: " "$REMOTE_PORT" REMOTE_PORT
  [[ -n "$REMOTE_PORT" && "$REMOTE_PORT" =~ ^[0-9]+$ && "$REMOTE_PORT" -ge 1 && "$REMOTE_PORT" -le 65535 ]] && break
  _error "Must be 1-65535"
done

while true; do
  _prompt "Local port${LOCAL_PORT:+ ${GRY}[$LOCAL_PORT]${RST}}: " "$LOCAL_PORT" LOCAL_PORT
  [[ -n "$LOCAL_PORT" && "$LOCAL_PORT" =~ ^[0-9]+$ && "$LOCAL_PORT" -ge 1 && "$LOCAL_PORT" -le 65535 ]] && break
  _error "Must be 1-65535"
done

while true; do
  _prompt "Container${CONTAINER_PATH:+ ${GRY}[$CONTAINER_PATH]${RST}}: " "$CONTAINER_PATH" CONTAINER_PATH
  [[ -n "$CONTAINER_PATH" ]] && break
done

# Find PyCharm backends
BACKENDS=$(find "$SCR" -maxdepth 2 -type d -name "pycharm-*" 2>/dev/null | sed "s|.*/pycharm-||" | sort -V)

if [[ -z "$BACKENDS" ]]; then
  _error "No PyCharm backends found in $SCR"
  exit 1
fi

LATEST=$(echo "$BACKENDS" | tail -n1)
_prompt "Backend${PY_BACKEND_VER:+ ${GRY}[$PY_BACKEND_VER]${RST}} (Available: ${GRY}$(echo "$BACKENDS" | xargs)${RST}): " "${PY_BACKEND_VER:-$LATEST}" PY_BACKEND_VER

# Save preferences
cat > "$PREFS_FILE" <<PREFS
TIME_HOURS=$TIME_HOURS
PARTITION=$PARTITION
CPUS=$CPUS
RAM=$RAM
GPU=$GPU
REMOTE_PORT=$REMOTE_PORT
LOCAL_PORT=$LOCAL_PORT
CONTAINER_PATH=$CONTAINER_PATH
PY_BACKEND_VER=$PY_BACKEND_VER
PREFS

# Submit job
printf "\n${BLD}Remote Startup${RST}\n"

JOB_NAME="pycharm-$(date +%s)-$$"
echo "$JOB_NAME" > "$JB/job_name"

RAM_MB=$((RAM * 1000))

# Create batch script that writes node info and keeps running
cat > "$JB/job_script.sh" <<JOBSCRIPT
#!/bin/bash
echo "\$SLURM_NODELIST" > $JB/node
sleep infinity
JOBSCRIPT
chmod +x "$JB/job_script.sh"

# Build sbatch command
SBATCH_CMD="sbatch --cpus-per-task=$CPUS --mem=$RAM_MB"
[[ "$PARTITION" != "any" ]] && SBATCH_CMD="$SBATCH_CMD --partition=$PARTITION"
SBATCH_CMD="$SBATCH_CMD --time=${TIME_HOURS}:00:00 --job-name=$JOB_NAME"
[[ "$GPU" == "yes" ]] && SBATCH_CMD="$SBATCH_CMD --gres=gpu:1"
SBATCH_CMD="$SBATCH_CMD --output=$JB/slurm-%j.out --error=$JB/slurm-%j.err"

# Submit job and capture job ID
printf "Submitting job... "
JOB_ID=$($SBATCH_CMD "$JB/job_script.sh" 2>&1 | grep -oP '(?<=Submitted batch job )\d+')
if [[ -z "$JOB_ID" ]]; then
  printf "${RED}✗${RST}\n"
  _error "Failed to submit job"
  exit 1
fi

echo "$JOB_ID" > "$JB/job_id"
printf "${GRN}✓${RST}\n"

# Poll for node
NODE=""
for i in {1..600}; do
  if [[ -f "$JB/node" ]]; then
    NODE=$(cat "$JB/node" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$NODE" && "$NODE" != "NONE" ]] && break
  fi

  # Show status
  if status=$(squeue -h -u "$USER" --name "$JOB_NAME" -o "%T %R" 2>/dev/null | head -n1); then
    printf "\rJob status: ${GRY}%s${RST}\033[K" "$status"
  fi

  sleep 1
done
printf "\rJob status: ${GRN}allocated${RST}\033[K\n"

if [[ -z "$NODE" || "$NODE" == "NONE" ]]; then
  _error "Failed to get node assignment"
  cat "$JB/salloc.log" 2>/dev/null || true
  exit 1
fi

BP="$SCR/pycharm-${PY_BACKEND_VER}/bin/remote-dev-server.sh"
if [[ ! -x "$BP" ]]; then
  _error "Backend not found: $BP"
  exit 1
fi

# Setup singularity args
SING_ARGS="exec --bind /scratch:/scratch"
[[ "$GPU" == "yes" ]] && SING_ARGS="$SING_ARGS --nv"

# Export env for container
export APPTAINERENV_JB_REMOTE_DEV_SCRIPT="$BP"
export APPTAINERENV_REMOTE_PORT="$REMOTE_PORT"
export APPTAINERENV_LC_ALL="C.UTF-8"
export APPTAINERENV_LANG="C.UTF-8"
export APPTAINERENV_IDEA_SYSTEM_PATH="$JB/system-$JOB_NAME"
export APPTAINERENV_IDEA_LOG_PATH="$JB/logs-$JOB_NAME"

# Create wrapper script for backend
cat > "$JB/run_backend.sh" <<'WRAPPER'
#!/bin/bash
LOG="$1"
BACKEND="$2"
PORT="$3"

touch "$LOG"
"$BACKEND" run --listen 127.0.0.1 --port "$PORT" >> "$LOG" 2>&1
WRAPPER
chmod +x "$JB/run_backend.sh"

# Launch backend using srun to run on the compute node
setsid nohup srun --jobid "$JOB_ID" --ntasks=1 --mem=0 \
  singularity $SING_ARGS "$CONTAINER_PATH" \
  "$JB/run_backend.sh" "$JB/backend.log" "$BP" "$REMOTE_PORT" \
  > "$JB/backend_launcher.log" 2>&1 &

# Wait for backend ready
READY=false
for i in {1..120}; do
  if JOIN_URL=$(grep -ao "tcp://[^[:space:]]*" "$JB/backend.log" 2>/dev/null | tail -n1); then
    if [[ -n "$JOIN_URL" ]]; then
      READY=true
      break
    fi
  fi

  if (( i % 5 == 0 )); then
    printf "\rStarting backend... ${GRY}%ds${RST}" "$i"
  fi
  sleep 1
done

if [[ "$READY" == "true" ]]; then
  printf "\rStarting backend... ${GRN}✓   ${RST}\033[K\n"
else
  printf "\rStarting backend... ${RED}✗ Timeout${RST}\n"
fi

# Write results for local script
# Quote JOIN_URL to handle special characters like #
cat > "$JB/session_info" <<INFO
NODE='$NODE'
JOB_ID='$JOB_ID'
REMOTE_PORT='$REMOTE_PORT'
LOCAL_PORT='$LOCAL_PORT'
JOIN_URL='$JOIN_URL'
INFO

printf "Session ready: Node ${GRN}%s${RST}, Job ${GRN}%s${RST}" "$NODE" "$JOB_ID"
