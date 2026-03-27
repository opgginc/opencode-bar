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

csv_value() {
    local input="$1"
    local idx="$2"
    IFS=',' read -r -a arr <<< "$(printf '%s' "$input" | tr -d ' \r')"
    if (( idx >= 0 && idx < ${#arr[@]} )); then
        printf '%s' "${arr[$idx]}"
    fi
}

csv_ints() {
    local input="$1"
    local raw
    IFS=',' read -r -a raw <<< "$(printf '%s' "$input" | tr -d ' \r')"
    local values=()
    local v
    for v in "${raw[@]}"; do
        v="${v%%;*}"
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            values+=("$v")
        fi
    done
    printf '%s' "${values[*]}"
}

policy_windows() {
    local policy="$1"
    IFS=',' read -r -a parts <<< "$(printf '%s' "$policy" | tr -d '\r')"
    local windows=()
    local p
    for p in "${parts[@]}"; do
        if [[ "$p" =~ w=([0-9]+) ]]; then
            windows+=("${BASH_REMATCH[1]}")
        fi
    done
    printf '%s' "${windows[*]}"
}

pick_index() {
    local windows_str="$1"
    local limits_str="$2"
    local remainings_str="$3"

    read -r -a ls <<< "$limits_str"
    read -r -a rs <<< "$remainings_str"
    read -r -a ws <<< "$windows_str"

    if (( ${#ls[@]} > 0 && ${#rs[@]} > 0 )); then
        local max_den=1
        local max_num=-1
        local best_idx=0
        local best_w=0
        local i=0

        for i in "${!ls[@]}"; do
            if (( i < ${#rs[@]} )); then
                local limit="${ls[$i]}"
                local remaining="${rs[$i]}"
                if (( limit <= 0 )); then
                    continue
                fi
                local used=$((limit - remaining))
                if (( used < 0 )); then
                    used=0
                fi
                local current_w=0
                if (( i < ${#ws[@]} )); then
                    current_w="${ws[$i]}"
                fi

                if (( used * max_den > max_num * limit )); then
                    max_num="$used"
                    max_den="$limit"
                    best_idx="$i"
                    best_w="$current_w"
                elif (( used * max_den == max_num * limit )); then
                    if (( best_w == 0 || (current_w > 0 && current_w < best_w) )); then
                        best_idx="$i"
                        best_w="$current_w"
                    fi
                fi
            fi
        done

        printf '%s' "$best_idx"
        return
    fi

    local count=${#ls[@]}
    if (( ${#rs[@]} > count )); then
        count=${#rs[@]}
    fi
    if (( count > 0 )); then
        printf '%s' $((count - 1))
    else
        printf '%s' 0
    fi
}

normalize_reset_to_delta() {
    local reset_value="$1"
    local now
    now=$(date +%s)

    if [[ ! "$reset_value" =~ ^[0-9]+$ ]]; then
        printf '%s' ""
        return
    fi

    if (( reset_value >= 1000000000 )); then
        local delta=$((reset_value - now))
        if (( delta < 0 )); then
            delta=0
        fi
        printf '%s' "$delta"
    else
        printf '%s' "$reset_value"
    fi
}

format_duration() {
    local sec="$1"
    if (( sec <= 0 )); then
        printf '%s' "now"
        return
    fi
    local days=$((sec / 86400))
    local hours=$(((sec % 86400) / 3600))
    local mins=$(((sec % 3600) / 60))
    if (( days > 0 )); then
        printf '%s' "${days}d ${hours}h ${mins}m"
    elif (( hours > 0 )); then
        printf '%s' "${hours}h ${mins}m"
    else
        printf '%s' "${mins}m"
    fi
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

headers_file="$(mktemp)"
body_file="$(mktemp)"
trap 'rm -f "$headers_file" "$body_file"' EXIT

HTTP_CODE=$(curl -sS -o "$body_file" -D "$headers_file" -w "%{http_code}" \
    "https://api.search.brave.com/res/v1/web/search?q=opencode&count=1" \
    -H "X-Subscription-Token: $API_KEY" \
    -H "Accept: application/json")

LIMIT_HEADER=$(grep -i '^X-RateLimit-Limit:' "$headers_file" | tail -1 | cut -d: -f2-)
REMAINING_HEADER=$(grep -i '^X-RateLimit-Remaining:' "$headers_file" | tail -1 | cut -d: -f2-)
RESET_HEADER=$(grep -i '^X-RateLimit-Reset:' "$headers_file" | tail -1 | cut -d: -f2-)
POLICY_HEADER=$(grep -i '^X-RateLimit-Policy:' "$headers_file" | tail -1 | cut -d: -f2-)

LIMITS_STR="$(csv_ints "$LIMIT_HEADER")"
REMAININGS_STR="$(csv_ints "$REMAINING_HEADER")"
WINDOWS_STR="$(policy_windows "$POLICY_HEADER")"

IDX="$(pick_index "$WINDOWS_STR" "$LIMITS_STR" "$REMAININGS_STR")"
LIMIT="$(csv_value "$LIMIT_HEADER" "$IDX" | tr -d ' \r' | cut -d';' -f1)"
REMAINING="$(csv_value "$REMAINING_HEADER" "$IDX" | tr -d ' \r' | cut -d';' -f1)"
RESET_VALUE="$(csv_value "$RESET_HEADER" "$IDX" | tr -d ' \r' | cut -d';' -f1)"
WINDOW_SECONDS="$(csv_value "$POLICY_HEADER" "$IDX" | grep -o 'w=[0-9]*' | cut -d= -f2)"
RESET_SECONDS="$(normalize_reset_to_delta "$RESET_VALUE")"

HAS_RATE_HEADERS=false
if [[ "$LIMIT" =~ ^[0-9]+$ && "$REMAINING" =~ ^[0-9]+$ ]]; then
    HAS_RATE_HEADERS=true
fi

if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    echo "Error: Invalid Brave Search API key (HTTP $HTTP_CODE)"
    exit 1
fi

if [[ "$HTTP_CODE" == "422" ]]; then
    if grep -q 'SUBSCRIPTION_TOKEN_INVALID' "$body_file"; then
        echo "Error: Invalid Brave Search API key (HTTP $HTTP_CODE)"
    else
        echo "Error: HTTP $HTTP_CODE"
        cat "$body_file"
    fi
    exit 1
fi

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
    if [[ "$HAS_RATE_HEADERS" == true ]]; then
        USED=$((LIMIT - REMAINING))
        if (( USED < 0 )); then
            USED=0
        fi
        echo "===[ Rate Limit Information ]==="
        echo ""
        echo "Selected window idx:  $IDX"
        echo "API Limit:            $LIMIT"
        echo "API Remaining:        $REMAINING"
        echo "API Used:             $USED"
        if [[ "$RESET_SECONDS" =~ ^[0-9]+$ ]]; then
            RESET_AT=$(( $(date +%s) + RESET_SECONDS ))
            RESET_DATE=$(date -r "$RESET_AT" 2>/dev/null || echo "$RESET_AT")
            echo "Resets at:            $RESET_DATE"
            echo "Time until reset:     $(format_duration "$RESET_SECONDS")"
        fi
        echo ""
    fi
    echo "Error: HTTP $HTTP_CODE"
    cat "$body_file"
    exit 1
fi

if [[ ! "$LIMIT" =~ ^[0-9]+$ || ! "$REMAINING" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not parse Brave Search rate-limit headers"
    echo ""
    cat "$headers_file"
    exit 1
fi

USED=$((LIMIT - REMAINING))
if (( USED < 0 )); then
    USED=0
fi

echo "===[ Rate Limit Information ]==="
echo ""
echo "Selected window idx:  $IDX"
echo "API Limit:            $LIMIT"
echo "API Remaining:        $REMAINING"
echo "API Used:             $USED"
if (( LIMIT > 0 )); then
    USED_PCT=$(awk -v u="$USED" -v l="$LIMIT" 'BEGIN { printf "%.2f", (u / l) * 100 }')
    REMAINING_PCT=$(awk -v r="$REMAINING" -v l="$LIMIT" 'BEGIN { printf "%.2f", (r / l) * 100 }')
    echo "Used %:               ${USED_PCT}%"
    echo "Remaining %:          ${REMAINING_PCT}%"
else
    echo "Used %:               unlimited"
    echo "Remaining %:          unlimited"
fi
echo ""

if [[ "$RESET_SECONDS" =~ ^[0-9]+$ ]]; then
    RESET_AT=$(( $(date +%s) + RESET_SECONDS ))
    RESET_DATE=$(date -r "$RESET_AT" 2>/dev/null || echo "$RESET_AT")
    echo "Resets at:            $RESET_DATE"
    echo "Time until reset:     $(format_duration "$RESET_SECONDS")"
    echo ""
fi

if [[ "$WINDOW_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Rate limit window:    $WINDOW_SECONDS seconds"
    echo ""
fi

echo "===[ Summary ]==="
echo ""
if (( LIMIT > 0 )); then
    printf "Window Usage         %s / %s (%.1f%%)\n" "$USED" "$LIMIT" "$USED_PCT"
    printf "Remaining            %s (%.1f%%)\n" "$REMAINING" "$REMAINING_PCT"
else
    printf "Window Usage         %s / %s\n" "$USED" "$LIMIT"
    printf "Remaining            %s\n" "$REMAINING"
fi
echo ""

if [[ "$1" == "--json" ]]; then
    echo "===[ Raw Response Body ]==="
    echo ""
    cat "$body_file" | jq . 2>/dev/null || cat "$body_file"
    echo ""
    echo "===[ Raw Response Headers ]==="
    echo ""
    cat "$headers_file"
fi
