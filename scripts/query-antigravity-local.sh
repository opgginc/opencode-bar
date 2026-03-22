#!/bin/bash
# Local Antigravity usage query.
# This now uses cache/proto reverse parsing (no localhost server dependency).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/query-antigravity-reversed.sh" "$@"
