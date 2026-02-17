#!/bin/bash
# Query OpenCode (Zen) usage statistics
# Uses: opencode stats command
# Data source: Local session data

set -e

# Find opencode binary using multiple strategies (matches Swift app approach)
find_opencode_bin() {
    # Strategy 1: Try "which opencode" in current PATH
    if command -v opencode &> /dev/null; then
        local path
        path=$(command -v opencode)
        echo "Found opencode via PATH: $path" >&2
        echo "$path"
        return 0
    fi

    # Strategy 2: Try via login shell to get user's full PATH
    local shell="${SHELL:-/bin/zsh}"
    local login_path
    login_path=$("$shell" -lc 'which opencode 2>/dev/null' 2>/dev/null)
    if [[ -n "$login_path" && -x "$login_path" ]]; then
        echo "Found opencode via login shell PATH: $login_path" >&2
        echo "$login_path"
        return 0
    fi

    # Strategy 3: Fallback to common installation paths
    local fallback_paths=(
        "/opt/homebrew/bin/opencode"      # Apple Silicon Homebrew
        "/usr/local/bin/opencode"          # Intel Homebrew
        "$HOME/.opencode/bin/opencode"     # OpenCode default
        "$HOME/.local/bin/opencode"        # pip/pipx
        "/usr/bin/opencode"                # System-wide
    )

    for path in "${fallback_paths[@]}"; do
        if [[ -x "$path" ]]; then
            echo "Found opencode via fallback path: $path" >&2
            echo "$path"
            return 0
        fi
    done

    return 1
}

OPENCODE_BIN=$(find_opencode_bin)
if [[ -z "$OPENCODE_BIN" ]]; then
    echo "Error: OpenCode CLI not found. Please ensure 'opencode' is in your PATH." >&2
    echo "Searched: PATH, login shell PATH, and common installation locations." >&2
    exit 1
fi

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
