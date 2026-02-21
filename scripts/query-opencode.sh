#!/bin/bash
# Query OpenCode (Zen) usage statistics
# Uses: opencode stats command
# Data source: Local session data

set -e

find_opencode_bin() {
    local bin_path

    bin_path=$(command -v opencode 2>/dev/null || true)
    if [[ -n "$bin_path" && -x "$bin_path" ]]; then
        echo "$bin_path"
        return 0
    fi

    bin_path=$(zsh -lic 'command -v opencode 2>/dev/null' 2>/dev/null || true)
    if [[ -n "$bin_path" && -x "$bin_path" ]]; then
        echo "$bin_path"
        return 0
    fi

    for candidate in \
        "$HOME/.opencode/bin/opencode" \
        "/opt/homebrew/bin/opencode" \
        "/usr/local/bin/opencode" \
        "$HOME/.local/bin/opencode"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

OPENCODE_BIN="$(find_opencode_bin || true)"

if [[ -z "$OPENCODE_BIN" ]]; then
    echo "Error: OpenCode CLI not found in PATH or common locations"
    exit 1
fi

echo "Using OpenCode binary: $OPENCODE_BIN"

# Default to last 30 days
DAYS="${1:-30}"

echo "=== OpenCode Usage (Last $DAYS Days) ==="
echo ""

# Run opencode stats with models breakdown
"$OPENCODE_BIN" stats --days "$DAYS" --models 10 --tools 10 2>&1

# Also show per-project breakdown if requested
if [[ "$2" == "--projects" ]]; then
    echo ""
    echo "=== Per-Project Breakdown ==="
    
    # Get list of recent projects from sessions
    SESSIONS_DIR="$HOME/.local/share/opencode/sessions"
    if [[ -d "$SESSIONS_DIR" ]]; then
        # Find unique project paths from recent sessions
        find "$SESSIONS_DIR" -name "*.json" -mtime -"$DAYS" -exec jq -r '.cwd // empty' {} \; 2>/dev/null | \
            sort | uniq -c | sort -rn | head -10
    fi
fi
