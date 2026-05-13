#!/usr/bin/env bash
# shellcheck shell=bash
#
# macOS VM client hardened entrypoint v2.2.
#
# This wrapper preserves the canonical v2 implementation while patching shell
# profile handling at runtime. The v2 profile discovery function could return a
# non-zero status when profiles already existed. With set -E, that could trigger
# the ERR trap inside process substitution and cause recovery text to be treated
# as profile filenames.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/macos-vm-claude-client-v2.sh"
PATCHED_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/macos-vm-claude-client-v2.2.XXXXXX.sh")"

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
import sys

source_path = pathlib.Path(sys.argv[1])
patched_path = pathlib.Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")

old = '''profiles_to_update() {
  local profiles=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile")
  local any="0" profile
  for profile in "${profiles[@]}"; do
    [[ -f "$profile" ]] && {
      echo "$profile"
      any="1"
    }
  done
  [[ "$any" == "0" ]] && {
    touch "$HOME/.zshrc"
    echo "$HOME/.zshrc"
  }
}

ensure_profile_line() {
  local marker="$1" line="$2" profile
  while IFS= read -r profile; do
    if ! grep -qF "$marker" "$profile" 2>/dev/null; then
      { echo ""; echo "# $APP_NAME"; echo "$line"; } >> "$profile"
    fi
  done < <(profiles_to_update)
}
'''

new = '''profiles_to_update() {
  local profiles=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile")
  local found="0" profile

  for profile in "${profiles[@]}"; do
    if [[ -f "$profile" ]]; then
      printf '%s\\n' "$profile"
      found="1"
    fi
  done

  if [[ "$found" == "0" ]]; then
    mkdir -p "$HOME"
    touch "$HOME/.zshrc"
    printf '%s\\n' "$HOME/.zshrc"
  fi

  return 0
}

ensure_profile_line() {
  local marker="$1" line="$2" profile
  local profiles=()

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    case "$profile" in
      "$HOME"/.*) profiles+=("$profile") ;;
      *) log WARN "Skipping unexpected shell profile path: $profile" ;;
    esac
  done < <(profiles_to_update 2>/dev/null || true)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    profile="$HOME/.zshrc"
    mkdir -p "$HOME"
    touch "$profile"
    profiles=("$profile")
  fi

  for profile in "${profiles[@]}"; do
    mkdir -p "$(dirname "$profile")"
    touch "$profile"
    if ! grep -qF "$marker" "$profile" 2>/dev/null; then
      printf '\\n# %s\\n%s\\n' "$APP_NAME" "$line" >> "$profile"
    fi
  done
}
'''

if old not in text:
    raise SystemExit("Could not find expected profile handling block in macos-vm-claude-client-v2.sh")

text = text.replace(old, new, 1)
patched_path.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED_SCRIPT"
exec bash "$PATCHED_SCRIPT" "$@"
