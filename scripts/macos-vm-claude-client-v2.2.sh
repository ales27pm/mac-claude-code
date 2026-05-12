#!/usr/bin/env bash
# shellcheck shell=bash
#
# Hardened macOS VM client entrypoint v2.2.
#
# This keeps the stable v2 implementation as the base and normalizes it as the
# v2.2 public route. The v2 base already contains the v2.2 hardening fixes:
#   - doctor avoids double live endpoint probing
#   - status JSON escapes backslashes and double-quotes
#   - optional Ollama launcher uses `ollama run`
#   - generated wrappers fail hard on broken .env sourcing
#   - active terminal banner is rendered as a stencil-wall client topology
#
# v2.2 wrapper fixes:
#   - BSD/macOS mktemp compatibility: template ends with XXXXXX, no suffix
#   - profiles_to_update always returns 0 when profiles exist, avoiding ERR trap
#     pollution inside process substitution during PATH setup
#   - claude-local injects npm/Homebrew/global binary paths before exec so a
#     newly installed Claude Code CLI is found without opening a new shell
#   - Claude Code VS Code extension can be installed/configured for the local
#     LiteLLM route using disableLoginPrompt + claudeProcessWrapper

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/macos-vm-claude-client-v2.sh"
PATCHED_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/macos-vm-claude-client-v2.2.XXXXXX")"

cleanup() {
  rm -f "$PATCHED_SCRIPT"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "Missing source script: $SOURCE_SCRIPT" >&2
  exit 1
fi

python3 - "$SOURCE_SCRIPT" "$PATCHED_SCRIPT" <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
patched_path = pathlib.Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")
text = text.replace("# Version: 2.1", "# Version: 2.2", 1)

text = text.replace(
    'SKIP_PROBE="${SKIP_PROBE:-0}"',
    'SKIP_PROBE="${SKIP_PROBE:-0}"\n'
    'ENABLE_VSCODE_EXTENSION="${ENABLE_VSCODE_EXTENSION:-1}"\n'
    'INSTALL_VSCODE_EXTENSION="${INSTALL_VSCODE_EXTENSION:-1}"\n'
    'VSCODE_CLAUDE_EXTENSION_ID="${VSCODE_CLAUDE_EXTENSION_ID:-anthropic.claude-code}"',
    1,
)

stencil_banner = r'''banner() {
  clear || true
  cat <<'ART'
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃                                                                                      ┃
┃       ███╗   ███╗ █████╗  ██████╗     ██╗   ██╗███╗   ███╗                         ┃
┃       ████╗ ████║██╔══██╗██╔════╝     ██║   ██║████╗ ████║                         ┃
┃       ██╔████╔██║███████║██║          ██║   ██║██╔████╔██║                         ┃
┃       ██║╚██╔╝██║██╔══██║██║          ╚██╗ ██╔╝██║╚██╔╝██║                         ┃
┃       ██║ ╚═╝ ██║██║  ██║╚██████╗      ╚████╔╝ ██║ ╚═╝ ██║                         ┃
┃       ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝       ╚═══╝  ╚═╝     ╚═╝                         ┃
┃                                                                                      ┃
┃       STENCIL WALL CLIENT · Claude Code inside the VM, muscle outside the VM          ┃
┃       thin client · dirty wall · clean endpoint · local model                         ┃
┃                                                                                      ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

        .-''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''''-.
       /  WALL #VM                                                            |
      /  "THE LOGIN SCREEN WANTED A CLOUD. THE RAT FOUND A BASE_URL."           |
     /__________________________________________________________________________|
     |                                                                          |
     |   ┌─────────────────────────────┐                                        |
     |   │ macOS VM                    │      (">")  rat@vm:~$ claude-local     |
     |   │ VS Code                     │       / > spray                        |
     |   │ Claude Code CLI             │                                        |
     |   │ VS Code extension           │                                        |
     |   │ project .env                │                                        |
     |   └──────────────┬──────────────┘                                        |
     |                  │                                                       |
     |                  │  ANTHROPIC_API_KEY                                    |
     |                  │  ANTHROPIC_BASE_URL                                   |
     |                  │  ANTHROPIC_MODEL                                      |
     |                  ▼                                                       |
     |   ┌─────────────────────────────┐      ┌─────────────────────────────┐   |
     |   │ Host Preconfig Import       │      │ Client Toolchain            │   |
     |   │ host-connection.env         │      │ Homebrew / Node / npm       │   |
     |   │ macos-host-preconfig.env    │      │ Claude Code CLI / Extension │   |
     |   │ persisted config            │      │ qwen-stack-status           │   |
     |   └──────────────┬──────────────┘      └─────────────────────────────┘   |
     |                  │                                                       |
     |                  ▼                                                       |
     |   ┌─────────────────────────────┐                                        |
     |   │ Ubuntu Host LiteLLM         │   :4000 OpenAI-compatible API          |
     |   └──────────────┬──────────────┘                                        |
     |                  │                                                       |
     |                  ▼                                                       |
     |   ┌─────────────────────────────┐                                        |
     |   │ Ubuntu Host Ollama          │   :11434 qwen-coder-ablit              |
     |   └─────────────────────────────┘                                        |
     |__________________________________________________________________________|
ART
}
'''
text, count = re.subn(r"banner\(\) \{.*?\n\}\n\nusage\(\) \{", stencil_banner + "\nusage() {", text, count=1, flags=re.S)
if count != 1:
    raise SystemExit("Could not patch banner")

# The v2 base has a classic set -e footgun: when at least one shell profile
# exists, the final [[ "$any" == "0" ]] expression returns 1. Because
# ensure_profile_line consumes profiles_to_update through process substitution,
# the ERR trap text can be captured as fake profile paths. Force return 0.
old_profiles_tail = '''  [[ "$any" == "0" ]] && {
    touch "$HOME/.zshrc"
    echo "$HOME/.zshrc"
  }
}'''
new_profiles_tail = '''  if [[ "$any" == "0" ]]; then
    touch "$HOME/.zshrc"
    echo "$HOME/.zshrc"
  fi
  return 0
}'''
if old_profiles_tail in text:
    text = text.replace(old_profiles_tail, new_profiles_tail, 1)
elif "profiles_to_update()" in text and "return 0" not in text[text.index("profiles_to_update()"):text.index("ensure_profile_line()")]:
    raise SystemExit("Could not patch profiles_to_update")

old_claude_local = '''cat > "$BIN_DIR/claude-local" <<'CLAUDELOCAL'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -f ".env" ]]; then
  set -a
  if ! source ".env"; then
    echo "Error: failed to source .env" >&2
    exit 1
  fi
  set +a
fi
exec claude "$@"
CLAUDELOCAL'''
new_claude_local = '''cat > "$BIN_DIR/claude-local" <<'CLAUDELOCAL'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
unset ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

if [[ -f ".env" ]]; then
  set -a
  if ! source ".env"; then
    echo "Error: failed to source .env" >&2
    exit 1
  fi
  set +a
fi

unset ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
CLAUDE_BIN="$(command -v claude || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "Error: claude not found." >&2
  echo "Expected Claude Code in ~/.npm-global/bin, /opt/homebrew/bin, /usr/local/bin, or PATH." >&2
  echo "Try: export PATH=\"$HOME/.npm-global/bin:$HOME/.local/bin:$PATH\"" >&2
  exit 127
fi

exec "$CLAUDE_BIN" "$@"
CLAUDELOCAL
  chmod +x "$BIN_DIR/claude-local"

  cat > "$BIN_DIR/claude-vscode-local" <<'CLAUDEVSCODE'
#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
unset ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

if [[ -f ".env" ]]; then
  set -a
  if ! source ".env"; then
    echo "Error: failed to source workspace .env" >&2
    exit 1
  fi
  set +a
fi

if [[ -f "$HOME/.config/mac-claude-code/host-connection.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$HOME/.config/mac-claude-code/host-connection.env" || true
  set +a
fi

unset ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

if [[ $# -gt 0 && -x "$1" ]]; then
  CLAUDE_BIN="$1"
  shift
else
  CLAUDE_BIN="$(command -v claude || true)"
fi

if [[ -z "${CLAUDE_BIN:-}" ]]; then
  echo "Error: claude binary not found for VS Code extension wrapper." >&2
  exit 127
fi

exec "$CLAUDE_BIN" "$@"
CLAUDEVSCODE'''
if old_claude_local in text:
    text = text.replace(old_claude_local, new_claude_local, 1)
elif "CLAUDE_BIN=" not in text or "claude-vscode-local" not in text:
    raise SystemExit("Could not patch Claude wrappers")

vscode_function = r'''
configure_vscode_claude_extension() {
  step "VS Code Claude extension"

  if [[ "$ENABLE_VSCODE_EXTENSION" != "1" ]]; then
    log WARN "Skipping VS Code extension configuration"
    return 0
  fi

  local code_bin=""
  if command_exists code; then
    code_bin="$(command -v code)"
  elif [[ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]]; then
    code_bin="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  fi

  if [[ -n "$code_bin" && "$INSTALL_VSCODE_EXTENSION" == "1" ]]; then
    local extension_log
    extension_log="$(mktemp "${TMPDIR:-/tmp}/claude-code-extension-install.XXXXXX")"
    if "$code_bin" --install-extension "$VSCODE_CLAUDE_EXTENSION_ID" --force >"$extension_log" 2>&1; then
      log OK "VS Code extension installed: $VSCODE_CLAUDE_EXTENSION_ID"
    else
      log WARN "VS Code extension install did not complete cleanly. Continuing with settings and terminal wrapper. Log: $extension_log"
      cat "$extension_log" || true
    fi
  elif [[ -z "$code_bin" ]]; then
    log WARN "VS Code CLI 'code' not found. Settings will still be written; install the extension from VS Code if needed."
  fi

  mkdir -p "$HOME/Library/Application Support/Code/User" "$(pwd)/.vscode"

  python3 - "$HOME/Library/Application Support/Code/User/settings.json" "$(pwd)/.vscode/settings.json" "$BIN_DIR/claude-vscode-local" <<'PYSETTINGS'
from __future__ import annotations

import json
import pathlib
import sys

user_settings = pathlib.Path(sys.argv[1])
workspace_settings = pathlib.Path(sys.argv[2])
wrapper = sys.argv[3]

base = {
    "claudeCode.disableLoginPrompt": True,
    "claudeCode.useTerminal": False,
    "claudeCode.usePythonEnvironment": False,
    "claudeCode.claudeProcessWrapper": wrapper,
}
workspace_extra = {
    "python.terminal.useEnvFile": True,
    "python.envFile": "${workspaceFolder}/.env",
    "terminal.integrated.env.osx": {
        "PATH": "${env:HOME}/.npm-global/bin:${env:HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${env:PATH}",
        "ANTHROPIC_AUTH_TOKEN": None,
        "CLAUDE_CODE_OAUTH_TOKEN": None,
    },
}

def load(path: pathlib.Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        backup = path.with_suffix(path.suffix + ".bak")
        backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        return {}

def merge(path: pathlib.Path, updates: dict) -> None:
    data = load(path)
    for key, value in updates.items():
        if isinstance(value, dict) and isinstance(data.get(key), dict):
            data[key].update(value)
        else:
            data[key] = value
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")

merge(user_settings, base)
merge(workspace_settings, {**base, **workspace_extra})
print(user_settings)
print(workspace_settings)
PYSETTINGS

  log OK "VS Code Claude settings configured"
  log INFO "claudeCode.disableLoginPrompt=true"
  log INFO "claudeCode.claudeProcessWrapper=$BIN_DIR/claude-vscode-local"

  if [[ -n "$code_bin" ]]; then
    "$code_bin" --reuse-window "$(pwd)" >/dev/null 2>&1 || true
  fi
}
'''
marker = "\nwrite_status_json() {\n"
if marker in text and "configure_vscode_claude_extension()" not in text:
    text = text.replace(marker, "\n" + vscode_function + marker, 1)
elif "configure_vscode_claude_extension()" not in text:
    raise SystemExit("Could not insert VS Code extension configurator")

old_install_tail = '''  write_project_env
  create_wrappers
  try_ollama_launch
  summary'''
new_install_tail = '''  write_project_env
  create_wrappers
  configure_vscode_claude_extension
  try_ollama_launch
  summary'''
if old_install_tail in text:
    text = text.replace(old_install_tail, new_install_tail, 1)
elif "configure_vscode_claude_extension" not in re.search(r"install_client\(\) \{.*?\n\}", text, re.S).group(0):
    raise SystemExit("Could not wire VS Code extension configurator into install_client")

old_summary_run = '''  echo "  qwen-stack-status"
  echo "  claude-local"'''
new_summary_run = '''  echo "  qwen-stack-status"
  echo "  claude-local"
  echo "  code ."
  echo "  Cmd+Shift+P → Claude Code: Open in New Tab"'''
if old_summary_run in text:
    text = text.replace(old_summary_run, new_summary_run, 1)

patched_path.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED_SCRIPT"
exec "$PATCHED_SCRIPT" "$@"
