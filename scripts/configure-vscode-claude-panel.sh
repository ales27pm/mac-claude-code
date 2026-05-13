#!/usr/bin/env bash
# shellcheck shell=bash
#
# Configure the Claude Code VS Code panel to use the local LiteLLM/Ollama route.
# This writes:
#   - ~/.claude/settings.json for Claude Code env shared by CLI and extension
#   - .vscode/settings.json for VS Code panel behavior
#
# Important for local/non-first-party ANTHROPIC_BASE_URL:
#   ENABLE_TOOL_SEARCH=false forces Claude Code to load tools upfront instead of
#   relying on deferred tool_reference discovery blocks that most proxies/local
#   models do not handle correctly.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${APP_NAME:-mac-claude-code}"
HOST_CONFIG_PATH="${HOST_CONFIG_PATH:-}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"
CLAUDE_SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"
VSCODE_SETTINGS_PATH="${VSCODE_SETTINGS_PATH:-$WORKSPACE_DIR/.vscode/settings.json}"
ENABLE_TOOL_SEARCH_VALUE="${ENABLE_TOOL_SEARCH_VALUE:-false}"
MAX_MCP_OUTPUT_TOKENS="${MAX_MCP_OUTPUT_TOKENS:-50000}"

log() { printf '[%s] %s\n' "$1" "$2"; }

find_host_config() {
  local candidates=()
  [[ -n "$HOST_CONFIG_PATH" ]] && candidates+=("$HOST_CONFIG_PATH")
  candidates+=("$WORKSPACE_DIR/macos-host-preconfig.env")
  candidates+=("$WORKSPACE_DIR/host-connection.env")
  candidates+=("$HOME/.config/$APP_NAME/host-connection.env")
  candidates+=("$HOME/Library/Application Support/$APP_NAME/host-connection.env")

  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] && {
      printf '%s\n' "$candidate"
      return 0
    }
  done
  return 1
}

CONFIG_FILE="$(find_host_config)" || {
  echo "Could not find macos-host-preconfig.env or host-connection.env." >&2
  echo "Run the macOS installer first, or pass HOST_CONFIG_PATH=/path/to/macos-host-preconfig.env." >&2
  exit 1
}

# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

HOST_IP="${HOST_IP:-}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_KEY="${LITELLM_KEY:-local-dev-key}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-http://$HOST_IP:$LITELLM_PORT}"

mkdir -p "$(dirname "$CLAUDE_SETTINGS_PATH")" "$(dirname "$VSCODE_SETTINGS_PATH")"

python3 - "$CLAUDE_SETTINGS_PATH" "$VSCODE_SETTINGS_PATH" "$LITELLM_KEY" "$LITELLM_BASE_URL" "$MODEL_ALIAS" "$ENABLE_TOOL_SEARCH_VALUE" "$MAX_MCP_OUTPUT_TOKENS" <<'PY'
from __future__ import annotations

import json
import pathlib
import sys
from typing import Any

claude_path = pathlib.Path(sys.argv[1]).expanduser()
vscode_path = pathlib.Path(sys.argv[2]).expanduser()
api_key = sys.argv[3]
base_url = sys.argv[4]
model = sys.argv[5]
enable_tool_search = sys.argv[6]
max_mcp_output_tokens = sys.argv[7]


def load_json(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        backup = path.with_suffix(path.suffix + ".bak")
        backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        raise SystemExit(f"Invalid JSON in {path}; backup written to {backup}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"Expected JSON object in {path}")
    return data

claude = load_json(claude_path)
claude_env = claude.get("env")
if not isinstance(claude_env, dict):
    claude_env = {}
claude_env.update(
    {
        "ANTHROPIC_API_KEY": api_key,
        "ANTHROPIC_AUTH_TOKEN": api_key,
        "ANTHROPIC_BASE_URL": base_url,
        "ANTHROPIC_MODEL": model,
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
        "ENABLE_TOOL_SEARCH": enable_tool_search,
        "MAX_MCP_OUTPUT_TOKENS": max_mcp_output_tokens,
        "API_TIMEOUT_MS": "600000",
    }
)
claude["env"] = claude_env
claude_path.write_text(json.dumps(claude, indent=2, sort_keys=True) + "\n", encoding="utf-8")
claude_path.chmod(0o600)

vscode = load_json(vscode_path)
vscode.update(
    {
        "claudeCode.disableLoginPrompt": True,
        "claudeCode.useTerminal": False,
        "claudeCode.preferredLocation": "panel",
    }
)
vscode_path.write_text(json.dumps(vscode, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

log OK "Loaded host config: $CONFIG_FILE"
log OK "Wrote Claude settings: $CLAUDE_SETTINGS_PATH"
log OK "Wrote VS Code settings: $VSCODE_SETTINGS_PATH"
log OK "ENABLE_TOOL_SEARCH=$ENABLE_TOOL_SEARCH_VALUE"
log OK "MAX_MCP_OUTPUT_TOKENS=$MAX_MCP_OUTPUT_TOKENS"
log INFO "Reload VS Code: Cmd+Shift+P → Developer: Reload Window"
log INFO "Then open the Claude panel. It should use: $LITELLM_BASE_URL model=$MODEL_ALIAS"

if command -v open >/dev/null 2>&1; then
  open "vscode://anthropic.claude-code/open" >/dev/null 2>&1 || true
fi
