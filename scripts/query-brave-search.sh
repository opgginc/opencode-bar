#!/bin/bash

set -e

CONFIG_PATHS=(
    "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
    "$HOME/.config/opencode/opencode.json"
    "$HOME/.local/share/opencode/opencode.json"
    "$HOME/Library/Application Support/opencode/opencode.json"
)

resolve_config_value() {
    local value="$1"

    if [[ -z "$value" || "$value" == "null" ]]; then
        printf '%s' ""
        return
    fi

    if [[ "$value" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local var_name="${BASH_REMATCH[1]}"
        printf '%s' "${!var_name}"
        return
    fi

    if [[ "$value" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        local var_name="${BASH_REMATCH[1]}"
        printf '%s' "${!var_name}"
        return
    fi

    printf '%s' "$value"
}

CONFIG_FILE=""
for path in "${CONFIG_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
        CONFIG_FILE="$path"
        break
    fi
done

if [[ -z "$CONFIG_FILE" ]]; then
    echo "Error: OpenCode config file not found"
    exit 1
fi

RAW_ENV_KEY=$(jq -r '.mcp["brave-search"].environment.BRAVE_API_KEY // empty' "$CONFIG_FILE")
RAW_HEADER_KEY=$(jq -r '.mcp["brave-search"].headers["X-Subscription-Token"] // empty' "$CONFIG_FILE")

API_KEY=$(resolve_config_value "$RAW_ENV_KEY")
if [[ -z "$API_KEY" ]]; then
    API_KEY=$(resolve_config_value "$RAW_HEADER_KEY")
fi

if [[ -z "$API_KEY" ]]; then
    echo "Error: Brave Search API key not found in $CONFIG_FILE"
    echo "Expected one of:"
    echo "  - .mcp[\"brave-search\"].environment.BRAVE_API_KEY"
    echo "  - .mcp[\"brave-search\"].headers[\"X-Subscription-Token\"]"
    exit 1
fi

echo "=== Brave Search Usage ==="
echo "Config: $CONFIG_FILE"
echo ""

HEADERS=$(curl -sS -D - -o /dev/null "https://api.search.brave.com/res/v1/web/search?q=opencode&count=1" \
    -H "X-Subscription-Token: $API_KEY" \
    -H "Accept: application/json")

LIMIT_CSV=$(printf '%s\n' "$HEADERS" | awk -F': ' 'tolower($1)=="x-ratelimit-limit" {gsub("\r", "", $2); print $2}' | tail -n 1)
REMAINING_CSV=$(printf '%s\n' "$HEADERS" | awk -F': ' 'tolower($1)=="x-ratelimit-remaining" {gsub("\r", "", $2); print $2}' | tail -n 1)
RESET_CSV=$(printf '%s\n' "$HEADERS" | awk -F': ' 'tolower($1)=="x-ratelimit-reset" {gsub("\r", "", $2); print $2}' | tail -n 1)
POLICY=$(printf '%s\n' "$HEADERS" | awk -F': ' 'tolower($1)=="x-ratelimit-policy" {gsub("\r", "", $2); print $2}' | tail -n 1)

if [[ -z "$LIMIT_CSV" || -z "$REMAINING_CSV" ]]; then
    echo "Error: Rate-limit headers not found. Check API key validity."
    echo ""
    printf '%s\n' "$HEADERS"
    exit 1
fi

IFS=',' read -r -a LIMITS <<< "$LIMIT_CSV"
IFS=',' read -r -a REMAININGS <<< "$REMAINING_CSV"
IFS=',' read -r -a RESETS <<< "$RESET_CSV"

LAST_INDEX=$((${#LIMITS[@]} - 1))
LIMIT="${LIMITS[$LAST_INDEX]}"
REMAINING="${REMAININGS[$LAST_INDEX]}"
RESET_SECONDS="${RESETS[$LAST_INDEX]}"

LIMIT="${LIMIT//[[:space:]]/}"
REMAINING="${REMAINING//[[:space:]]/}"
RESET_SECONDS="${RESET_SECONDS//[[:space:]]/}"

if [[ -z "$LIMIT" || -z "$REMAINING" ]]; then
    echo "Error: Could not resolve monthly quota from Brave headers"
    exit 1
fi

USED=$((LIMIT - REMAINING))
if [[ "$USED" -lt 0 ]]; then
    USED=0
fi

PERCENT="0.00"
if [[ "$LIMIT" -gt 0 ]]; then
    PERCENT=$(awk -v u="$USED" -v l="$LIMIT" 'BEGIN { printf "%.2f", (u / l) * 100 }')
fi

echo "Raw policy windows: ${POLICY:-unknown}"
echo ""
echo "--- Monthly quota (selected) ---"
echo "Limit: $LIMIT"
echo "Used: $USED"
echo "Remaining: $REMAINING"
echo "Used %: $PERCENT"
echo "Reset (seconds): ${RESET_SECONDS:-unknown}"
