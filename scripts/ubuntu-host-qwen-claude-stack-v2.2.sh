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

python3 - "$SOURCE_SCRIPT" "$PATCHED_SCRIPT" <<'PY'
from __future__ import annotations

import pathlib
import sys

source_path = pathlib.Path(sys.argv[1])
patched_path = pathlib.Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")
old = "model_exists() { ollama list 2>/dev/null | awk '{print $1}' | grep -Fxq \"$MODEL_ALIAS\"; }"
new = "model_exists() { ollama list 2>/dev/null | awk '{print $1}' | cut -d: -f1 | grep -Fxq \"$MODEL_ALIAS\"; }"
if old not in text:
    # Keep this wrapper forward-compatible if v2.1 is already patched later.
    new_variant = new
    if new_variant not in text:
        raise SystemExit("Could not find expected model_exists implementation to patch")
else:
    text = text.replace(old, new, 1)
patched_path.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED_SCRIPT"
exec "$PATCHED_SCRIPT" "$@"
