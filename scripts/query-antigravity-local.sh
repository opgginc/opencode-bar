#!/bin/bash
# Backward-compatible alias for local Antigravity server query.
# Use query-antigravity-server.sh directly for server-only behavior.
# Use query-antigravity-reversed.sh for cache/proto reverse parsing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/query-antigravity-server.sh" "$@"
