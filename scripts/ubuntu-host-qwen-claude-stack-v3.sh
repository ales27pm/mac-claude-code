#!/usr/bin/env bash
# shellcheck shell=bash
#
# Ubuntu host merged entrypoint v3.0.
#
# This keeps the battle-tested v2.1 body as the base and applies the v3 hardening
# fixes before execution:
#   - model_exists strips Ollama :tag suffixes before comparing aliases
#   - health_json escapes JSON string fields
#   - the active terminal banner is rendered as a stencil-wall topology
#   - v2.2 runtime patch wrapper is no longer the public route

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/ubuntu-host-qwen-claude-stack-v2.1.sh"
MERGED_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/ubuntu-host-qwen-claude-stack-v3.XXXXXX.sh")"

cleanup() {
  rm -f "$MERGED_SCRIPT"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "Missing source script: $SOURCE_SCRIPT" >&2
  exit 1
fi

python3 - "$SOURCE_SCRIPT" "$MERGED_SCRIPT" <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
merged_path = pathlib.Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")

text = text.replace("# Version: 2.1", "# Version: 3.0 (merged from v2, v2.1, v2.2)", 1)
text = text.replace("hardened v2.1", "v3.0", 1)

write_env_marker = "write_env_var() { printf '%s=%s\\n' \"$1\" \"$(shell_quote \"$2\")\"; }\n"
json_helper = """
json_str() {
  printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'
}
"""
if "json_str()" not in text:
    if write_env_marker not in text:
        raise SystemExit("Could not find write_env_var marker for json_str insertion")
    text = text.replace(write_env_marker, write_env_marker + json_helper, 1)

old_model_exists = "model_exists() { ollama list 2>/dev/null | awk '{print $1}' | grep -Fxq \"$MODEL_ALIAS\"; }"
new_model_exists = """model_exists() {
  ollama list 2>/dev/null |
    awk '{print $1}' |
    cut -d: -f1 |
    grep -Fxq "$MODEL_ALIAS"
}"""
if old_model_exists in text:
    text = text.replace(old_model_exists, new_model_exists, 1)
elif "cut -d: -f1" not in text:
    raise SystemExit("Could not patch model_exists")

stencil_banner = r'''banner() {
  clear || true
  cat <<'ART'
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                                                      ┃
┃  ███╗   ███╗ █████╗  ██████╗      ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗  ┃
┃  ████╗ ████║██╔══██╗██╔════╝     ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝  ┃
┃  ██╔████╔██║███████║██║          ██║     ██║     ███████║██║   ██║██║  ██║█████╗    ┃
┃  ██║╚██╔╝██║██╔══██║██║          ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝    ┃
┃  ██║ ╚═╝ ██║██║  ██║╚██████╗     ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗  ┃
┃  ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝      ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝  ┃
┃                                                                                      ┃
┃       STENCIL WALL HOST STACK · Ubuntu muscle for a lightweight macOS VM             ┃
┃       No API rent · no cloud priest · no token tax · just local silicon              ┃
┃                                                                                      ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

        .-''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''-.
       /  WALL #11434 + #4000                                                 \
      /  "THE CLOUD WAS JUST SOMEONE ELSE'S COMPUTER WITH BETTER MARKETING"    \
     /__________________________________________________________________________\
     |                                                                          |
     |   ┌─────────────────────────────┐      ┌─────────────────────────────┐   |
     |   │ SYSTEM SCAN                 │      │ macOS PRECONFIG EXPORT      │   |
     |   │ CPU / RAM / SWAP            │      │ host-connection.env         │   |
     |   │ GPU / VRAM / CUDA           │      │ macos-host-preconfig.env    │   |
     |   │ LAN IP / GATEWAY / IFACE    │      │ install-on-macos-vm.sh      │   |
     |   │ SYSTEMD / UFW / PORTS       │      └──────────────┬──────────────┘   |
     |   └──────────────┬──────────────┘                     │                  |
     |                  │                                    │                  |
     |                  ▼                                    │                  |
     |   ┌─────────────────────────────┐                     │                  |
     |   │ AUTO TUNER                  │                     │                  |
     |   │ q5_k_m  ≥ 11 GB VRAM        │                     │                  |
     |   │ q4_k_m  ≥  7 GB VRAM        │                     │                  |
     |   │ iq4_xs  ≥  5 GB VRAM        │                     │                  |
     |   │ q3_k_m  fallback            │                     │                  |
     |   └──────────────┬──────────────┘                     │                  |
     |                  │                                    │                  |
     |                  ▼                                    │                  |
     |   ┌─────────────────────────────┐                     │                  |
     |   │ LiteLLM Proxy               │◄────────────────────┘                  |
     |   │ OpenAI-compatible API       │                                        |
     |   │ LAN endpoint :4000          │      ("></")  rat@wall:~$ curl /models |
     |   │ master key protected        │       / > spray                         |
     |   └──────────────┬──────────────┘                                        |
     |                  │                                                       |
     |                  ▼                                                       |
     |   ┌─────────────────────────────┐      ┌─────────────────────────────┐   |
     |   │ Ollama Runtime              │      │ PROCESS / SAFETY LAYER      │   |
     |   │ qwen-coder-ablit            │      │ PID files                   │   |
     |   │ Qwen2.5 Coder 7B            │      │ INT / TERM cleanup          │   |
     |   │ abliterated GGUF            │      │ systemd-user or nohup       │   |
     |   │ LAN endpoint :11434         │      │ UFW optional rules          │   |
     |   └──────────────┬──────────────┘      └─────────────────────────────┘   |
     |                  │                                                       |
     |                  ▼                                                       |
     |   ┌─────────────────────────────┐                                        |
     |   │ NVIDIA / CUDA ACCELERATION  │   local inference, no rented oracle    |
     |   └─────────────────────────────┘                                        |
     |__________________________________________________________________________|
ART
}
'''
text, banner_count = re.subn(r"banner\(\) \{.*?\n\}\n\nusage\(\) \{", stencil_banner + "\nusage() {", text, count=1, flags=re.S)
if banner_count != 1:
    raise SystemExit("Could not patch banner")

new_health_json = r'''health_json() {
  local status="$1" elapsed="$(( $(date +%s) - START_TS ))"
  [[ -z "$HOST_PRIMARY_IP" ]] && HOST_PRIMARY_IP="$(primary_ip)"
  cat > "$STATUS_JSON" <<STATUSEOF
{
  "status": "$(json_str "$status")",
  "app": "$(json_str "$APP_NAME")",
  "model_alias": "$(json_str "$MODEL_ALIAS")",
  "model_source": "$(json_str "$MODEL_SOURCE")",
  "num_ctx": $NUM_CTX,
  "gpu_name": "$(json_str "$GPU_NAME")",
  "gpu_vram_mb": "$(json_str "$GPU_VRAM_MB")",
  "ram_gb": "$(json_str "$RAM_GB")",
  "host_ip": "$(json_str "$HOST_PRIMARY_IP")",
  "ollama_port": $OLLAMA_PORT,
  "litellm_port": $LITELLM_PORT,
  "litellm_base_url": "http://$(json_str "$HOST_PRIMARY_IP"):$LITELLM_PORT",
  "ollama_base_url": "http://$(json_str "$HOST_PRIMARY_IP"):$OLLAMA_PORT",
  "scan_env": "$(json_str "$SCAN_ENV")",
  "host_export": "$(json_str "$HOST_EXPORT")",
  "log_file": "$(json_str "$LOG_FILE")",
  "elapsed_seconds": $elapsed,
  "updated_at": "$(date -Iseconds)"
}
STATUSEOF
}
'''
text, count = re.subn(r"health_json\(\) \{.*?\n\}\n\nprobe\(\) \{", new_health_json + "\nprobe() {", text, count=1, flags=re.S)
if count != 1:
    raise SystemExit("Could not patch health_json")

merged_path.write_text(text, encoding="utf-8")
PY

chmod +x "$MERGED_SCRIPT"
exec "$MERGED_SCRIPT" "$@"
