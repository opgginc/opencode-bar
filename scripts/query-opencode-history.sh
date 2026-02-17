#!/bin/zsh
# Query OpenCode (Zen) daily usage history
# Calculates daily costs by computing cumulative differences
# Algorithm: Day(N) cost = stats(N) - stats(N-1)
#
# Based on ui-fixes.md specification:
#   Day 7 ($4.38) - Day 6 ($0.19) = Jan 24: $4.19
#   Day 6 ($0.19) - Day 5 ($0.19) = Jan 25: $0.00
#   ...

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

HISTORY_DAYS="${1:-7}"
OUTPUT_FORMAT="${2:-text}"

typeset -A cumulative_costs
typeset -A daily_costs
typeset -A daily_dates

# Parses: │Total Cost          $285.39│
extract_total_cost() {
    local days="$1"
    local output
    output=$("$OPENCODE_BIN" stats --days "$days" --models 0 2>&1)

    local cost
    cost=$(echo "$output" | grep -oE 'Total Cost[^│]*\$[0-9.]+' | grep -oE '\$[0-9.]+' | tr -d '$')

    if [[ -z "$cost" ]]; then
        echo "0.00"
    else
        echo "$cost"
    fi
}

extract_stats() {
    local days="$1"
    local output
    output=$("$OPENCODE_BIN" stats --days "$days" --models 10 2>&1)

    local sessions avg_cost messages

    sessions=$(echo "$output" | grep -oE 'Sessions[^│]*[0-9,]+' | grep -oE '[0-9,]+' | tr -d ',')
    avg_cost=$(echo "$output" | grep -oE 'Avg Cost/Day[^│]*\$[0-9.]+' | grep -oE '\$[0-9.]+' | tr -d '$')
    messages=$(echo "$output" | grep -oE 'Messages[^│]*[0-9,]+' | grep -oE '[0-9,]+' | tr -d ',')

    echo "sessions=$sessions avg_cost=$avg_cost messages=$messages"
}

calculate_daily_history() {
    local max_days="$1"

    echo "=== OpenCode Zen Daily Usage History ===" >&2
    echo "Calculating cumulative costs for days 1-$max_days..." >&2

    for day in {1..$max_days}; do
        cumulative_costs[$day]=$(extract_total_cost "$day")
        echo "  Day $day cumulative: \$${cumulative_costs[$day]}" >&2
    done

    echo "" >&2

    # daily_costs[N] = cumulative[N] - cumulative[N-1]
    for day in {1..$max_days}; do
        if [[ $day -eq 1 ]]; then
            daily_costs[$day]="${cumulative_costs[1]}"
        else
            local prev_cost="${cumulative_costs[$((day-1))]}"
            local curr_cost="${cumulative_costs[$day]}"
            daily_costs[$day]=$(echo "$curr_cost - $prev_cost" | bc)
        fi

        daily_dates[$day]=$(date -v-$((day-1))d "+%Y-%m-%d")
    done

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        output_json "$max_days"
    else
        output_text "$max_days"
    fi
}

output_text() {
    local max_days="$1"

    echo ""
    echo "=== Daily Cost Breakdown ==="
    echo ""
    printf "%-12s  %10s\n" "Date" "Cost"
    echo "------------------------"

    local total=0
    for day in {1..$max_days}; do
        printf "%-12s  %10s\n" "${daily_dates[$day]}" "\$${daily_costs[$day]}"
        total=$(echo "$total + ${daily_costs[$day]}" | bc)
    done

    echo "------------------------"
    printf "%-12s  %10s\n" "Total" "\$$total"
}

output_json() {
    local max_days="$1"

    echo "{"
    echo "  \"history\": ["

    for day in {1..$max_days}; do
        local comma=","
        if [[ $day -eq $max_days ]]; then
            comma=""
        fi
        echo "    {\"date\": \"${daily_dates[$day]}\", \"cost\": ${daily_costs[$day]}}$comma"
    done

    echo "  ]"
    echo "}"
}

echo "OpenCode Zen Usage History Calculator"
echo "======================================"
echo ""

echo "=== Summary (Last $HISTORY_DAYS Days) ==="
stats=$(extract_stats "$HISTORY_DAYS")
total_cost=$(extract_total_cost "$HISTORY_DAYS")

echo "Total Cost: \$$total_cost"
echo "$stats" | tr ' ' '\n' | while read -r line; do
    key=$(echo "$line" | cut -d= -f1)
    val=$(echo "$line" | cut -d= -f2)
    case "$key" in
        sessions) echo "Sessions: $val" ;;
        avg_cost) echo "Avg Cost/Day: \$$val" ;;
        messages) echo "Messages: $val" ;;
    esac
done

echo ""

calculate_daily_history "$HISTORY_DAYS"
