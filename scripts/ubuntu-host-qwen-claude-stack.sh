#!/usr/bin/env bash
# Compatibility entrypoint.
# The hardened Ubuntu host implementation lives in:
#   scripts/ubuntu-host-qwen-claude-stack-v2.2.sh

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ubuntu-host-qwen-claude-stack-v2.2.sh" "$@"
