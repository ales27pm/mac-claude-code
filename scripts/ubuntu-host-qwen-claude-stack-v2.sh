#!/usr/bin/env bash
# Compatibility entrypoint for the superseded v2 name.
# The active Ubuntu host implementation route is:
#   scripts/ubuntu-host-qwen-claude-stack-v2.1.sh

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ubuntu-host-qwen-claude-stack-v2.1.sh" "$@"
