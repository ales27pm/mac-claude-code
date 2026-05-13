#!/usr/bin/env bash
# shellcheck shell=bash
#
# Verify that the local Ollama Anthropic-compatible endpoint returns real
# Anthropic content blocks, including tool_use, instead of plain JSON text.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="${APP_NAME:-mac-claude-code}"
HOST_CONFIG_PATH="${HOST_CONFIG_PATH:-}"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"
MODEL_ALIAS="${MODEL_ALIAS:-}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-}"
MAX_TOKENS="${MAX_TOKENS:-512}"

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

if config_file="$(find_host_config)"; then
  # shellcheck disable=SC1090
  set -a; source "$config_file"; set +a
  log OK "Loaded host config: $config_file"
else
  log WARN "No host config found; using environment values"
fi

HOST_IP="${HOST_IP:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen-coder-ablit}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-${OLLAMA_BASE_URL:-http://$HOST_IP:$OLLAMA_PORT}}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL%/}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL%/v1/messages}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL%/v1}"

payload="$(python3 - "$MODEL_ALIAS" "$MAX_TOKENS" <<'PY'
from __future__ import annotations

import json
import sys

model = sys.argv[1]
max_tokens = int(sys.argv[2])
print(json.dumps({
    "model": model,
    "max_tokens": max_tokens,
    "tools": [
        {
            "name": "get_repository_summary",
            "description": "Return a short summary for a repository path.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Repository-relative path to inspect."
                    }
                },
                "required": ["path"]
            }
        }
    ],
    "messages": [
        {
            "role": "user",
            "content": "Use the get_repository_summary tool for README.md. Do not answer directly."
        }
    ],
}))
PY
)"

response_file="$(mktemp "${TMPDIR:-/tmp}/ollama-anthropic-tool-test.XXXXXX.json")"
trap 'rm -f "$response_file"' EXIT

log INFO "POST $OLLAMA_HOST_URL/v1/messages"
log INFO "model=$MODEL_ALIAS"

http_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
  "$OLLAMA_HOST_URL/v1/messages" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ollama' \
  -d "$payload")"

cat "$response_file"
echo

if [[ "$http_code" != "200" ]]; then
  log ERR "HTTP $http_code from Ollama Anthropic endpoint"
  exit 1
fi

python3 - "$response_file" <<'PY'
from __future__ import annotations

import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

content = data.get("content")
if not isinstance(content, list):
    raise SystemExit("FAIL: response.content is not a list")

types = [block.get("type") for block in content if isinstance(block, dict)]
if "tool_use" not in types:
    print("FAIL: no Anthropic tool_use block returned")
    print(f"content block types: {types}")
    raise SystemExit(2)

usage = data.get("usage", {})
if not isinstance(usage, dict) or "input_tokens" not in usage:
    print("WARN: response missing usage.input_tokens; streaming parsers may be fragile")
else:
    print(f"OK: usage.input_tokens={usage.get('input_tokens')} output_tokens={usage.get('output_tokens')}")

print("OK: tool_use block detected")
PY

log OK "Ollama Anthropic tool-use path is functional"
