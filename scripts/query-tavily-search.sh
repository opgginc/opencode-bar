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

extract_bearer_token() {
    local value="$1"
    if [[ "$value" =~ ^[Bb]earer[[:space:]]+(.+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
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

RAW_ENV_KEY=$(jq -r '.mcp.tavily.environment.TAVILY_API_KEY // empty' "$CONFIG_FILE")
RAW_AUTH_HEADER=$(jq -r '.mcp.tavily.headers.Authorization // empty' "$CONFIG_FILE")
RAW_X_API_KEY=$(jq -r '.mcp.tavily.headers["X-API-Key"] // empty' "$CONFIG_FILE")

API_KEY=$(resolve_config_value "$RAW_ENV_KEY")

if [[ -z "$API_KEY" ]]; then
    AUTH_VALUE=$(resolve_config_value "$RAW_AUTH_HEADER")
    API_KEY=$(extract_bearer_token "$AUTH_VALUE")
fi

if [[ -z "$API_KEY" ]]; then
    API_KEY=$(resolve_config_value "$RAW_X_API_KEY")
fi

if [[ -z "$API_KEY" ]]; then
    echo "Error: Tavily API key not found in $CONFIG_FILE"
    echo "Expected one of:"
    echo "  - .mcp.tavily.environment.TAVILY_API_KEY"
    echo "  - .mcp.tavily.headers.Authorization"
    echo "  - .mcp.tavily.headers[\"X-API-Key\"]"
    exit 1
fi

echo "=== Tavily Usage ==="
echo "Config: $CONFIG_FILE"
echo ""

RESPONSE=$(curl -sS "https://api.tavily.com/usage" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Accept: application/json")

if echo "$RESPONSE" | jq -e '.error != null' > /dev/null 2>&1; then
    echo "Error: $(echo "$RESPONSE" | jq -r '.error.message // .error // "unknown error"')"
    exit 1
fi

PLAN=$(echo "$RESPONSE" | jq -r '.account.current_plan // "unknown"')
USED=$(echo "$RESPONSE" | jq -r '.account.plan_usage // .key.usage // empty')
LIMIT=$(echo "$RESPONSE" | jq -r '.account.plan_limit // .key.limit // empty')

if [[ -z "$USED" || -z "$LIMIT" || "$LIMIT" -le 0 ]]; then
    echo "Error: Could not extract Tavily usage data"
    echo "$RESPONSE" | jq
    exit 1
fi

REMAINING=$((LIMIT - USED))
if [[ "$REMAINING" -lt 0 ]]; then
    REMAINING=0
fi

PERCENT=$(awk -v u="$USED" -v l="$LIMIT" 'BEGIN { printf "%.2f", (u / l) * 100 }')

echo "Plan: $PLAN"
echo ""
echo "--- Monthly quota ---"
echo "Limit: $LIMIT"
echo "Used: $USED"
echo "Remaining: $REMAINING"
echo "Used %: $PERCENT"

echo ""
echo "--- Raw response ---"
echo "$RESPONSE" | jq
