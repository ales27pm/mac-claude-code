#!/usr/bin/env bash
# shellcheck shell=bash
#
# Ubuntu host installer for a local Claude Code-compatible coding stack:
#   Ollama -> Qwen Coder abliterated -> LiteLLM OpenAI-compatible proxy -> macOS VM client
#
# Designed for repeated runs. It is idempotent, logged, defensive, and reversible enough
# for a workstation/dev-machine setup.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${APP_NAME:-mac-claude-code}"
STACK_NAME="${STACK_NAME:-qwen-claude-stack}"
MODEL_SOURCE="${MODEL_SOURCE:-dagbs/qwen2.5-coder-7b-instruct-abliterated:q4_k_m}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_KEY:-local-dev-key}"
NUM_CTX="${NUM_CTX:-8192}"
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

BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/${APP_NAME}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${APP_NAME}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME}"
LOG_DIR="$STATE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"
MODEL_DIR="$BASE_DIR/models/$MODEL_ALIAS"
VENV_DIR="$BASE_DIR/venv"
LITELLM_CONFIG="$CONFIG_DIR/litellm.yaml"
HOST_EXPORT="$BASE_DIR/host-connection.env"
STATUS_JSON="$STATE_DIR/status.json"
SERVICE_NAME="${APP_NAME}-litellm.service"
LOG_FILE="$LOG_DIR/host-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$MODEL_DIR" "$CACHE_DIR"
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

on_error() {
  local exit_code=$?
  echo
  echo "${RED}${BOLD}✘ FAILURE${RESET} step=${CURRENT_STEP} line=${BASH_LINENO[0]} exit=$exit_code"
  echo "${DIM}Log: $LOG_FILE${RESET}"
  echo
  echo "Quick probes:"
  echo "  systemctl status ollama --no-pager || true"
  echo "  journalctl -u ollama -n 80 --no-pager || true"
  echo "  systemctl --user status $SERVICE_NAME --no-pager || true"
  echo "  curl -v http://127.0.0.1:$OLLAMA_PORT/api/tags"
  echo "  curl -v -H 'Authorization: Bearer $LITELLM_KEY' http://127.0.0.1:$LITELLM_PORT/v1/models"
  exit "$exit_code"
}
trap on_error ERR

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

step() {
  CURRENT_STEP="$1"
  echo
  log STEP "$1"
}

run() {
  log INFO "$*"
  "$@"
}

banner() {
  clear || true
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║    ███╗   ███╗ █████╗  ██████╗      ██████╗██╗      █████╗ ██╗   ██╗██████╗ ║
║    ████╗ ████║██╔══██╗██╔════╝     ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗║
║    ██╔████╔██║███████║██║          ██║     ██║     ███████║██║   ██║██║  ██║║
║    ██║╚██╔╝██║██╔══██║██║          ██║     ██║     ██╔══██║██║   ██║██║  ██║║
║    ██║ ╚═╝ ██║██║  ██║╚██████╗     ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝║
║    ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝      ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ║
║                                                                              ║
║          Ubuntu Host Installer: Ollama + Qwen Coder + LiteLLM Proxy          ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

usage() {
  cat <<EOF
Usage:
  ./scripts/ubuntu-host-qwen-claude-stack.sh [command]

Commands:
  install       Install/configure everything. Default.
  status        Print stack status and health checks.
  logs          Tail recent LiteLLM/Ollama logs.
  restart       Restart Ollama and LiteLLM.
  stop          Stop LiteLLM user service only.
  env           Print VM environment export values.
  uninstall     Remove LiteLLM service/venv/config only. Does not delete Ollama models.
  help          Show this help.

Useful environment overrides:
  MODEL_SOURCE=dagbs/qwen2.5-coder-7b-instruct-abliterated:q5_k_m
  MODEL_ALIAS=qwen-coder-ablit
  NUM_CTX=8192
  LITELLM_KEY=local-dev-key
  OPEN_TO_LAN=1
  SKIP_MODEL_PULL=1
  FORCE_REINSTALL_LITELLM=1
EOF
}

ascii_topology() {
  cat <<EOF

${BLUE}${BOLD}Topology${RESET}

  ┌──────────────────────────────────────────────────────────────┐
  │ Ubuntu Host                                                   │
  │ CPU/RAM + NVIDIA GPU if available                            │
  └──────────────┬───────────────────────────────────────────────┘
                 │
                 │ http://0.0.0.0:$OLLAMA_PORT
                 ▼
        ┌───────────────────────┐
        │ Ollama                │
        │ $MODEL_ALIAS
        │ $MODEL_SOURCE
        └───────────┬───────────┘
                    │ localhost
                    ▼
        ┌───────────────────────┐
        │ LiteLLM Proxy         │
        │ OpenAI-compatible API │
        │ http://0.0.0.0:$LITELLM_PORT
        └───────────┬───────────┘
                    │ LAN / VM NAT bridge
                    ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ macOS VM                                                      │
  │ Claude Code CLI via ANTHROPIC_* environment variables         │
  └──────────────────────────────────────────────────────────────┘

EOF
}

require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    log WARN "sudo required; requesting elevation"
    sudo true
  fi
}

os_guard() {
  step "OS guard"
  if [[ ! -f /etc/os-release ]]; then
    log ERR "This script is intended for Ubuntu/Linux hosts. /etc/os-release missing."
    exit 1
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  log INFO "Detected: ${PRETTY_NAME:-Linux}"
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then
    log WARN "Not Ubuntu/Debian-like. Continuing, but package install may fail."
  fi
}

apt_install_base() {
  step "Base packages"
  if [[ "$SKIP_APT" == "1" ]]; then
    log WARN "Skipping apt package installation"
    return
  fi
  require_sudo
  run sudo apt-get update
  run sudo apt-get install -y curl ca-certificates jq python3 python3-venv python3-pip lsof net-tools iproute2 ufw procps gawk
}

detect_gpu() {
  step "GPU detection"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
    local gpu_name="unknown"
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || true)"
    log OK "NVIDIA detected: ${gpu_name:-unknown}"
  else
    log WARN "nvidia-smi not found. Ollama may run CPU-only. Install NVIDIA drivers/CUDA runtime if needed."
  fi
}

install_ollama() {
  step "Ollama installation"
  if command -v ollama >/dev/null 2>&1; then
    log OK "Ollama found: $(ollama --version || true)"
  else
    log INFO "Installing Ollama from official installer"
    curl -fsSL https://ollama.com/install.sh | sh
  fi
}

configure_ollama_service() {
  step "Ollama service configuration"
  local host_bind="127.0.0.1:$OLLAMA_PORT"
  if [[ "$OPEN_TO_LAN" == "1" ]]; then
    host_bind="0.0.0.0:$OLLAMA_PORT"
  fi

  if systemctl list-unit-files | grep -q '^ollama.service'; then
    require_sudo
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=$host_bind"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF
    run sudo systemctl daemon-reload
    run sudo systemctl enable ollama
    run sudo systemctl restart ollama
    sleep 2
    log OK "Ollama service bound to $host_bind"
  else
    log WARN "No systemd Ollama service found. Launching temporary server in background."
    pkill -f "ollama serve" || true
    nohup env OLLAMA_HOST="$host_bind" OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 ollama serve >"$LOG_DIR/ollama-serve.log" 2>&1 &
    sleep 3
  fi
}

wait_for_http() {
  local url="$1"
  local header_arg="${2:-}"
  local attempts="${3:-30}"
  local delay="${4:-1}"
  local i
  for ((i=1; i<=attempts; i++)); do
    if [[ -n "$header_arg" ]]; then
      if curl -fsS --connect-timeout 2 -H "$header_arg" "$url" >/dev/null 2>&1; then
        return 0
      fi
    else
      if curl -fsS --connect-timeout 2 "$url" >/dev/null 2>&1; then
        return 0
      fi
    fi
    printf "%s" "${DIM}.${RESET}"
    sleep "$delay"
  done
  echo
  return 1
}

pull_model() {
  step "Model pull"
  if [[ "$SKIP_MODEL_PULL" == "1" ]]; then
    log WARN "Skipping model pull"
    return
  fi
  run ollama pull "$MODEL_SOURCE"
  log OK "Pulled: $MODEL_SOURCE"
}

model_exists() {
  ollama list 2>/dev/null | awk '{print $1}' | grep -Fxq "$MODEL_ALIAS"
}

create_wrapper_model() {
  step "Wrapper model"
  cat > "$MODEL_DIR/Modelfile" <<EOF
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
EOF

  if model_exists && [[ "$FORCE_RECREATE_MODEL" != "1" ]]; then
    log OK "Wrapper model already exists: $MODEL_ALIAS"
  else
    run ollama create "$MODEL_ALIAS" -f "$MODEL_DIR/Modelfile"
    log OK "Wrapper model created: $MODEL_ALIAS"
  fi
}

install_litellm() {
  step "LiteLLM installation"
  if [[ "$FORCE_REINSTALL_LITELLM" == "1" && -d "$VENV_DIR" ]]; then
    log WARN "Removing existing venv because FORCE_REINSTALL_LITELLM=1"
    rm -rf "$VENV_DIR"
  fi

  if [[ ! -x "$VENV_DIR/bin/litellm" ]]; then
    run python3 -m venv "$VENV_DIR"
    run "$VENV_DIR/bin/python" -m pip install --upgrade pip wheel setuptools
    run "$VENV_DIR/bin/python" -m pip install "litellm[proxy]"
  else
    log OK "LiteLLM already installed in $VENV_DIR"
  fi

  cat > "$LITELLM_CONFIG" <<EOF
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
EOF
  chmod 600 "$LITELLM_CONFIG"
  log OK "LiteLLM config: $LITELLM_CONFIG"
}

start_litellm_service() {
  step "LiteLLM service"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/$SERVICE_NAME" <<EOF
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
EOF

  if [[ "$USE_SYSTEMD_USER" == "1" ]] && systemctl --user status >/dev/null 2>&1; then
    run systemctl --user daemon-reload
    run systemctl --user enable --now "$SERVICE_NAME"
    sleep 3
    log OK "LiteLLM user service started: $SERVICE_NAME"
  else
    log WARN "systemd --user unavailable or disabled. Starting LiteLLM with nohup."
    pkill -f "litellm --config $LITELLM_CONFIG" || true
    nohup "$VENV_DIR/bin/litellm" --config "$LITELLM_CONFIG" --host 0.0.0.0 --port "$LITELLM_PORT" >"$LOG_DIR/litellm.log" 2>&1 &
    sleep 3
  fi
}

configure_firewall() {
  step "Firewall"
  if [[ "$SKIP_FIREWALL" == "1" ]]; then
    log WARN "Skipping firewall changes"
    return
  fi
  if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
    require_sudo
    run sudo ufw allow "$OLLAMA_PORT/tcp"
    run sudo ufw allow "$LITELLM_PORT/tcp"
    log OK "UFW allows ports $OLLAMA_PORT and $LITELLM_PORT"
  else
    log INFO "UFW inactive or unavailable; no firewall rules changed"
  fi
}

host_ips() {
  ip -4 addr show scope global \
    | awk '/inet / {print $2}' \
    | cut -d/ -f1 \
    | grep -v '^127\.' \
    | awk '!seen[$0]++' || true
}

health_json() {
  local status="$1"
  local elapsed="$(( $(date +%s) - START_TS ))"
  local first_ip
  first_ip="$(host_ips | head -n 1 || true)"
  cat > "$STATUS_JSON" <<EOF
{
  "status": "$status",
  "app": "$APP_NAME",
  "model_alias": "$MODEL_ALIAS",
  "model_source": "$MODEL_SOURCE",
  "num_ctx": $NUM_CTX,
  "ollama_port": $OLLAMA_PORT,
  "litellm_port": $LITELLM_PORT,
  "host_ip": "${first_ip:-}",
  "litellm_base_url": "http://${first_ip:-127.0.0.1}:$LITELLM_PORT",
  "ollama_base_url": "http://${first_ip:-127.0.0.1}:$OLLAMA_PORT",
  "log_file": "$LOG_FILE",
  "elapsed_seconds": $elapsed,
  "updated_at": "$(date -Iseconds)"
}
EOF
}

probe() {
  step "Health checks"
  local ollama_url="http://127.0.0.1:$OLLAMA_PORT/api/tags"
  local litellm_url="http://127.0.0.1:$LITELLM_PORT/v1/models"

  wait_for_http "$ollama_url" "" 30 1
  log OK "Ollama responds: $ollama_url"

  wait_for_http "$litellm_url" "Authorization: Bearer $LITELLM_KEY" 30 1
  log OK "LiteLLM responds: $litellm_url"

  log INFO "Generation smoke test"
  local response
  response="$(curl -fsS "http://127.0.0.1:$OLLAMA_PORT/api/generate" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ALIAS\",\"prompt\":\"Return exactly LOCAL_QWEN_READY and nothing else.\",\"stream\":false}" \
    | jq -r '.response' || true)"
  echo "${DIM}${response}${RESET}"

  health_json "ready"
}

write_exports() {
  local first_ip
  first_ip="$(host_ips | head -n 1 || true)"
  cat > "$HOST_EXPORT" <<EOF
# Generated by $APP_NAME on $(date -Iseconds)
MODEL_ALIAS=$MODEL_ALIAS
MODEL_SOURCE=$MODEL_SOURCE
OLLAMA_HOST_URL=http://${first_ip:-127.0.0.1}:$OLLAMA_PORT
LITELLM_BASE_URL=http://${first_ip:-127.0.0.1}:$LITELLM_PORT
LITELLM_KEY=$LITELLM_KEY
ANTHROPIC_API_KEY=$LITELLM_KEY
ANTHROPIC_BASE_URL=http://${first_ip:-127.0.0.1}:$LITELLM_PORT
ANTHROPIC_MODEL=$MODEL_ALIAS
EOF
  chmod 600 "$HOST_EXPORT"
}

print_status() {
  banner
  ascii_topology
  echo "${BOLD}Paths${RESET}"
  echo "  Base:       $BASE_DIR"
  echo "  Config:     $CONFIG_DIR"
  echo "  Logs:       $LOG_DIR"
  echo "  Status:     $STATUS_JSON"
  echo
  echo "${BOLD}Services${RESET}"
  if systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
    systemctl is-active ollama >/dev/null 2>&1 && echo "  Ollama:     ${GREEN}active${RESET}" || echo "  Ollama:     ${RED}inactive${RESET}"
  else
    echo "  Ollama:     ${YELLOW}no system service detected${RESET}"
  fi
  if systemctl --user status >/dev/null 2>&1; then
    systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 && echo "  LiteLLM:    ${GREEN}active${RESET}" || echo "  LiteLLM:    ${RED}inactive${RESET}"
  else
    echo "  LiteLLM:    ${YELLOW}systemd-user unavailable${RESET}"
  fi
  echo
  echo "${BOLD}Network${RESET}"
  host_ips | sed 's/^/  Host IP:   /'
  echo "  Ollama:     http://HOST_IP:$OLLAMA_PORT"
  echo "  LiteLLM:    http://HOST_IP:$LITELLM_PORT"
  echo
  curl -fsS "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null 2>&1 && log OK "Ollama HTTP healthy" || log WARN "Ollama HTTP not responding"
  curl -fsS -H "Authorization: Bearer $LITELLM_KEY" "http://127.0.0.1:$LITELLM_PORT/v1/models" >/dev/null 2>&1 && log OK "LiteLLM HTTP healthy" || log WARN "LiteLLM HTTP not responding"
  echo
}

print_env() {
  write_exports
  cat "$HOST_EXPORT"
}

show_logs() {
  echo "${BOLD}Recent Ollama logs${RESET}"
  journalctl -u ollama -n 80 --no-pager 2>/dev/null || tail -n 80 "$LOG_DIR/ollama-serve.log" 2>/dev/null || true
  echo
  echo "${BOLD}Recent LiteLLM logs${RESET}"
  journalctl --user -u "$SERVICE_NAME" -n 120 --no-pager 2>/dev/null || tail -n 120 "$LOG_DIR/litellm.log" 2>/dev/null || true
}

restart_stack() {
  step "Restart stack"
  if systemctl list-unit-files 2>/dev/null | grep -q '^ollama.service'; then
    require_sudo
    run sudo systemctl restart ollama
  fi
  if systemctl --user status >/dev/null 2>&1; then
    run systemctl --user restart "$SERVICE_NAME" || true
  fi
  probe
}

stop_stack() {
  step "Stop LiteLLM"
  if systemctl --user status >/dev/null 2>&1; then
    run systemctl --user stop "$SERVICE_NAME" || true
  fi
  pkill -f "litellm --config $LITELLM_CONFIG" || true
  log OK "LiteLLM stopped"
}

uninstall_stack() {
  step "Uninstall LiteLLM stack files"
  stop_stack
  if systemctl --user status >/dev/null 2>&1; then
    systemctl --user disable "$SERVICE_NAME" || true
    rm -f "$HOME/.config/systemd/user/$SERVICE_NAME"
    systemctl --user daemon-reload || true
  fi
  rm -rf "$VENV_DIR" "$CONFIG_DIR" "$STATUS_JSON"
  log OK "Removed LiteLLM venv/config/status. Ollama and models kept."
}

summary() {
  write_exports
  local elapsed="$(( $(date +%s) - START_TS ))"
  echo
  echo "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${RESET}"
  echo "${GREEN}${BOLD}║                              HOST STACK READY                               ║${RESET}"
  echo "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${RESET}"
  echo
  echo "  Model alias:       $MODEL_ALIAS"
  echo "  Model source:      $MODEL_SOURCE"
  echo "  Context:           $NUM_CTX"
  echo "  Ollama port:       $OLLAMA_PORT"
  echo "  LiteLLM port:      $LITELLM_PORT"
  echo "  Export file:       $HOST_EXPORT"
  echo "  Status JSON:       $STATUS_JSON"
  echo "  Log file:          $LOG_FILE"
  echo "  Elapsed:           ${elapsed}s"
  echo
  echo "${CYAN}${BOLD}Detected host IPs${RESET}"
  host_ips | sed 's/^/  - /'
  echo
  echo "${CYAN}${BOLD}Run this inside the macOS VM, replacing HOST_IP if needed:${RESET}"
  local ipaddr
  ipaddr="$(host_ips | head -n 1 || true)"
  echo "  HOST_IP=${ipaddr:-<ubuntu-host-ip>} ./scripts/macos-vm-claude-client.sh"
  echo
}

install_stack() {
  banner
  ascii_topology
  os_guard
  apt_install_base
  detect_gpu
  install_ollama
  configure_ollama_service
  pull_model
  create_wrapper_model
  install_litellm
  start_litellm_service
  configure_firewall
  probe
  summary
}

case "${1:-install}" in
  install) install_stack ;;
  status) print_status ;;
  logs) show_logs ;;
  restart) restart_stack ;;
  stop) stop_stack ;;
  env) print_env ;;
  uninstall) uninstall_stack ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
