#!/usr/bin/env bash
# shellcheck shell=bash
#
# macOS VM client installer for Claude Code using a local Ubuntu-hosted
# Ollama/LiteLLM proxy.
#
# The Ubuntu host does the heavy model work. The macOS VM only runs VS Code,
# Node.js, Claude Code CLI, and a small wrapper that loads project .env values.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${APP_NAME:-mac-claude-code}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
LITELLM_KEY="${LITELLM_KEY:-local-dev-key}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
INSTALL_BREW_IF_MISSING="${INSTALL_BREW_IF_MISSING:-1}"
INSTALL_CLAUDE_CODE="${INSTALL_CLAUDE_CODE:-1}"
TRY_OLLAMA_LAUNCH="${TRY_OLLAMA_LAUNCH:-0}"
WRITE_SHELL_PROFILE="${WRITE_SHELL_PROFILE:-1}"
PROJECT_ENV_PATH="${PROJECT_ENV_PATH:-$(pwd)/.env}"

STATE_DIR="$HOME/Library/Logs/$APP_NAME"
DATA_DIR="$HOME/Library/Application Support/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
LOG_FILE="$STATE_DIR/client-$(date +%Y%m%d-%H%M%S).log"
STATUS_JSON="$DATA_DIR/status.json"

mkdir -p "$STATE_DIR" "$DATA_DIR" "$BIN_DIR"
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
  echo "Quick recovery:"
  echo "  HOST_IP=<ubuntu-host-ip> $0 install"
  echo "  $0 status"
  echo "  tail -n 160 '$LOG_FILE'"
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
║       ███╗   ███╗ █████╗  ██████╗     ██╗   ██╗███╗   ███╗                  ║
║       ████╗ ████║██╔══██╗██╔════╝     ██║   ██║████╗ ████║                  ║
║       ██╔████╔██║███████║██║          ██║   ██║██╔████╔██║                  ║
║       ██║╚██╔╝██║██╔══██║██║          ╚██╗ ██╔╝██║╚██╔╝██║                  ║
║       ██║ ╚═╝ ██║██║  ██║╚██████╗      ╚████╔╝ ██║ ╚═╝ ██║                  ║
║       ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝       ╚═══╝  ╚═╝     ╚═╝                  ║
║                                                                              ║
║             Claude Code Client Installer → Ubuntu Host LLM Proxy             ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

usage() {
  cat <<EOF
Usage:
  ./scripts/macos-vm-claude-client.sh [command]

Commands:
  install       Install/configure Node, Claude Code CLI, .env, wrappers. Default.
  status        Check host/proxy/client state.
  env           Print Claude Code environment values.
  launch        Launch Claude Code through the local wrapper.
  doctor        Extended diagnostics.
  uninstall     Remove generated wrapper scripts and local status file.
  help          Show this help.

Useful overrides:
  HOST_IP=192.168.1.50
  MODEL_ALIAS=qwen-coder-ablit
  LITELLM_KEY=local-dev-key
  PROJECT_ENV_PATH=/path/to/project/.env
  INSTALL_BREW_IF_MISSING=0
  INSTALL_CLAUDE_CODE=0
EOF
}

ascii_topology() {
  cat <<EOF

${BLUE}${BOLD}Topology${RESET}

  ┌──────────────────────────────────────────────────────────────┐
  │ macOS VM                                                      │
  │ VS Code + Node + Claude Code CLI                              │
  └──────────────┬───────────────────────────────────────────────┘
                 │ ANTHROPIC_BASE_URL
                 ▼
        ┌───────────────────────┐
        │ Ubuntu Host LiteLLM   │  http://HOST_IP:$LITELLM_PORT
        └───────────┬───────────┘
                    │
                    ▼
        ┌───────────────────────┐
        │ Ubuntu Host Ollama    │  http://HOST_IP:$OLLAMA_PORT
        │ $MODEL_ALIAS
        └───────────────────────┘

EOF
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
  if command -v brew >/dev/null 2>&1; then
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
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log OK "Node $(node --version), npm $(npm --version)"
    return
  fi

  if command -v brew >/dev/null 2>&1; then
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

  if command -v claude >/dev/null 2>&1; then
    log OK "Claude already available: $(claude --version || true)"
    return
  fi

  run npm install -g @anthropic-ai/claude-code
  command -v claude >/dev/null 2>&1
  log OK "Claude installed: $(claude --version || true)"
}

default_gateway() {
  route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true
}

unique_candidates() {
  {
    [[ -n "${HOST_IP:-}" ]] && echo "$HOST_IP"
    default_gateway
    echo "10.0.2.2"
    echo "192.168.64.1"
    echo "172.16.0.1"
    echo "192.168.1.1"
  } | awk 'NF && !seen[$0]++'
}

probe_host() {
  step "Host discovery"
  local candidate proxy_url ollama_url

  for candidate in $(unique_candidates); do
    proxy_url="http://$candidate:$LITELLM_PORT/v1/models"
    ollama_url="http://$candidate:$OLLAMA_PORT/api/tags"
    log INFO "Probing $proxy_url"

    if curl -fsS --connect-timeout 2 -H "Authorization: Bearer $LITELLM_KEY" "$proxy_url" >/dev/null 2>&1; then
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

  log ERR "Could not detect Ubuntu host LiteLLM proxy"
  echo "Run: HOST_IP=<ubuntu-host-ip> $0 install"
  exit 1
}

write_project_env() {
  step "Claude Code environment"
  local env_dir
  env_dir="$(dirname "$PROJECT_ENV_PATH")"
  mkdir -p "$env_dir"

  if [[ -f "$PROJECT_ENV_PATH" ]] && grep -q '^ANTHROPIC_' "$PROJECT_ENV_PATH"; then
    cp "$PROJECT_ENV_PATH" "$PROJECT_ENV_PATH.bak.$(date +%Y%m%d-%H%M%S)"
    log WARN "Existing .env backed up before rewrite"
  fi

  cat > "$PROJECT_ENV_PATH" <<EOF
ANTHROPIC_API_KEY=$LITELLM_KEY
ANTHROPIC_BASE_URL=$DETECTED_LITELLM_BASE
ANTHROPIC_MODEL=$MODEL_ALIAS
EOF
  chmod 600 "$PROJECT_ENV_PATH"

  local gitignore_path="$env_dir/.gitignore"
  if [[ -f "$gitignore_path" ]]; then
    grep -qxF ".env" "$gitignore_path" || echo ".env" >> "$gitignore_path"
  else
    echo ".env" > "$gitignore_path"
  fi

  log OK "Wrote $PROJECT_ENV_PATH"
}

create_wrappers() {
  step "Client wrappers"

  cat > "$BIN_DIR/claude-local" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f ".env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source ".env"
  set +a
fi

exec claude "$@"
EOF
  chmod +x "$BIN_DIR/claude-local"

  cat > "$BIN_DIR/qwen-stack-status" <<EOF
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
EOF
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
  cat > "$STATUS_JSON" <<EOF
{
  "status": "ready",
  "app": "$APP_NAME",
  "model_alias": "$MODEL_ALIAS",
  "host_ip": "$DETECTED_HOST_IP",
  "litellm_base_url": "$DETECTED_LITELLM_BASE",
  "ollama_base_url": "$DETECTED_OLLAMA_BASE",
  "project_env_path": "$PROJECT_ENV_PATH",
  "log_file": "$LOG_FILE",
  "elapsed_seconds": $elapsed,
  "updated_at": "$(date -Iseconds)"
}
EOF
}

try_ollama_launch() {
  if [[ "$TRY_OLLAMA_LAUNCH" != "1" ]]; then
    return
  fi

  step "Ollama launcher"
  if command -v ollama >/dev/null 2>&1 && ollama launch --help >/dev/null 2>&1; then
    export OLLAMA_HOST="$DETECTED_OLLAMA_BASE"
    ollama launch claude --model "$MODEL_ALIAS" || true
  else
    log WARN "ollama launch unavailable; using Claude Code env route"
  fi
}

print_env() {
  if [[ -f "$PROJECT_ENV_PATH" ]]; then
    cat "$PROJECT_ENV_PATH"
  elif [[ -f .env ]]; then
    cat .env
  else
    log WARN "No .env found"
  fi
}

print_status() {
  banner
  ascii_topology
  echo "${BOLD}Local tools${RESET}"
  command -v node >/dev/null 2>&1 && echo "  node:      $(node --version)" || echo "  node:      ${RED}missing${RESET}"
  command -v npm >/dev/null 2>&1 && echo "  npm:       $(npm --version)" || echo "  npm:       ${RED}missing${RESET}"
  command -v claude >/dev/null 2>&1 && echo "  claude:    $(claude --version || true)" || echo "  claude:    ${RED}missing${RESET}"
  echo "  env:       ${PROJECT_ENV_PATH}"
  echo "  log:       ${LOG_FILE}"
  echo

  if [[ -f "$STATUS_JSON" ]]; then
    echo "${BOLD}Last status${RESET}"
    cat "$STATUS_JSON"
    echo
  fi

  if [[ -n "${HOST_IP:-}" ]]; then
    DETECTED_HOST_IP="$HOST_IP"
    DETECTED_LITELLM_BASE="http://$HOST_IP:$LITELLM_PORT"
    DETECTED_OLLAMA_BASE="http://$HOST_IP:$OLLAMA_PORT"
    curl -fsS -H "Authorization: Bearer $LITELLM_KEY" "$DETECTED_LITELLM_BASE/v1/models" >/dev/null 2>&1 && log OK "LiteLLM healthy" || log WARN "LiteLLM unreachable"
  fi
}

doctor() {
  print_status
  echo "${BOLD}Network candidates${RESET}"
  unique_candidates | sed 's/^/  - /'
  echo
  echo "${BOLD}Route${RESET}"
  route -n get default 2>/dev/null || true
  echo
  echo "${BOLD}DNS / network${RESET}"
  ping -c 1 1.1.1.1 >/dev/null 2>&1 && log OK "Internet reachable" || log WARN "Internet ping failed"
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
  log OK "Removed wrappers and status file. Project .env kept."
}

summary() {
  write_status_json
  echo
  echo "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${RESET}"
  echo "${GREEN}${BOLD}║                              MAC CLIENT READY                               ║${RESET}"
  echo "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${RESET}"
  echo
  echo "  Host IP:       $DETECTED_HOST_IP"
  echo "  LiteLLM:       $DETECTED_LITELLM_BASE"
  echo "  Ollama:        $DETECTED_OLLAMA_BASE"
  echo "  Model:         $MODEL_ALIAS"
  echo "  Env file:      $PROJECT_ENV_PATH"
  echo "  Status JSON:   $STATUS_JSON"
  echo "  Log file:      $LOG_FILE"
  echo
  echo "${CYAN}${BOLD}Run:${RESET}"
  echo "  qwen-stack-status"
  echo "  claude-local"
  echo
  echo "${CYAN}${BOLD}Inside Claude Code:${RESET}"
  echo "  /status"
  echo
}

install_client() {
  banner
  ascii_topology
  ensure_path
  install_homebrew_if_needed
  install_node
  configure_npm_global
  install_claude_code
  probe_host
  write_project_env
  create_wrappers
  try_ollama_launch
  summary
}

case "${1:-install}" in
  install) install_client ;;
  status) print_status ;;
  env) print_env ;;
  launch) launch_claude ;;
  doctor) doctor ;;
  uninstall) uninstall_client ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
