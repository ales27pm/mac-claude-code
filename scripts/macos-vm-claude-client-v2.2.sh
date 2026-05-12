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
     |   │ project .env                │                                        |
     |   │ claude-local wrapper        │                                        |
     |   └──────────────┬──────────────┘                                        |
     |                  │                                                       |
     |                  │  ANTHROPIC_API_KEY                                    |
     |                  │  ANTHROPIC_BASE_URL                                   |
     |                  │  ANTHROPIC_MODEL                                      |
     |                  ▼                                                       |
     |   ┌─────────────────────────────┐      ┌─────────────────────────────┐   |
     |   │ Host Preconfig Import       │      │ Client Toolchain            │   |
     |   │ host-connection.env         │      │ Homebrew / Node / npm       │   |
     |   │ macos-host-preconfig.env    │      │ Claude Code CLI             │   |
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

patched_path.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED_SCRIPT"
exec "$PATCHED_SCRIPT" "$@"
