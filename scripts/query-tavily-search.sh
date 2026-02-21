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

    if [[ "$value" =~ ^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local var_name="${BASH_REMATCH[1]}"
        value="${!var_name}"
    elif [[ "$value" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local var_name="${BASH_REMATCH[1]}"
        value="${!var_name}"
    elif [[ "$value" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
        local var_name="${BASH_REMATCH[1]}"
        value="${!var_name}"
    fi

    value="${value#Bearer }"
    printf '%s' "$value"
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
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
    API_KEY=$(resolve_config_value "$RAW_AUTH_HEADER")
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

HTTP_PAYLOAD=$(curl -sS -w $'\n%{http_code}' "https://api.tavily.com/usage" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Accept: application/json")
HTTP_CODE="${HTTP_PAYLOAD##*$'\n'}"
RESPONSE="${HTTP_PAYLOAD%$'\n'*}"

if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    echo "Error: Invalid Tavily API key (HTTP $HTTP_CODE)"
    exit 1
fi

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
    echo "Error: HTTP $HTTP_CODE"
    echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
    exit 1
fi

if echo "$RESPONSE" | jq -e '.error != null' >/dev/null 2>&1; then
    echo "Error: $(echo "$RESPONSE" | jq -r '.error.message // .error // "unknown error"')"
    exit 1
fi

PLAN_USAGE=$(echo "$RESPONSE" | jq -r '.account.plan_usage // null')
PLAN_LIMIT=$(echo "$RESPONSE" | jq -r '.account.plan_limit // null')
PAYGO_USAGE=$(echo "$RESPONSE" | jq -r '.account.paygo_usage // null')
PAYGO_LIMIT=$(echo "$RESPONSE" | jq -r '.account.paygo_limit // null')
KEY_USAGE=$(echo "$RESPONSE" | jq -r '.key.usage // null')
KEY_LIMIT=$(echo "$RESPONSE" | jq -r '.key.limit // null')

if [[ "$PLAN_USAGE" != "null" && "$PLAN_LIMIT" != "null" ]]; then
    USAGE="$PLAN_USAGE"
    LIMIT="$PLAN_LIMIT"
    SOURCE="account.plan"
elif [[ "$PLAN_USAGE" != "null" && "$PLAN_LIMIT" == "null" ]]; then
    USAGE="$PLAN_USAGE"
    LIMIT="unlimited"
    SOURCE="account.plan"
elif [[ "$PAYGO_USAGE" != "null" && "$PAYGO_LIMIT" != "null" ]]; then
    USAGE="$PAYGO_USAGE"
    LIMIT="$PAYGO_LIMIT"
    SOURCE="account.paygo"
elif [[ "$PAYGO_USAGE" != "null" && "$PAYGO_LIMIT" == "null" ]]; then
    USAGE="$PAYGO_USAGE"
    LIMIT="unlimited"
    SOURCE="account.paygo"
elif [[ "$KEY_USAGE" != "null" && "$KEY_LIMIT" != "null" ]]; then
    USAGE="$KEY_USAGE"
    LIMIT="$KEY_LIMIT"
    SOURCE="key"
elif [[ "$KEY_USAGE" != "null" && "$KEY_LIMIT" == "null" ]]; then
    USAGE="$KEY_USAGE"
    LIMIT="unlimited"
    SOURCE="key"
else
    echo "Error: No usage data found in Tavily response"
    echo "$RESPONSE" | jq .
    exit 1
fi

if ! is_number "$USAGE"; then
    echo "Error: Non-numeric Tavily usage fields"
    echo "$RESPONSE" | jq .
    exit 1
fi

if [[ "$LIMIT" != "unlimited" ]] && ! is_number "$LIMIT"; then
    echo "Error: Non-numeric Tavily usage fields"
    echo "$RESPONSE" | jq .
    exit 1
fi

if [[ "$LIMIT" != "unlimited" ]]; then
    REMAINING=$(awk -v l="$LIMIT" -v u="$USAGE" 'BEGIN { r=l-u; if (r < 0) r=0; printf "%.2f", r }')
fi

CURRENT_PLAN=$(echo "$RESPONSE" | jq -r '.account.current_plan // "Unknown"')

echo "===[ Usage Information ]==="
echo ""
echo "Source:              $SOURCE"
echo "Current Plan:        $CURRENT_PLAN"
echo "Usage:               $USAGE"
echo "Limit:               $LIMIT"
if [[ "$LIMIT" == "unlimited" ]]; then
    echo "Remaining:           unlimited"
else
    echo "Remaining:           $REMAINING"
fi

if [[ "$LIMIT" == "unlimited" ]]; then
    echo "Used %:              unlimited"
    echo "Remaining %:         unlimited"
elif awk -v l="$LIMIT" 'BEGIN { exit !(l > 0) }'; then
    USED_PCT=$(awk -v u="$USAGE" -v l="$LIMIT" 'BEGIN { printf "%.2f", (u / l) * 100 }')
    REMAINING_PCT=$(awk -v u="$USAGE" -v l="$LIMIT" 'BEGIN { r=l-u; if (r < 0) r=0; printf "%.2f", (r / l) * 100 }')
    echo "Used %:              ${USED_PCT}%"
    echo "Remaining %:         ${REMAINING_PCT}%"
else
    echo "Used %:              unlimited"
    echo "Remaining %:         unlimited"
fi
echo ""

if [[ "$PAYGO_USAGE" != "null" || "$PAYGO_LIMIT" != "null" ]]; then
    echo "===[ Pay-as-you-go ]==="
    echo ""
    echo "paygo_usage:         ${PAYGO_USAGE}"
    echo "paygo_limit:         ${PAYGO_LIMIT}"
    echo ""
fi

if [[ "$1" == "--json" ]]; then
    echo "===[ Raw JSON Response ]==="
    echo ""
    echo "$RESPONSE" | jq .
fi
