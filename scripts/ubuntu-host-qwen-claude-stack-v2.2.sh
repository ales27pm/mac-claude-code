#!/usr/bin/env bash
# shellcheck shell=bash
#
# Ubuntu host hardened entrypoint v2.2.
#
# This wrapper preserves the full v2.1 implementation while applying the
# model_exists fix at runtime. Ollama lists models as name:tag, so wrapper
# model aliases such as qwen-coder-ablit must be compared after stripping tags.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/ubuntu-host-qwen-claude-stack-v2.1.sh"
PATCHED_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/ubuntu-host-qwen-claude-stack-v2.2.XXXXXX.sh")"

cleanup() {
  rm -f "$PATCHED_SCRIPT"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
  echo "Missing source script: $SOURCE_SCRIPT" >&2
  exit 1
fi

OLD_MODEL_EXISTS='model_exists() { ollama list 2>/dev/null | awk '\''{print $1}'\'' | grep -Fxq "$MODEL_ALIAS"; }'
NEW_MODEL_EXISTS='model_exists() { ollama list 2>/dev/null | awk '\''{print $1}'\'' | cut -d: -f1 | grep -Fxq "$MODEL_ALIAS"; }'

if ! awk -v old="$OLD_MODEL_EXISTS" -v new="$NEW_MODEL_EXISTS" '
  $0 == old { print new; patched = 1; next }
  $0 == new { patched = 1 }
  { print }
  END { if (!patched) exit 42 }
' "$SOURCE_SCRIPT" > "$PATCHED_SCRIPT"; then
  echo "Could not patch or verify model_exists implementation in: $SOURCE_SCRIPT" >&2
  exit 1
fi

chmod +x "$PATCHED_SCRIPT"
exec "$PATCHED_SCRIPT" "$@"
