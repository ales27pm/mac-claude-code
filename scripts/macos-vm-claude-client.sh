#!/usr/bin/env bash
# Compatibility entrypoint. The hardened implementation lives in:
#   scripts/macos-vm-claude-client-v2.2.sh
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/macos-vm-claude-client-v2.2.sh" "$@"
