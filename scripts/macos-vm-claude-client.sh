#!/usr/bin/env bash
# shellcheck shell=bash
#
# macOS VM client installer for Claude Code using a preconfigured Ubuntu-hosted
# Ollama/LiteLLM proxy.
#
# The Ubuntu host script generates host-connection.env / macos-host-preconfig.env.
# This script can import that file, persist it locally, and configure Claude Code.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${APP_NAME:-mac-claude-code}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
LITELLM_KEY="${LITELLM_KEY:-local-dev-key}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
HOST_IP="${HOST_IP:-}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-}"
HOST_CONFIG_PATH="${HOST_CONFIG_PATH:-}"
INSTALL_BREW_IF_MISSING="${INSTALL_BREW_IF_MISSING:-1}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
TRY_OLLAMA_LAUNCH="${TRY_OLLAMA_LAUNCH:-0}"
WRITE_SHELL_PROFILE="${WRITE_SHELL_PROFILE:-1}"
PROJECT_ENV_PATH="${PROJECT_ENV_PATH:-$(pwd)/.env}"
FORCE_ENV_REWRITE="${FORCE_ENV_REWRITE:-1}"

STATE_DIR="$HOME/Library/Logs/$APP_NAME"
DATA_DIR="$HOME/Library/Application Support/$APP_NAME"
CONFIG_DIR="$HOME/.config/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
PERSISTED_HOST_CONFIG="$CONFIG_DIR/host-connection.env"
LOG_FILE="$STATE_DIR/client-$(date +%Y%m%d-%H%M%S).log"
STATUS_JSON="$DATA_DIR/status.json"

mkdir -p "$STATE_DIR" "$DATA_DIR" "$CONFIG_DIR" "$BIN_DIR"
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
DETECTED_HOST_IP=""
DETECTED_LITELLM_BASE=""
DETECTED_OLLAMA_BASE=""

on_error() {
  local exit_code=$?
  echo
  echo "${RED}${BOLD}✘ FAILURE${RESET} step=${CURRENT_STEP} line=${BASH_LINENO[0]} exit=$exit_code"
  echo "${DIM}Log: $LOG_FILE${RESET}"
  echo
  echo "Recovery:"
  echo "  HOST_CONFIG_PATH=./macos-host-preconfig.env $0 install"
  echo "  HOST_IP=<ubuntu-host-ip> $0 install"
  echo "  $0 doctor"
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

kv() {
  printf "%-22s %s\n" "$1:" "$2"
}

banner() {
  clear || true
  cat <<'ART'
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║       ███╗   ███╗ █████╗  ██████╗     ██╗   ██╗███╗   ███╗                  ║
║       ████╗ ████║██╔══██╗██╔════╝     ██║   ██║████╗ ████║                  ║
║       ██╔████╔██║███████║██║          ██║   ██║██╔████╔██║                  ║
║       ██║╚██╔╝██║██╔══██║██║          ╚██╗ ██╔╝██║╚██╔╝██║                  ║
║       ██║ ╚═╝ ██║██║  ██║╚██████╗      ╚████╔╝ ██║ ╚═╝ ██║                  ║
║       ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝       ╚═══╝  ╚═╝     ╚═╝                  ║
║                                                                              ║
║       Claude Code VM Client: import host config → verify → write .env         ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
ART
}

usage() {
  cat <<USAGE
Usage:
  ./scripts/macos-vm-claude-client.sh [command]

Commands:
  install       Import host config, install tools, write .env, create wrappers. Default.
  import-host   Import host preconfig only.
  status        Check local tools and the preconfigured host endpoint.
  env           Print Claude Code environment values.
  launch        Launch Claude Code through claude-local.
  doctor        Extended diagnostics.
  uninstall     Remove generated wrappers and local status file. Project .env kept.
  help          Show this help.

Host preconfiguration sources, in priority order:
  1. HOST_CONFIG_PATH=/path/to/macos-host-preconfig.env
  2. ./macos-host-preconfig.env
  3. ./host-connection.env
  4. ~/.config/mac-claude-code/host-connection.env
  5. ~/Library/Application Support/mac-claude-code/host-connection.env
  6. HOST_IP / LITELLM_BASE_URL env vars
  7. network probing fallback

Useful overrides:
  HOST_IP=192.168.1.50
  HOST_CONFIG_PATH=./macos-host-preconfig.env
  PROJECT_ENV_PATH=/path/to/project/.env
  INSTALL_BREW_IF_MISSING=0
  INSTALL_CLAUDE_CODE=0
USAGE
}

ascii_topology() {
  cat <<TOPOLOGY

${BLUE}${BOLD}Client topology${RESET}

  ┌──────────────────────────────────────────────────────────────┐
  │ macOS VM                                                      │
  │ VS Code + Node + Claude Code CLI                              │
  └──────────────┬───────────────────────────────────────────────┘
                 │ ANTHROPIC_BASE_URL=$DETECTED_LITELLM_BASE
                 ▼
        ┌───────────────────────┐
        │ Ubuntu Host LiteLLM   │  $DETECTED_LITELLM_BASE
        └───────────┬───────────┘
                    │
                    ▼
        ┌───────────────────────┐
        │ Ubuntu Host Ollama    │  $DETECTED_OLLAMA_BASE
        │ $MODEL_ALIAS
        └───────────────────────┘

TOPOLOGY
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

find_host_config() {
  local candidates=()
  [[ -n "$HOST_CONFIG_PATH" ]] && candidates+=("$HOST_CONFIG_PATH")
  candidates+=("$(pwd)/macos-host-preconfig.env")
  candidates+=("$(pwd)/host-connection.env")
  candidates+=("$PERSISTED_HOST_CONFIG")
  candidates+=("$DATA_DIR/host-connection.env")

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

load_host_config() {
  step "Host preconfiguration"
  local config_path=""
  if config_path="$(find_host_config)"; then
    log INFO "Loading host config: $config_path"
    set -a
    # shellcheck disable=SC1090
    source "$config_path"
    set +a

    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
    cp "$config_path" "$PERSISTED_HOST_CONFIG"
    cp "$config_path" "$DATA_DIR/host-connection.env"
    chmod 600 "$PERSISTED_HOST_CONFIG" "$DATA_DIR/host-connection.env"
    log OK "Persisted host config: $PERSISTED_HOST_CONFIG"
  else
    log WARN "No host preconfig file found; using environment/probe fallback"
  fi

  MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
  LITELLM_KEY="${LITELLM_KEY:-local-dev-key}"
  LITELLM_PORT="${LITELLM_PORT:-4000}"
  OLLAMA_PORT="${OLLAMA_PORT:-11434}"

  if [[ -n "${ANTHROPIC_BASE_URL:-}" && -z "$LITELLM_BASE_URL" ]]; then
    LITELLM_BASE_URL="$ANTHROPIC_BASE_URL"
  fi

  if [[ -n "$LITELLM_BASE_URL" && -z "$HOST_IP" ]]; then
    HOST_IP="$(printf '%s' "$LITELLM_BASE_URL" | sed -E 's#^https?://([^:/]+).*#\1#')"
  fi

  if [[ -n "$HOST_IP" ]]; then
    DETECTED_HOST_IP="$HOST_IP"
    DETECTED_LITELLM_BASE="${LITELLM_BASE_URL:-http://$HOST_IP:$LITELLM_PORT}"
    DETECTED_OLLAMA_BASE="${OLLAMA_HOST_URL:-http://$HOST_IP:$OLLAMA_PORT}"
    log OK "Preconfigured host: $DETECTED_HOST_IP"
    log OK "Preconfigured LiteLLM: $DETECTED_LITELLM_BASE"
    log OK "Preconfigured Ollama:  $DETECTED_OLLAMA_BASE"
  fi
}

ensure_path() {
  step "PATH setup"
  export PATH="$BIN_DIR:$HOME/.npm-global/bin:$PATH"

  if [[ "$WRITE_SHELL_PROFILE" == "1" ]]; then
    touch "$HOME/.zshrc"
    if ! grep -qF "$BIN_DIR" "$HOME/.zshrc"; then
      {
        echo ""
        echo "# $APP_NAME local binaries"
        echo "export PATH=\"$BIN_DIR:\$HOME/.npm-global/bin:\$PATH\""
      } >> "$HOME/.zshrc"
    fi
  fi
  log OK "PATH configured"
}

install_homebrew_if_needed() {
  step "Homebrew"
  if command_exists brew; then
    log OK "Homebrew found"
    return
  fi

  if [[ "$INSTALL_BREW_IF_MISSING" != "1" ]]; then
    log WARN "Homebrew missing; INSTALL_BREW_IF_MISSING=0"
    return
  fi

  log INFO "Installing Homebrew non-interactively"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if [[ "$WRITE_SHELL_PROFILE" == "1" ]]; then
    touch "$HOME/.zprofile"
    if ! grep -q "brew shellenv" "$HOME/.zprofile"; then
      {
        echo ""
        echo "# Homebrew"
        if [[ -x /opt/homebrew/bin/brew ]]; then
          echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
        elif [[ -x /usr/local/bin/brew ]]; then
          echo 'eval "$(/usr/local/bin/brew shellenv)"'
        fi
      } >> "$HOME/.zprofile"
    fi
  fi
  log OK "Homebrew installed"
}

install_node() {
  step "Node.js"
  if command_exists node && command_exists npm; then
    log OK "Node $(node --version), npm $(npm --version)"
    return
  fi

  if command_exists brew; then
    run brew install node
  else
    log ERR "Node.js missing and Homebrew unavailable. Install Node.js or allow Homebrew install."
    exit 1
  fi
}

configure_npm_global() {
  step "npm global prefix"
  local prefix="$HOME/.npm-global"
  mkdir -p "$prefix"
  npm config set prefix "$prefix" >/dev/null
  export PATH="$prefix/bin:$PATH"

  if [[ "$WRITE_SHELL_PROFILE" == "1" ]]; then
    touch "$HOME/.zshrc"
    if ! grep -qF "$prefix/bin" "$HOME/.zshrc"; then
      {
        echo ""
        echo "# npm global binaries"
        echo "export PATH=\"$prefix/bin:\$PATH\""
      } >> "$HOME/.zshrc"
    fi
  fi
  log OK "npm prefix: $prefix"
}

install_claude_code() {
  step "Claude Code CLI"
  if [[ "$INSTALL_CLAUDE_CODE" != "1" ]]; then
    log WARN "Skipping Claude Code install"
    return
  fi

  if command_exists claude; then
    log OK "Claude already available: $(claude --version || true)"
    return
  fi

  run npm install -g @anthropic-ai/claude-code
  command_exists claude
  log OK "Claude installed: $(claude --version || true)"
}

default_gateway() {
  route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true
}

unique_candidates() {
  {
    [[ -n "$DETECTED_HOST_IP" ]] && echo "$DETECTED_HOST_IP"
    [[ -n "$HOST_IP" ]] && echo "$HOST_IP"
    default_gateway
    echo "10.0.2.2"
    echo "192.168.64.1"
    echo "172.16.0.1"
    echo "192.168.1.1"
  } | awk 'NF && !seen[$0]++'
}

probe_url() {
  local url="$1"
  curl -fsS --connect-timeout 2 -H "Authorization: Bearer $LITELLM_KEY" "$url" >/dev/null 2>&1
}

probe_host() {
  step "Host verification"

  if [[ -n "$DETECTED_LITELLM_BASE" ]]; then
    log INFO "Testing preconfigured LiteLLM: $DETECTED_LITELLM_BASE"
    if probe_url "$DETECTED_LITELLM_BASE/v1/models"; then
      log OK "Preconfigured LiteLLM is reachable"
      return 0
    fi
    log WARN "Preconfigured LiteLLM did not respond; falling back to candidate probing"
  fi

  local candidate proxy_url ollama_url
  for candidate in $(unique_candidates); do
    proxy_url="http://$candidate:$LITELLM_PORT/v1/models"
    ollama_url="http://$candidate:$OLLAMA_PORT/api/tags"
    log INFO "Probing $proxy_url"

    if probe_url "$proxy_url"; then
      DETECTED_HOST_IP="$candidate"
      DETECTED_LITELLM_BASE="http://$candidate:$LITELLM_PORT"
      DETECTED_OLLAMA_BASE="http://$candidate:$OLLAMA_PORT"
      log OK "LiteLLM detected: $DETECTED_LITELLM_BASE"

      if curl -fsS --connect-timeout 2 "$ollama_url" >/dev/null 2>&1; then
        log OK "Ollama detected: $DETECTED_OLLAMA_BASE"
      else
        log WARN "Ollama direct endpoint unreachable; LiteLLM is enough for Claude Code"
      fi
      return 0
    fi
  done

  log ERR "Could not verify Ubuntu host LiteLLM proxy"
  echo "Use one of:"
  echo "  HOST_CONFIG_PATH=./macos-host-preconfig.env $0 install"
  echo "  HOST_IP=<ubuntu-host-ip> $0 install"
  exit 1
}

write_project_env() {
  step "Claude Code environment"
  local env_dir
  env_dir="$(dirname "$PROJECT_ENV_PATH")"
  mkdir -p "$env_dir"

  if [[ -f "$PROJECT_ENV_PATH" && "$FORCE_ENV_REWRITE" == "1" ]]; then
    cp "$PROJECT_ENV_PATH" "$PROJECT_ENV_PATH.bak.$(date +%Y%m%d-%H%M%S)"
    log WARN "Existing env backed up before rewrite"
  elif [[ -f "$PROJECT_ENV_PATH" && "$FORCE_ENV_REWRITE" != "1" ]]; then
    log WARN "Env exists and FORCE_ENV_REWRITE=0; leaving untouched"
    return
  fi

  cat > "$PROJECT_ENV_PATH" <<ENVEOF
ANTHROPIC_API_KEY=$LITELLM_KEY
ANTHROPIC_BASE_URL=$DETECTED_LITELLM_BASE
ANTHROPIC_MODEL=$MODEL_ALIAS
ENVEOF
  chmod 600 "$PROJECT_ENV_PATH"

  local gitignore_path="$env_dir/.gitignore"
  if [[ -f "$gitignore_path" ]]; then
    grep -qxF ".env" "$gitignore_path" || echo ".env" >> "$gitignore_path"
    grep -qxF ".env.*" "$gitignore_path" || echo ".env.*" >> "$gitignore_path"
  else
    {
      echo ".env"
      echo ".env.*"
      echo "!.env.example"
    } > "$gitignore_path"
  fi

  log OK "Wrote $PROJECT_ENV_PATH"
}

create_wrappers() {
  step "Client wrappers"

  cat > "$BIN_DIR/claude-local" <<'CLAUDELOCAL'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

exec claude "$@"
CLAUDELOCAL
  chmod +x "$BIN_DIR/claude-local"

  cat > "$BIN_DIR/qwen-stack-status" <<STATUSEOF
#!/usr/bin/env bash
set -Eeuo pipefail
MODEL_ALIAS="$MODEL_ALIAS"
LITELLM_KEY="$LITELLM_KEY"
LITELLM_BASE="$DETECTED_LITELLM_BASE"
OLLAMA_BASE="$DETECTED_OLLAMA_BASE"
GREEN="\\033[32m"; RED="\\033[31m"; YELLOW="\\033[33m"; CYAN="\\033[36m"; BOLD="\\033[1m"; RESET="\\033[0m"
echo
echo "[36m[1mQwen Claude Stack Status[0m"
echo "  model:    \$MODEL_ALIAS"
echo "  litellm:  \$LITELLM_BASE"
echo "  ollama:   \$OLLAMA_BASE"
echo
curl -fsS -H "Authorization: Bearer \$LITELLM_KEY" "\$LITELLM_BASE/v1/models" >/dev/null && echo "  LiteLLM: \${GREEN}OK\${RESET}" || echo "  LiteLLM: \${RED}FAIL\${RESET}"
curl -fsS "\$OLLAMA_BASE/api/tags" >/dev/null && echo "  Ollama:  \${GREEN}OK\${RESET}" || echo "  Ollama:  \${YELLOW}UNREACHABLE DIRECTLY\${RESET}"
echo
STATUSEOF
  chmod +x "$BIN_DIR/qwen-stack-status"

  if [[ "$WRITE_SHELL_PROFILE" == "1" ]]; then
    touch "$HOME/.zshrc"
    if ! grep -q "alias clocal=" "$HOME/.zshrc"; then
      {
        echo ""
        echo "# $APP_NAME helpers"
        echo "alias clocal='claude-local'"
        echo "alias qstatus='qwen-stack-status'"
      } >> "$HOME/.zshrc"
    fi
  fi

  log OK "Created claude-local and qwen-stack-status"
}

write_status_json() {
  local elapsed="$(( $(date +%s) - START_TS ))"
  cat > "$STATUS_JSON" <<JSONEOF
{
  "status": "ready",
  "app": "$APP_NAME",
  "model_alias": "$MODEL_ALIAS",
  "host_ip": "$DETECTED_HOST_IP",
  "litellm_base_url": "$DETECTED_LITELLM_BASE",
  "ollama_base_url": "$DETECTED_OLLAMA_BASE",
  "project_env_path": "$PROJECT_ENV_PATH",
  "persisted_host_config": "$PERSISTED_HOST_CONFIG",
  "log_file": "$LOG_FILE",
  "elapsed_seconds": $elapsed,
  "updated_at": "$(date -Iseconds)"
}
JSONEOF
}

try_ollama_launch() {
  if [[ "$TRY_OLLAMA_LAUNCH" != "1" ]]; then
    return
  fi

  step "Ollama launcher"
  if command_exists ollama && ollama launch --help >/dev/null 2>&1; then
    export OLLAMA_HOST="$DETECTED_OLLAMA_BASE"
    ollama launch claude --model "$MODEL_ALIAS" || true
  else
    log WARN "ollama launch unavailable; using Claude Code env route"
  fi
}

print_env() {
  load_host_config || true
  probe_host || true
  cat <<ENVOUT
ANTHROPIC_API_KEY=$LITELLM_KEY
ANTHROPIC_BASE_URL=$DETECTED_LITELLM_BASE
ANTHROPIC_MODEL=$MODEL_ALIAS
ENVOUT
}

print_status() {
  banner
  load_host_config || true
  ascii_topology
  echo "${BOLD}Local tools${RESET}"
  command_exists node && kv "node" "$(node --version)" || kv "node" "missing"
  command_exists npm && kv "npm" "$(npm --version)" || kv "npm" "missing"
  command_exists claude && kv "claude" "$(claude --version || true)" || kv "claude" "missing"
  kv "env" "$PROJECT_ENV_PATH"
  kv "host config" "$PERSISTED_HOST_CONFIG"
  kv "log" "$LOG_FILE"
  echo

  if [[ -f "$STATUS_JSON" ]]; then
    echo "${BOLD}Last status${RESET}"
    cat "$STATUS_JSON"
    echo
  fi

  if [[ -n "$DETECTED_LITELLM_BASE" ]]; then
    curl -fsS -H "Authorization: Bearer $LITELLM_KEY" "$DETECTED_LITELLM_BASE/v1/models" >/dev/null 2>&1 && log OK "LiteLLM healthy" || log WARN "LiteLLM unreachable"
  fi
}

doctor() {
  banner
  load_host_config || true
  echo "${BOLD}Network candidates${RESET}"
  unique_candidates | sed 's/^/  - /'
  echo
  echo "${BOLD}Route${RESET}"
  route -n get default 2>/dev/null || true
  echo
  echo "${BOLD}DNS / network${RESET}"
  ping -c 1 1.1.1.1 >/dev/null 2>&1 && log OK "Internet reachable" || log WARN "Internet ping failed"
  echo
  probe_host || true
  print_status
}

launch_claude() {
  if [[ -f "$PROJECT_ENV_PATH" ]]; then
    cd "$(dirname "$PROJECT_ENV_PATH")"
  fi
  exec claude-local
}

uninstall_client() {
  step "Uninstall client generated files"
  rm -f "$BIN_DIR/claude-local" "$BIN_DIR/qwen-stack-status" "$STATUS_JSON"
  log OK "Removed wrappers and status file. Project .env and persisted host config kept."
}

summary() {
  write_status_json
  echo
  echo "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${RESET}"
  echo "${GREEN}${BOLD}║                              MAC CLIENT READY                               ║${RESET}"
  echo "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${RESET}"
  echo
  kv "Host IP" "$DETECTED_HOST_IP"
  kv "LiteLLM" "$DETECTED_LITELLM_BASE"
  kv "Ollama" "$DETECTED_OLLAMA_BASE"
  kv "Model" "$MODEL_ALIAS"
  kv "Env file" "$PROJECT_ENV_PATH"
  kv "Host config" "$PERSISTED_HOST_CONFIG"
  kv "Status JSON" "$STATUS_JSON"
  kv "Log file" "$LOG_FILE"
  echo
  echo "${CYAN}${BOLD}Run:${RESET}"
  echo "  qwen-stack-status"
  echo "  claude-local"
  echo
  echo "${CYAN}${BOLD}Inside Claude Code:${RESET}"
  echo "  /status"
  echo
}

import_host_only() {
  banner
  load_host_config
  probe_host
  write_status_json
  log OK "Host config imported and verified"
}

install_client() {
  banner
  load_host_config
  probe_host
  ascii_topology
  ensure_path
  install_homebrew_if_needed
  install_node
  configure_npm_global
  install_claude_code
  write_project_env
  create_wrappers
  try_ollama_launch
  summary
}

case "${1:-install}" in
  install) install_client ;;
  import-host) import_host_only ;;
  status) print_status ;;
  env) print_env ;;
  launch) launch_claude ;;
  doctor) doctor ;;
  uninstall) uninstall_client ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
