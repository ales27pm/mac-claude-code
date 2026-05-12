#!/usr/bin/env bash
# Compatibility entrypoint.
# The active Ubuntu host implementation lives in:
#   scripts/ubuntu-host-qwen-claude-stack-v3.sh

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/ubuntu-host-qwen-claude-stack-v3.sh" "$@"
