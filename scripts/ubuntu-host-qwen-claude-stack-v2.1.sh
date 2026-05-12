#!/usr/bin/env bash
# shellcheck shell=bash
#
# Hardened Ubuntu host installer for a local Claude Code-compatible coding stack.
# Flow: scan -> tune -> Ollama -> Qwen Coder -> LiteLLM -> macOS VM preconfig.
# Version: 2.1

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${APP_NAME:-mac-claude-code}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
USER_MODEL_SOURCE="${MODEL_SOURCE:-}"
USER_NUM_CTX="${NUM_CTX:-}"
MODEL_SOURCE="${USER_MODEL_SOURCE:-dagbs/qwen2.5-coder-7b-instruct-abliterated:q4_k_m}"
NUM_CTX="${USER_NUM_CTX:-8192}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_KEY:-local-dev-key}"
TEMPERATURE="${TEMPERATURE:-0.15}"
TOP_P="${TOP_P:-0.90}"
REPEAT_PENALTY="${REPEAT_PENALTY:-1.05}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-600}"
SKIP_APT="${SKIP_APT:-0}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
SKIP_MODEL_PULL="${SKIP_MODEL_PULL:-0}"
FORCE_RECREATE_MODEL="${FORCE_RECREATE_MODEL:-0}"
FORCE_REINSTALL_LITELLM="${FORCE_REINSTALL_LITELLM:-0}"
USE_SYSTEMD_USER="${USE_SYSTEMD_USER:-1}"
OPEN_TO_LAN="${OPEN_TO_LAN:-1}"
AUTO_TUNE_MODEL="${AUTO_TUNE_MODEL:-1}"
AUTO_ENABLE_LINGER="${AUTO_ENABLE_LINGER:-1}"
AUTO_CONFIGURE_UFW="${AUTO_CONFIGURE_UFW:-1}"
STRICT_PORT_CHECK="${STRICT_PORT_CHECK:-0}"
CONFIRM_UNINSTALL="${CONFIRM_UNINSTALL:-0}"
REMOVE_UFW_RULES_ON_UNINSTALL="${REMOVE_UFW_RULES_ON_UNINSTALL:-0}"

BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/${APP_NAME}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME}"
LOG_DIR="$STATE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"
MODEL_DIR="$BASE_DIR/models/$MODEL_ALIAS"
VENV_DIR="$BASE_DIR/venv"
LITELLM_CONFIG="$CONFIG_DIR/litellm.yaml"
STACK_ENV="$CONFIG_DIR/stack.env"
SCAN_ENV="$CONFIG_DIR/host-scan.env"
SCAN_TXT="$CONFIG_DIR/host-scan.txt"
HOST_EXPORT="$BASE_DIR/host-connection.env"
MAC_PRECONFIG="$BASE_DIR/macos-host-preconfig.env"
MAC_BOOTSTRAP="$BASE_DIR/install-on-macos-vm.sh"
STATUS_JSON="$STATE_DIR/status.json"
SERVICE_NAME="${APP_NAME}-litellm.service"
PID_DIR="$STATE_DIR/pids"
OLLAMA_PIDFILE="$PID_DIR/ollama.pid"
LITELLM_PIDFILE="$PID_DIR/litellm.pid"
LOG_FILE="$LOG_DIR/host-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$BASE_DIR" "$STATE_DIR" "$CACHE_DIR" "$LOG_DIR" "$CONFIG_DIR" "$MODEL_DIR" "$PID_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi

CURRENT_STEP="bootstrap"
START_TS="$(date +%s)"
HOST_PRIMARY_IP=""
HOST_DEFAULT_IFACE=""
HOST_DEFAULT_GATEWAY=""
GPU_NAME="none"
GPU_VRAM_MB="0"
GPU_DRIVER="unknown"
CUDA_VERSION="unknown"
RAM_GB="0"
SWAP_GB="0"
CPU_MODEL="unknown"
CPU_CORES="0"
DISK_FREE_GB="0"
SYSTEMD_USER_OK="0"
STARTED_PIDS=()

log() {
  local level="$1"; shift || true
  local color="$RESET"
  case "$level" in
    OK) color="$GREEN" ;;
    INFO) color="$CYAN" ;;
    WARN) color="$YELLOW" ;;
    ERR) color="$RED" ;;
    STEP) color="$MAGENTA" ;;
    DEBUG) color="$DIM" ;;
  esac
  printf "%s[%s]%s %s\n" "$color" "$level" "$RESET" "$*"
}

step() { CURRENT_STEP="$1"; echo; log STEP "$1"; }
run() { log INFO "$*"; "$@"; }
kv() { printf "%-22s %s\n" "$1:" "$2"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
shell_quote() { printf '%q' "$1"; }
write_env_var() { printf '%s=%s\n' "$1" "$(shell_quote "$2")"; }

cleanup_started_children() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log WARN "Stopping background process started by this run: $pid"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

on_error() {
  local exit_code=$?
  cleanup_started_children
  echo
  echo "${RED}${BOLD}✘ FAILURE${RESET} step=${CURRENT_STEP} line=${BASH_LINENO[0]} exit=$exit_code"
  echo "${DIM}Log: $LOG_FILE${RESET}"
  echo
  echo "Quick probes:"
  echo "  ./scripts/ubuntu-host-qwen-claude-stack-v2.1.sh scan"
  echo "  ./scripts/ubuntu-host-qwen-claude-stack-v2.1.sh status"
  echo "  ./scripts/ubuntu-host-qwen-claude-stack-v2.1.sh logs"
  echo "  systemctl status ollama --no-pager || true"
  echo "  curl -v http://127.0.0.1:$OLLAMA_PORT/api/tags"
  echo "  curl -v -H 'Authorization: Bearer $LITELLM_KEY' http://127.0.0.1:$LITELLM_PORT/v1/models"
  exit "$exit_code"
}

on_interrupt() {
  echo
  log WARN "Interrupted. Cleaning up background processes started by this run."
  cleanup_started_children
  exit 130
}
trap on_error ERR
trap on_interrupt INT TERM

safe_source_env() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

systemd_available() {
  command_exists systemctl && [[ "$(ps -p 1 -o comm= 2>/dev/null || true)" == "systemd" ]]
}

with_timeout() {
  local seconds="$1"; shift
  if command_exists timeout; then timeout "$seconds" "$@"; else "$@"; fi
}

systemd_user_available() {
  with_timeout 2s systemctl --user status >/dev/null 2>&1
}

require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    log WARN "sudo required; requesting elevation"
    sudo true
  fi
}

pid_alive() { [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null; }

stop_pidfile() {
  local pidfile="$1" label="$2" pid=""
  [[ -f "$pidfile" ]] || return 0
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if pid_alive "$pid"; then
    log WARN "Stopping tracked $label process: $pid"
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

banner() {
  clear || true
  cat <<'ART'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║    ███╗   ███╗ █████╗  ██████╗      ██████╗██╗      █████╗ ██╗   ██╗██████╗ ║
║    ████╗ ████║██╔══██╗██╔════╝     ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗║
║    ██╔████╔██║███████║██║          ██║     ██║     ███████║██║   ██║██║  ██║║
║    ██║╚██╔╝██║██╔══██║██║          ██║     ██║     ██╔══██║██║   ██║██║  ██║║
║    ██║ ╚═╝ ██║██║  ██║╚██████╗     ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝║
║    ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝      ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ║
║                                                                              ║
║     Ubuntu Host Autoconfig: scan → tune → Ollama → LiteLLM → macOS VM env     ║
║                              hardened v2.1                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
ART
}

usage() {
  cat <<USAGE
Usage:
  $0 [command]

Commands:
  install       Full scan + install/configure. Default.
  scan          Deep host scan only.
  status        Print stack status and health checks.
  env           Print host connection env for the macOS VM.
  mac-env       Same as env, plus copy instructions.
  preconfigure  Regenerate macOS VM preconfiguration files only.
  logs          Tail recent LiteLLM/Ollama logs.
  restart       Restart Ollama and LiteLLM.
  stop          Stop fallback LiteLLM/Ollama processes and user service.
  uninstall     Remove LiteLLM service/venv/config. Keeps Ollama models.
  help          Show this help.

Useful overrides:
  MODEL_SOURCE=dagbs/qwen2.5-coder-7b-instruct-abliterated:q5_k_m
  NUM_CTX=8192
  LITELLM_KEY=local-dev-key
  OPEN_TO_LAN=1
  AUTO_TUNE_MODEL=1
  SKIP_MODEL_PULL=1
  FORCE_RECREATE_MODEL=1
  FORCE_REINSTALL_LITELLM=1
  CONFIRM_UNINSTALL=1
  REMOVE_UFW_RULES_ON_UNINSTALL=1
USAGE
}

ascii_topology() {
  cat <<TOPOLOGY

${BLUE}${BOLD}Runtime topology${RESET}

  ┌────────────────────────────────────────────────────────────────────┐
  │ Ubuntu Host                                                        │
  │ scan: CPU/RAM/GPU/network/systemd/firewall/ports                   │
  └──────────────┬─────────────────────────────────────────────────────┘
                 │ tune: model/context/service binding
                 ▼
        ┌───────────────────────┐
        │ Ollama                │  http://${HOST_PRIMARY_IP:-HOST_IP}:$OLLAMA_PORT
        │ $MODEL_ALIAS
        │ $MODEL_SOURCE
        └───────────┬───────────┘
                    │ localhost
                    ▼
        ┌───────────────────────┐
        │ LiteLLM Proxy         │  http://${HOST_PRIMARY_IP:-HOST_IP}:$LITELLM_PORT
        │ OpenAI-compatible API │  key=$LITELLM_KEY
        └───────────┬───────────┘
                    │ generated host-connection.env
                    ▼
  ┌────────────────────────────────────────────────────────────────────┐
  │ macOS VM                                                           │
  │ Claude Code CLI via ANTHROPIC_API_KEY/BASE_URL/MODEL               │
  └────────────────────────────────────────────────────────────────────┘

TOPOLOGY
}

host_ips() {
  ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | grep -v '^127\.' | awk '!seen[$0]++' || true
}

default_iface() { ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true; }
default_gateway() { ip route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true; }
primary_ip() {
  local iface ipaddr
  iface="$(default_iface)"
  if [[ -n "$iface" ]]; then
    ipaddr="$(ip -4 addr show dev "$iface" scope global 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1 || true)"
    [[ -n "$ipaddr" ]] && echo "$ipaddr" && return 0
  fi
  host_ips | head -n 1 || true
}

collect_scan() {
  step "Deep system scan"
  HOST_DEFAULT_IFACE="$(default_iface)"
  HOST_DEFAULT_GATEWAY="$(default_gateway)"
  HOST_PRIMARY_IP="$(primary_ip)"
  CPU_MODEL="$(awk -F: '/model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
  CPU_CORES="$(nproc 2>/dev/null || echo 0)"
  RAM_GB="$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  SWAP_GB="$(awk '/SwapTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  DISK_FREE_GB="$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}' || echo 0)"

  if command_exists nvidia-smi; then
    GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || echo none)"
    GPU_VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n 1 || echo 0)"
    GPU_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo unknown)"
    CUDA_VERSION="$(nvidia-smi 2>/dev/null | awk -F'CUDA Version: ' '/CUDA Version/ {split($2,a," "); print a[1]; exit}' || echo unknown)"
  fi
  if systemd_user_available; then SYSTEMD_USER_OK="1"; else SYSTEMD_USER_OK="0"; fi

  {
    write_env_var HOST_PRIMARY_IP "$HOST_PRIMARY_IP"
    write_env_var HOST_DEFAULT_IFACE "$HOST_DEFAULT_IFACE"
    write_env_var HOST_DEFAULT_GATEWAY "$HOST_DEFAULT_GATEWAY"
    write_env_var CPU_MODEL "$CPU_MODEL"
    write_env_var CPU_CORES "$CPU_CORES"
    write_env_var RAM_GB "$RAM_GB"
    write_env_var SWAP_GB "$SWAP_GB"
    write_env_var DISK_FREE_GB "$DISK_FREE_GB"
    write_env_var GPU_NAME "$GPU_NAME"
    write_env_var GPU_VRAM_MB "$GPU_VRAM_MB"
    write_env_var GPU_DRIVER "$GPU_DRIVER"
    write_env_var CUDA_VERSION "$CUDA_VERSION"
    write_env_var SYSTEMD_USER_OK "$SYSTEMD_USER_OK"
  } > "$SCAN_ENV"
  chmod 600 "$SCAN_ENV"

  {
    echo "mac-claude-code host scan"
    echo "generated_at=$(date -Iseconds)"
    echo
    kv "host" "$(hostname 2>/dev/null || true)"
    kv "os" "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
    kv "kernel" "$(uname -r)"
    kv "arch" "$(uname -m)"
    kv "cpu" "$CPU_MODEL"
    kv "cores" "$CPU_CORES"
    kv "ram_gb" "$RAM_GB"
    kv "swap_gb" "$SWAP_GB"
    kv "disk_free_gb" "$DISK_FREE_GB"
    kv "gpu" "$GPU_NAME"
    kv "gpu_vram_mb" "$GPU_VRAM_MB"
    kv "nvidia_driver" "$GPU_DRIVER"
    kv "cuda" "$CUDA_VERSION"
    kv "default_iface" "$HOST_DEFAULT_IFACE"
    kv "gateway" "$HOST_DEFAULT_GATEWAY"
    kv "primary_ip" "$HOST_PRIMARY_IP"
    echo "all_ips:"
    host_ips | sed 's/^/  - /'
  } > "$SCAN_TXT"

  echo "${BOLD}System scan${RESET}"
  cat "$SCAN_TXT"
  log OK "Scan written: $SCAN_ENV"
  log OK "Scan report:  $SCAN_TXT"
}

auto_tune_from_scan() {
  step "Auto tuning"
  if [[ "$AUTO_TUNE_MODEL" != "1" ]]; then
    log WARN "AUTO_TUNE_MODEL=0; preserving MODEL_SOURCE=$MODEL_SOURCE NUM_CTX=$NUM_CTX"
    return
  fi
  if [[ -z "$USER_MODEL_SOURCE" ]]; then
    if [[ "$GPU_VRAM_MB" =~ ^[0-9]+$ ]] && (( GPU_VRAM_MB >= 11000 )); then
      MODEL_SOURCE="dagbs/qwen2.5-coder-7b-instruct-abliterated:q5_k_m"
    elif [[ "$GPU_VRAM_MB" =~ ^[0-9]+$ ]] && (( GPU_VRAM_MB >= 7000 )); then
      MODEL_SOURCE="dagbs/qwen2.5-coder-7b-instruct-abliterated:q4_k_m"
    elif [[ "$GPU_VRAM_MB" =~ ^[0-9]+$ ]] && (( GPU_VRAM_MB >= 5000 )); then
      MODEL_SOURCE="dagbs/qwen2.5-coder-7b-instruct-abliterated:iq4_xs"
    else
      MODEL_SOURCE="dagbs/qwen2.5-coder-7b-instruct-abliterated:q3_k_m"
    fi
  fi
  if [[ -z "$USER_NUM_CTX" ]]; then
    if [[ "$GPU_VRAM_MB" =~ ^[0-9]+$ ]] && (( GPU_VRAM_MB >= 11000 )); then NUM_CTX="12288"; elif [[ "$GPU_VRAM_MB" =~ ^[0-9]+$ ]] && (( GPU_VRAM_MB >= 7000 )); then NUM_CTX="8192"; else NUM_CTX="4096"; fi
  fi
  {
    write_env_var MODEL_SOURCE "$MODEL_SOURCE"
    write_env_var MODEL_ALIAS "$MODEL_ALIAS"
    write_env_var NUM_CTX "$NUM_CTX"
    write_env_var OLLAMA_PORT "$OLLAMA_PORT"
    write_env_var LITELLM_PORT "$LITELLM_PORT"
    write_env_var LITELLM_KEY "$LITELLM_KEY"
  } > "$STACK_ENV"
  chmod 600 "$STACK_ENV"
  log OK "Selected model: $MODEL_SOURCE"
  log OK "Selected context: $NUM_CTX"
}

os_guard() {
  step "OS guard"
  [[ -f /etc/os-release ]] || { log ERR "This script is intended for Ubuntu/Linux hosts. /etc/os-release missing."; exit 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  log INFO "Detected: ${PRETTY_NAME:-Linux}"
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then log WARN "Not Ubuntu/Debian-like. Continuing, but package install may fail."; fi
}

apt_install_base() {
  step "Base packages"
  [[ "$SKIP_APT" == "1" ]] && { log WARN "Skipping apt package installation"; return; }
  require_sudo
  run sudo apt-get update
  run sudo apt-get install -y curl ca-certificates jq python3 python3-venv python3-pip lsof net-tools iproute2 ufw procps gawk coreutils
}

preflight_ports() {
  step "Port preflight"
  local conflict="0" tmpfile port
  for port in "$OLLAMA_PORT" "$LITELLM_PORT"; do
    tmpfile="$(mktemp "/tmp/${APP_NAME}-port-${port}.XXXXXX")"
    if command_exists lsof && lsof -iTCP:"$port" -sTCP:LISTEN -n -P >"$tmpfile" 2>/dev/null; then
      if grep -qE 'ollama|litellm|python' "$tmpfile"; then log OK "Port $port already used by expected stack process"; else log WARN "Port $port is already in use by another process:"; cat "$tmpfile"; conflict="1"; fi
    else
      log OK "Port $port is free"
    fi
    rm -f "$tmpfile"
  done
  [[ "$STRICT_PORT_CHECK" == "1" && "$conflict" == "1" ]] && { log ERR "Port conflict detected and STRICT_PORT_CHECK=1"; exit 1; }
}

install_ollama() {
  step "Ollama installation"
  if command_exists ollama; then log OK "Ollama found: $(ollama --version || true)"; else log INFO "Installing Ollama from official installer"; curl -fsSL https://ollama.com/install.sh | sh; fi
}

configure_ollama_service() {
  step "Ollama service configuration"
  local host_bind="127.0.0.1:$OLLAMA_PORT"
  [[ "$OPEN_TO_LAN" == "1" ]] && host_bind="0.0.0.0:$OLLAMA_PORT"
  if systemd_available && systemctl list-unit-files | grep -q '^ollama.service'; then
    require_sudo
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<SERVICEEOF
[Service]
Environment="OLLAMA_HOST=$host_bind"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
SERVICEEOF
    run sudo systemctl daemon-reload
    run sudo systemctl enable ollama
    run sudo systemctl restart ollama
    sleep 2
    log OK "Ollama service bound to $host_bind"
  else
    log WARN "No systemd Ollama service found. Launching tracked background server."
    stop_pidfile "$OLLAMA_PIDFILE" "Ollama"
    nohup env OLLAMA_HOST="$host_bind" OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_KEEP_ALIVE=30m ollama serve >"$LOG_DIR/ollama-serve.log" 2>&1 &
    echo $! > "$OLLAMA_PIDFILE"
    STARTED_PIDS+=("$!")
    sleep 3
  fi
}

wait_for_http() {
  local url="$1" header_arg="${2:-}" attempts="${3:-30}" delay="${4:-1}" max_delay="${5:-5}" i
  for ((i=1; i<=attempts; i++)); do
    if [[ -n "$header_arg" ]]; then curl -fsS --connect-timeout 2 -H "$header_arg" "$url" >/dev/null 2>&1 && return 0; else curl -fsS --connect-timeout 2 "$url" >/dev/null 2>&1 && return 0; fi
    printf "%s" "${DIM}.${RESET}"
    sleep "$delay"
    delay=$((delay * 2))
    (( delay > max_delay )) && delay="$max_delay"
  done
  echo
  return 1
}

pull_model() {
  step "Model pull"
  [[ "$SKIP_MODEL_PULL" == "1" ]] && { log WARN "Skipping model pull"; return; }
  wait_for_http "http://127.0.0.1:$OLLAMA_PORT/api/tags" "" 30 1 5
  run ollama pull "$MODEL_SOURCE"
  log OK "Pulled: $MODEL_SOURCE"
}

model_exists() { ollama list 2>/dev/null | awk '{print $1}' | grep -Fxq "$MODEL_ALIAS"; }

create_wrapper_model() {
  step "Wrapper model"
  cat > "$MODEL_DIR/Modelfile" <<MODELEOF
FROM $MODEL_SOURCE

PARAMETER num_ctx $NUM_CTX
PARAMETER temperature $TEMPERATURE
PARAMETER top_p $TOP_P
PARAMETER repeat_penalty $REPEAT_PENALTY
PARAMETER num_gpu 999

SYSTEM """
You are a local autonomous coding assistant specialized in Swift, iOS, CoreML, Expo, React Native, Python, Linux, macOS VM development, debugging, terminal automation, and full-project refactoring.

Operational rules:
- Produce complete working code when code is requested.
- Avoid placeholders.
- Avoid vague advice.
- Prefer precise file-level fixes.
- Preserve existing architecture unless a refactor is clearly justified.
- Be direct.
"""
MODELEOF
  if model_exists && [[ "$FORCE_RECREATE_MODEL" != "1" ]]; then log OK "Wrapper model already exists: $MODEL_ALIAS"; else run ollama create "$MODEL_ALIAS" -f "$MODEL_DIR/Modelfile"; log OK "Wrapper model created: $MODEL_ALIAS"; fi
}

install_litellm() {
  step "LiteLLM installation"
  if [[ "$FORCE_REINSTALL_LITELLM" == "1" && -d "$VENV_DIR" ]]; then log WARN "Removing existing venv because FORCE_REINSTALL_LITELLM=1"; [[ "$VENV_DIR" == "$BASE_DIR"/* ]] && rm -rf "$VENV_DIR"; fi
  if [[ ! -x "$VENV_DIR/bin/litellm" ]]; then
    run python3 -m venv "$VENV_DIR"
    run "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools
    run "$VENV_DIR/bin/python" -m pip install "litellm[proxy]"
  else
    log OK "LiteLLM already installed in $VENV_DIR"
  fi
  cat > "$LITELLM_CONFIG" <<LITEEOF
model_list:
  - model_name: $MODEL_ALIAS
    litellm_params:
      model: ollama_chat/$MODEL_ALIAS
      api_base: http://127.0.0.1:$OLLAMA_PORT
router_settings:
  routing_strategy: simple-shuffle
  num_retries: 2
  timeout: $REQUEST_TIMEOUT
general_settings:
  master_key: "$LITELLM_KEY"
litellm_settings:
  request_timeout: $REQUEST_TIMEOUT
  num_retries: 2
  drop_params: true
  set_verbose: false
LITEEOF
  chmod 600 "$LITELLM_CONFIG"
  log OK "LiteLLM config: $LITELLM_CONFIG"
}

enable_linger_if_needed() {
  [[ "$AUTO_ENABLE_LINGER" == "1" ]] || return 0
  if command_exists loginctl && systemd_available; then
    step "User service persistence"
    if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then log OK "User linger already enabled for $USER"; else require_sudo; run sudo loginctl enable-linger "$USER"; log OK "Enabled user linger for $USER"; fi
  fi
}

start_litellm_service() {
  step "LiteLLM service"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/$SERVICE_NAME" <<USERSERVICEEOF
[Unit]
Description=mac-claude-code LiteLLM Proxy
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$BASE_DIR
ExecStart=$VENV_DIR/bin/litellm --config $LITELLM_CONFIG --host 0.0.0.0 --port $LITELLM_PORT
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
USERSERVICEEOF
  if [[ "$USE_SYSTEMD_USER" == "1" ]] && systemd_user_available; then
    run systemctl --user daemon-reload
    run systemctl --user enable --now "$SERVICE_NAME"
    sleep 3
    log OK "LiteLLM user service started: $SERVICE_NAME"
  else
    log WARN "systemd --user unavailable or disabled. Starting tracked LiteLLM with nohup."
    stop_pidfile "$LITELLM_PIDFILE" "LiteLLM"
    nohup "$VENV_DIR/bin/litellm" --config "$LITELLM_CONFIG" --host 0.0.0.0 --port "$LITELLM_PORT" >"$LOG_DIR/litellm.log" 2>&1 &
    echo $! > "$LITELLM_PIDFILE"
    STARTED_PIDS+=("$!")
    sleep 3
  fi
}

configure_firewall() {
  step "Firewall"
  [[ "$SKIP_FIREWALL" == "1" || "$AUTO_CONFIGURE_UFW" != "1" ]] && { log WARN "Skipping firewall changes"; return; }
  if command_exists ufw && sudo ufw status | grep -q "Status: active"; then
    require_sudo
    run sudo ufw allow "$OLLAMA_PORT/tcp"
    run sudo ufw allow "$LITELLM_PORT/tcp"
    log OK "UFW allows ports $OLLAMA_PORT and $LITELLM_PORT"
  else
    log INFO "UFW inactive or unavailable; no firewall rules changed"
  fi
}

write_exports() {
  [[ -z "$HOST_PRIMARY_IP" ]] && HOST_PRIMARY_IP="$(primary_ip)"
  {
    echo "# Generated by $APP_NAME on $(date -Iseconds)"
    write_env_var HOST_IP "$HOST_PRIMARY_IP"
    write_env_var HOST_DEFAULT_IFACE "$HOST_DEFAULT_IFACE"
    write_env_var HOST_DEFAULT_GATEWAY "$HOST_DEFAULT_GATEWAY"
    write_env_var MODEL_ALIAS "$MODEL_ALIAS"
    write_env_var MODEL_SOURCE "$MODEL_SOURCE"
    write_env_var NUM_CTX "$NUM_CTX"
    write_env_var OLLAMA_PORT "$OLLAMA_PORT"
    write_env_var LITELLM_PORT "$LITELLM_PORT"
    write_env_var OLLAMA_HOST_URL "http://$HOST_PRIMARY_IP:$OLLAMA_PORT"
    write_env_var LITELLM_BASE_URL "http://$HOST_PRIMARY_IP:$LITELLM_PORT"
    write_env_var LITELLM_KEY "$LITELLM_KEY"
    write_env_var ANTHROPIC_API_KEY "$LITELLM_KEY"
    write_env_var ANTHROPIC_BASE_URL "http://$HOST_PRIMARY_IP:$LITELLM_PORT"
    write_env_var ANTHROPIC_MODEL "$MODEL_ALIAS"
  } > "$HOST_EXPORT"
  chmod 600 "$HOST_EXPORT"
  cp "$HOST_EXPORT" "$MAC_PRECONFIG"
  chmod 600 "$MAC_PRECONFIG"
}

write_macos_bootstrap() {
  cat > "$MAC_BOOTSTRAP" <<'MACBOOTEOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ! -f ./macos-host-preconfig.env && -f ./host-connection.env ]]; then cp ./host-connection.env ./macos-host-preconfig.env; fi
if [[ -f ./macos-host-preconfig.env ]]; then set -a; source ./macos-host-preconfig.env; set +a; fi
chmod +x scripts/macos-vm-claude-client-v2.sh
HOST_CONFIG_PATH="${HOST_CONFIG_PATH:-$(pwd)/macos-host-preconfig.env}" ./scripts/macos-vm-claude-client-v2.sh install
MACBOOTEOF
  chmod +x "$MAC_BOOTSTRAP"
}

preconfigure_macos_files() { step "macOS VM preconfiguration"; write_exports; write_macos_bootstrap; log OK "Host connection env: $HOST_EXPORT"; log OK "macOS preconfig env:  $MAC_PRECONFIG"; log OK "macOS bootstrap:      $MAC_BOOTSTRAP"; }

health_json() {
  local status="$1" elapsed="$(( $(date +%s) - START_TS ))"
  [[ -z "$HOST_PRIMARY_IP" ]] && HOST_PRIMARY_IP="$(primary_ip)"
  cat > "$STATUS_JSON" <<STATUSEOF
{
  "status": "$status",
  "app": "$APP_NAME",
  "model_alias": "$MODEL_ALIAS",
  "model_source": "$MODEL_SOURCE",
  "num_ctx": $NUM_CTX,
  "gpu_name": "$GPU_NAME",
  "gpu_vram_mb": "$GPU_VRAM_MB",
  "ram_gb": "$RAM_GB",
  "host_ip": "$HOST_PRIMARY_IP",
  "ollama_port": $OLLAMA_PORT,
  "litellm_port": $LITELLM_PORT,
  "litellm_base_url": "http://$HOST_PRIMARY_IP:$LITELLM_PORT",
  "ollama_base_url": "http://$HOST_PRIMARY_IP:$OLLAMA_PORT",
  "scan_env": "$SCAN_ENV",
  "host_export": "$HOST_EXPORT",
  "log_file": "$LOG_FILE",
  "elapsed_seconds": $elapsed,
  "updated_at": "$(date -Iseconds)"
}
STATUSEOF
}

probe() {
  step "Health checks"
  local ollama_tags_url="http://127.0.0.1:$OLLAMA_PORT/api/tags"
  local ollama_generate_url="http://127.0.0.1:$OLLAMA_PORT/api/generate"
  local litellm_url="http://127.0.0.1:$LITELLM_PORT/v1/models"
  local response=""
  wait_for_http "$ollama_tags_url" "" 30 1 5
  log OK "Ollama responds: $ollama_tags_url"
  wait_for_http "$litellm_url" "Authorization: Bearer $LITELLM_KEY" 30 1 5
  log OK "LiteLLM responds: $litellm_url"
  log INFO "Generation smoke test"
  if command_exists jq; then
    response="$(curl -fsS "$ollama_generate_url" -H "Content-Type: application/json" -d "{\"model\":\"$MODEL_ALIAS\",\"prompt\":\"Return exactly LOCAL_QWEN_READY and nothing else.\",\"stream\":false}" | jq -r '.response' || true)"
  else
    response="$(curl -fsS "$ollama_generate_url" -H "Content-Type: application/json" -d "{\"model\":\"$MODEL_ALIAS\",\"prompt\":\"Return exactly LOCAL_QWEN_READY and nothing else.\",\"stream\":false}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("response", ""))' 2>/dev/null || true)"
  fi
  echo "${DIM}${response}${RESET}"
  health_json "ready"
}

print_scan() { banner; collect_scan; auto_tune_from_scan; }

print_status() {
  banner
  safe_source_env "$SCAN_ENV"
  HOST_PRIMARY_IP="$(primary_ip)"
  ascii_topology
  echo "${BOLD}Paths${RESET}"
  kv "Base" "$BASE_DIR"; kv "Config" "$CONFIG_DIR"; kv "Logs" "$LOG_DIR"; kv "Status" "$STATUS_JSON"; kv "macOS env" "$MAC_PRECONFIG"
  echo; echo "${BOLD}Scan summary${RESET}"
  kv "CPU" "$CPU_MODEL"; kv "Cores" "$CPU_CORES"; kv "RAM GB" "$RAM_GB"; kv "GPU" "$GPU_NAME"; kv "VRAM MB" "$GPU_VRAM_MB"; kv "Primary IP" "$HOST_PRIMARY_IP"
  echo; echo "${BOLD}Services${RESET}"
  if systemd_available && systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then systemctl is-active ollama >/dev/null 2>&1 && echo "  Ollama:     ${GREEN}active${RESET}" || echo "  Ollama:     ${RED}inactive${RESET}"; else echo "  Ollama:     ${YELLOW}no system service detected${RESET}"; fi
  if systemd_user_available; then systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 && echo "  LiteLLM:    ${GREEN}active${RESET}" || echo "  LiteLLM:    ${RED}inactive${RESET}"; else echo "  LiteLLM:    ${YELLOW}systemd-user unavailable${RESET}"; fi
  echo
  curl -fsS --connect-timeout 2 "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null 2>&1 && log OK "Ollama HTTP healthy" || log WARN "Ollama HTTP not responding"
  curl -fsS --connect-timeout 2 -H "Authorization: Bearer $LITELLM_KEY" "http://127.0.0.1:$LITELLM_PORT/v1/models" >/dev/null 2>&1 && log OK "LiteLLM HTTP healthy" || log WARN "LiteLLM HTTP not responding"
}

print_env() { safe_source_env "$SCAN_ENV"; HOST_PRIMARY_IP="$(primary_ip)"; write_exports; cat "$HOST_EXPORT"; }
print_mac_env() { print_env; echo; echo "# Copy to macOS VM:"; echo "#   scp '$MAC_PRECONFIG' user@mac-vm:~/macos-host-preconfig.env"; echo "#   HOST_CONFIG_PATH=~/macos-host-preconfig.env ./scripts/macos-vm-claude-client-v2.sh install"; }
show_logs() { echo "${BOLD}Recent Ollama logs${RESET}"; journalctl -u ollama -n 100 --no-pager 2>/dev/null || tail -n 100 "$LOG_DIR/ollama-serve.log" 2>/dev/null || true; echo; echo "${BOLD}Recent LiteLLM logs${RESET}"; journalctl --user -u "$SERVICE_NAME" -n 160 --no-pager 2>/dev/null || tail -n 160 "$LOG_DIR/litellm.log" 2>/dev/null || true; }

restart_stack() {
  step "Restart stack"
  if systemd_available && systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then require_sudo; run sudo systemctl restart ollama; else stop_pidfile "$OLLAMA_PIDFILE" "Ollama"; configure_ollama_service; fi
  if systemd_user_available; then run systemctl --user restart "$SERVICE_NAME" || true; else stop_pidfile "$LITELLM_PIDFILE" "LiteLLM"; start_litellm_service; fi
  probe
}

stop_stack() {
  step "Stop stack"
  if systemd_user_available; then run systemctl --user stop "$SERVICE_NAME" || true; fi
  stop_pidfile "$LITELLM_PIDFILE" "LiteLLM"
  stop_pidfile "$OLLAMA_PIDFILE" "Ollama"
  log OK "Tracked fallback processes stopped"
}

confirm_uninstall() {
  [[ "$CONFIRM_UNINSTALL" == "1" ]] && return 0
  echo "This will remove LiteLLM venv/config/status files under: $BASE_DIR and $STATE_DIR"
  read -r -p "Type 'uninstall' to continue: " answer
  [[ "$answer" == "uninstall" ]] || { log WARN "Uninstall cancelled"; exit 0; }
}

uninstall_stack() {
  step "Uninstall LiteLLM stack files"
  confirm_uninstall
  stop_stack
  if systemd_user_available; then systemctl --user disable "$SERVICE_NAME" || true; rm -f "$HOME/.config/systemd/user/$SERVICE_NAME"; systemctl --user daemon-reload || true; fi
  [[ "$VENV_DIR" == "$BASE_DIR"/* ]] && rm -rf "$VENV_DIR"
  rm -f "$LITELLM_CONFIG" "$STATUS_JSON"
  if [[ "$REMOVE_UFW_RULES_ON_UNINSTALL" == "1" && "$AUTO_CONFIGURE_UFW" == "1" ]] && command_exists ufw && sudo ufw status | grep -q "Status: active"; then require_sudo; sudo ufw delete allow "$OLLAMA_PORT/tcp" 2>/dev/null || true; sudo ufw delete allow "$LITELLM_PORT/tcp" 2>/dev/null || true; log OK "Removed UFW rules for $OLLAMA_PORT and $LITELLM_PORT"; fi
  log OK "Removed LiteLLM venv/config/status. Ollama models kept."
}

summary() {
  preconfigure_macos_files
  local elapsed="$(( $(date +%s) - START_TS ))"
  echo; echo "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${RESET}"; echo "${GREEN}${BOLD}║                              HOST STACK READY                               ║${RESET}"; echo "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${RESET}"
  echo; kv "Model alias" "$MODEL_ALIAS"; kv "Model source" "$MODEL_SOURCE"; kv "Context" "$NUM_CTX"; kv "GPU" "$GPU_NAME / ${GPU_VRAM_MB} MB"; kv "Primary IP" "$HOST_PRIMARY_IP"; kv "LiteLLM" "http://$HOST_PRIMARY_IP:$LITELLM_PORT"; kv "Ollama" "http://$HOST_PRIMARY_IP:$OLLAMA_PORT"; kv "macOS env" "$MAC_PRECONFIG"; kv "Bootstrap" "$MAC_BOOTSTRAP"; kv "Status JSON" "$STATUS_JSON"; kv "Log" "$LOG_FILE"; kv "Elapsed" "${elapsed}s"
  echo; echo "${CYAN}${BOLD}macOS VM command:${RESET}"; echo "  HOST_CONFIG_PATH=$MAC_PRECONFIG ./scripts/macos-vm-claude-client-v2.sh install"; echo
}

install_stack() { banner; os_guard; collect_scan; auto_tune_from_scan; ascii_topology; apt_install_base; preflight_ports; install_ollama; configure_ollama_service; pull_model; create_wrapper_model; install_litellm; enable_linger_if_needed; start_litellm_service; configure_firewall; probe; summary; }

case "${1:-install}" in
  install) install_stack ;;
  scan) print_scan ;;
  status) print_status ;;
  logs) show_logs ;;
  restart) restart_stack ;;
  stop) stop_stack ;;
  env) print_env ;;
  mac-env) print_mac_env ;;
  preconfigure) collect_scan; auto_tune_from_scan; preconfigure_macos_files ;;
  uninstall) uninstall_stack ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
