#!/bin/bash
# Query MiniMax Coding Plan rate limits via OpenCode auth
# Token: ~/.local/share/opencode/auth.json (minimax-coding-plan.key)
# Official docs:
#   - https://platform.minimax.io/docs/coding-plan/intro
#   - https://platform.minimax.io/docs/coding-plan/faq

set -euo pipefail

AUTH_FILE="$HOME/.local/share/opencode/auth.json"
SHOW_JSON=0
SHOW_ALL=0
MODEL_FILTER=""

usage() {
    cat <<'EOF'
Usage: query-minimax.sh [--json] [--all] [--model <pattern>]

Options:
  --json             Print the raw JSON response after the summary
  --all              Include models with zero quota in the detail section
  --model <pattern>  Filter model rows by case-insensitive substring
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            SHOW_JSON=1
            shift
            ;;
        --all)
            SHOW_ALL=1
            shift
            ;;
        --model)
            if [[ $# -lt 2 ]]; then
                echo "Error: --model requires a value" >&2
                exit 1
            fi
            MODEL_FILTER="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Error: Required command not found: $command_name" >&2
        exit 1
    fi
}

format_local_time_ms() {
    local milliseconds="$1"
    if [[ -z "$milliseconds" || "$milliseconds" == "null" || "$milliseconds" -le 0 ]]; then
        echo "unknown"
        return
    fi

    local seconds=$((milliseconds / 1000))
    date -r "$seconds" "+%Y-%m-%d %H:%M:%S %Z"
}

format_duration_ms() {
    local milliseconds="$1"
    if [[ -z "$milliseconds" || "$milliseconds" == "null" || "$milliseconds" -le 0 ]]; then
        echo "now"
        return
    fi

    local total_seconds=$((milliseconds / 1000))
    local days=$((total_seconds / 86400))
    local hours=$(((total_seconds % 86400) / 3600))
    local minutes=$(((total_seconds % 3600) / 60))

    if [[ "$days" -gt 0 ]]; then
        echo "${days}d ${hours}h"
    elif [[ "$hours" -gt 0 ]]; then
        echo "${hours}h"
    else
        echo "${minutes}m"
    fi
}

calculate_percent_used() {
    local used="$1"
    local total="$2"
    if [[ "$total" -le 0 ]]; then
        echo "N/A"
        return
    fi
    echo $((used * 100 / total))
}

calculate_used_from_remaining() {
    local remaining="$1"
    local total="$2"
    if [[ "$total" -le 0 ]]; then
        echo 0
        return
    fi

    if [[ "$remaining" -lt 0 ]]; then
        remaining=0
    elif [[ "$remaining" -gt "$total" ]]; then
        remaining="$total"
    fi

    echo $((total - remaining))
}

calculate_percent_left() {
    local remaining="$1"
    local total="$2"
    if [[ "$total" -le 0 ]]; then
        echo "N/A"
        return
    fi
    echo $((remaining * 100 / total))
}

fetch_minimax_usage() {
    local token="$1"
    local endpoints=(
        "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
        "https://www.minimax.io/v1/api/openplatform/coding_plan/remains"
    )
    local tmp_body
    tmp_body="$(mktemp)"
    trap 'rm -f "$tmp_body"' RETURN

    for endpoint in "${endpoints[@]}"; do
        echo "Debug: Trying MiniMax endpoint: $endpoint" >&2
        local http_code
        http_code=$(curl -sS --location "$endpoint" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -o "$tmp_body" \
            -w "%{http_code}" || true)
        echo "Debug: MiniMax endpoint returned HTTP $http_code" >&2

        if [[ "$http_code" == "200" ]] && jq -e '.base_resp.status_code == 0 and (.model_remains | type == "array")' "$tmp_body" >/dev/null 2>&1; then
            cat "$tmp_body"
            return 0
        fi
    done

    echo "Error: Failed to fetch MiniMax Coding Plan usage from all known endpoints" >&2
    if [[ -s "$tmp_body" ]]; then
        echo "Last response preview:" >&2
        sed -n '1,20p' "$tmp_body" >&2
    fi
    return 1
}

require_command "curl"
require_command "jq"

if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Error: OpenCode auth file not found at $AUTH_FILE" >&2
    exit 1
fi

API_KEY=$(jq -r '.["minimax-coding-plan"].key // empty' "$AUTH_FILE")

if [[ -z "$API_KEY" ]]; then
    echo "Error: No MiniMax Coding Plan API key found in auth file" >&2
    echo "Expected key: minimax-coding-plan.key" >&2
    exit 1
fi

RESPONSE="$(fetch_minimax_usage "$API_KEY")"

FILTERED_ROWS=$(echo "$RESPONSE" | jq -c \
    --arg model_filter "$MODEL_FILTER" \
    --argjson show_all "$SHOW_ALL" '
    [
        .model_remains[]
        | select(
            ($show_all == 1)
            or ((.current_interval_total_count // 0) > 0)
            or ((.current_weekly_total_count // 0) > 0)
        )
        | select(
            ($model_filter | length) == 0
            or ((.model_name // "") | ascii_downcase | contains($model_filter | ascii_downcase))
        )
    ]')

ROW_COUNT=$(echo "$FILTERED_ROWS" | jq 'length')

if [[ "$ROW_COUNT" -eq 0 ]]; then
    echo "Error: No MiniMax rate-limit rows matched the requested filters" >&2
    exit 1
fi

echo "=== MiniMax Coding Plan Usage ==="
echo "Auth Source: $AUTH_FILE"
echo "Rows: $ROW_COUNT"
if [[ -n "$MODEL_FILTER" ]]; then
    echo "Model Filter: $MODEL_FILTER"
fi
echo ""

PRIMARY_ROW=$(echo "$FILTERED_ROWS" | jq '.[0]')
PRIMARY_MODEL=$(echo "$PRIMARY_ROW" | jq -r '.model_name')
PRIMARY_INTERVAL_TOTAL=$(echo "$PRIMARY_ROW" | jq -r '.current_interval_total_count // 0')
PRIMARY_INTERVAL_REMAINING=$(echo "$PRIMARY_ROW" | jq -r '.current_interval_usage_count // 0')
PRIMARY_INTERVAL_REMAINS_MS=$(echo "$PRIMARY_ROW" | jq -r '.remains_time // 0')
PRIMARY_WEEKLY_TOTAL=$(echo "$PRIMARY_ROW" | jq -r '.current_weekly_total_count // 0')
PRIMARY_WEEKLY_REMAINING=$(echo "$PRIMARY_ROW" | jq -r '.current_weekly_usage_count // 0')
PRIMARY_WEEKLY_REMAINS_MS=$(echo "$PRIMARY_ROW" | jq -r '.weekly_remains_time // 0')

PRIMARY_INTERVAL_USED=$(calculate_used_from_remaining "$PRIMARY_INTERVAL_REMAINING" "$PRIMARY_INTERVAL_TOTAL")
PRIMARY_WEEKLY_USED=$(calculate_used_from_remaining "$PRIMARY_WEEKLY_REMAINING" "$PRIMARY_WEEKLY_TOTAL")
PRIMARY_INTERVAL_PERCENT=$(calculate_percent_used "$PRIMARY_INTERVAL_USED" "$PRIMARY_INTERVAL_TOTAL")
PRIMARY_WEEKLY_PERCENT=$(calculate_percent_used "$PRIMARY_WEEKLY_USED" "$PRIMARY_WEEKLY_TOTAL")
PRIMARY_INTERVAL_LEFT_PERCENT=$(calculate_percent_left "$PRIMARY_INTERVAL_REMAINING" "$PRIMARY_INTERVAL_TOTAL")
PRIMARY_WEEKLY_LEFT_PERCENT=$(calculate_percent_left "$PRIMARY_WEEKLY_REMAINING" "$PRIMARY_WEEKLY_TOTAL")

echo "--- Summary ---"
echo "Primary Model: $PRIMARY_MODEL"
if [[ "$PRIMARY_INTERVAL_TOTAL" -gt 0 ]]; then
    echo "5h Window Used: $PRIMARY_INTERVAL_USED/$PRIMARY_INTERVAL_TOTAL (${PRIMARY_INTERVAL_PERCENT}% used)"
    echo "5h Window Left: $PRIMARY_INTERVAL_REMAINING/$PRIMARY_INTERVAL_TOTAL (${PRIMARY_INTERVAL_LEFT_PERCENT}% left)"
    echo "5h Window Reset: $(format_local_time_ms "$(echo "$PRIMARY_ROW" | jq -r '.end_time // 0')") ($(format_duration_ms "$PRIMARY_INTERVAL_REMAINS_MS"))"
fi
if [[ "$PRIMARY_WEEKLY_TOTAL" -gt 0 ]]; then
    echo "Weekly Window Used: $PRIMARY_WEEKLY_USED/$PRIMARY_WEEKLY_TOTAL (${PRIMARY_WEEKLY_PERCENT}% used)"
    echo "Weekly Window Left: $PRIMARY_WEEKLY_REMAINING/$PRIMARY_WEEKLY_TOTAL (${PRIMARY_WEEKLY_LEFT_PERCENT}% left)"
    echo "Weekly Window Reset: $(format_local_time_ms "$(echo "$PRIMARY_ROW" | jq -r '.weekly_end_time // 0')") ($(format_duration_ms "$PRIMARY_WEEKLY_REMAINS_MS"))"
fi
echo ""

echo "--- Detail ---"
echo "$FILTERED_ROWS" | jq -c '.[]' | while IFS= read -r row; do
    model_name=$(echo "$row" | jq -r '.model_name')
    interval_total=$(echo "$row" | jq -r '.current_interval_total_count // 0')
    interval_remaining=$(echo "$row" | jq -r '.current_interval_usage_count // 0')
    interval_start=$(echo "$row" | jq -r '.start_time // 0')
    interval_end=$(echo "$row" | jq -r '.end_time // 0')
    interval_remains_ms=$(echo "$row" | jq -r '.remains_time // 0')
    weekly_total=$(echo "$row" | jq -r '.current_weekly_total_count // 0')
    weekly_remaining=$(echo "$row" | jq -r '.current_weekly_usage_count // 0')
    weekly_start=$(echo "$row" | jq -r '.weekly_start_time // 0')
    weekly_end=$(echo "$row" | jq -r '.weekly_end_time // 0')
    weekly_remains_ms=$(echo "$row" | jq -r '.weekly_remains_time // 0')

    interval_used=$(calculate_used_from_remaining "$interval_remaining" "$interval_total")
    weekly_used=$(calculate_used_from_remaining "$weekly_remaining" "$weekly_total")
    interval_percent=$(calculate_percent_used "$interval_used" "$interval_total")
    weekly_percent=$(calculate_percent_used "$weekly_used" "$weekly_total")
    interval_left_percent=$(calculate_percent_left "$interval_remaining" "$interval_total")
    weekly_left_percent=$(calculate_percent_left "$weekly_remaining" "$weekly_total")

    echo "Model: $model_name"
    if [[ "$interval_total" -gt 0 ]]; then
        echo "  5h Used: $interval_used/$interval_total (${interval_percent}% used)"
        echo "  5h Left: $interval_remaining/$interval_total (${interval_left_percent}% left)"
        echo "  5h Range: $(format_local_time_ms "$interval_start") -> $(format_local_time_ms "$interval_end")"
        echo "  5h Reset In: $(format_duration_ms "$interval_remains_ms")"
    fi
    if [[ "$weekly_total" -gt 0 ]]; then
        echo "  Weekly Used: $weekly_used/$weekly_total (${weekly_percent}% used)"
        echo "  Weekly Left: $weekly_remaining/$weekly_total (${weekly_left_percent}% left)"
        echo "  Weekly Range: $(format_local_time_ms "$weekly_start") -> $(format_local_time_ms "$weekly_end")"
        echo "  Weekly Reset In: $(format_duration_ms "$weekly_remains_ms")"
    fi
    echo ""
done

if [[ "$SHOW_JSON" -eq 1 ]]; then
    echo "--- Raw JSON ---"
    echo "$RESPONSE" | jq .
fi
