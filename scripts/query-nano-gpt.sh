#!/bin/bash

set -e

AUTH_FILE="$HOME/.local/share/opencode/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Error: OpenCode auth file not found at $AUTH_FILE"
    exit 1
fi

API_KEY=$(jq -r '.["nano-gpt"].key // empty' "$AUTH_FILE")

if [[ -z "$API_KEY" ]]; then
    echo "Error: No Nano-GPT API key found in auth file (nano-gpt.key)"
    exit 1
fi

echo "=== Nano-GPT Usage ==="
echo ""

USAGE_RESPONSE=$(curl -sS "https://nano-gpt.com/api/subscription/v1/usage" \
    -H "Authorization: Bearer $API_KEY" \
    -H "x-api-key: $API_KEY" \
    -H "Accept: application/json")

if echo "$USAGE_RESPONSE" | jq -e '.error != null' > /dev/null 2>&1; then
    echo "Error: $(echo "$USAGE_RESPONSE" | jq -r '.error.message // .error // "unknown error"')"
    exit 1
fi

PRIMARY_LABEL="Monthly quota"
PRIMARY_LIMIT=$(echo "$USAGE_RESPONSE" | jq -r '.limits.monthly // empty')
PRIMARY_USED=$(echo "$USAGE_RESPONSE" | jq -r '.monthly.used // 0')
PRIMARY_REMAINING=$(echo "$USAGE_RESPONSE" | jq -r '.monthly.remaining // empty')
PRIMARY_PERCENT=$(echo "$USAGE_RESPONSE" | jq -r '.monthly.percentUsed // empty')

if [[ -z "$PRIMARY_LIMIT" ]]; then
    PRIMARY_LABEL="Weekly input tokens"
    PRIMARY_LIMIT=$(echo "$USAGE_RESPONSE" | jq -r '.limits.weeklyInputTokens // empty')
    PRIMARY_USED=$(echo "$USAGE_RESPONSE" | jq -r '.weeklyInputTokens.used // 0')
    PRIMARY_REMAINING=$(echo "$USAGE_RESPONSE" | jq -r '.weeklyInputTokens.remaining // empty')
    PRIMARY_PERCENT=$(echo "$USAGE_RESPONSE" | jq -r '.weeklyInputTokens.percentUsed // empty')
fi

DAILY_LIMIT=$(echo "$USAGE_RESPONSE" | jq -r '.limits.daily // .limits.dailyInputTokens // empty')
DAILY_USED=$(echo "$USAGE_RESPONSE" | jq -r '.daily.used // .dailyInputTokens.used // empty')
DAILY_REMAINING=$(echo "$USAGE_RESPONSE" | jq -r '.daily.remaining // .dailyInputTokens.remaining // empty')
DAILY_PERCENT=$(echo "$USAGE_RESPONSE" | jq -r '.daily.percentUsed // .dailyInputTokens.percentUsed // empty')

if [[ -z "$PRIMARY_LIMIT" || "$PRIMARY_LIMIT" -le 0 ]]; then
    echo "Error: Missing Nano-GPT primary quota limit"
    echo "$USAGE_RESPONSE" | jq
    exit 1
fi

if [[ -z "$PRIMARY_REMAINING" ]]; then
    PRIMARY_REMAINING=$((PRIMARY_LIMIT - PRIMARY_USED))
fi

if [[ -z "$PRIMARY_PERCENT" ]]; then
    PRIMARY_PERCENT=$(awk -v u="$PRIMARY_USED" -v l="$PRIMARY_LIMIT" 'BEGIN { printf "%.2f", (u / l) * 100 }')
elif awk -v p="$PRIMARY_PERCENT" 'BEGIN { exit !(p <= 1.0) }'; then
    PRIMARY_PERCENT=$(awk -v p="$PRIMARY_PERCENT" 'BEGIN { printf "%.2f", p * 100 }')
else
    PRIMARY_PERCENT=$(awk -v p="$PRIMARY_PERCENT" 'BEGIN { printf "%.2f", p }')
fi

if [[ -n "$DAILY_PERCENT" ]]; then
    if awk -v p="$DAILY_PERCENT" 'BEGIN { exit !(p <= 1.0) }'; then
        DAILY_PERCENT=$(awk -v p="$DAILY_PERCENT" 'BEGIN { printf "%.2f", p * 100 }')
    else
        DAILY_PERCENT=$(awk -v p="$DAILY_PERCENT" 'BEGIN { printf "%.2f", p }')
    fi
fi

BALANCE_RESPONSE=$(curl -sS -X POST "https://nano-gpt.com/api/check-balance" \
    -H "x-api-key: $API_KEY" \
    -H "Accept: application/json")

USD_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r '.usd_balance // empty')
NANO_BALANCE=$(echo "$BALANCE_RESPONSE" | jq -r '.nano_balance // empty')
CURRENT_PERIOD_END=$(echo "$USAGE_RESPONSE" | jq -r '.period.currentPeriodEnd // empty')

echo "--- $PRIMARY_LABEL ---"
echo "Limit: $PRIMARY_LIMIT"
echo "Used: $PRIMARY_USED"
echo "Remaining: $PRIMARY_REMAINING"
echo "Used %: $PRIMARY_PERCENT"

if [[ -n "$DAILY_LIMIT" || -n "$DAILY_USED" || -n "$DAILY_REMAINING" || -n "$DAILY_PERCENT" ]]; then
    echo ""
    echo "--- Daily quota ---"
    echo "Limit: ${DAILY_LIMIT:-unknown}"
    echo "Used: ${DAILY_USED:-unknown}"
    echo "Remaining: ${DAILY_REMAINING:-unknown}"
    echo "Used %: ${DAILY_PERCENT:-unknown}"
fi

echo ""
echo "--- Balance ---"
echo "USD Balance: ${USD_BALANCE:-unknown}"
echo "NANO Balance: ${NANO_BALANCE:-unknown}"

if [[ -n "$CURRENT_PERIOD_END" ]]; then
    echo ""
    echo "Current period end: $CURRENT_PERIOD_END"
fi

echo ""
echo "--- Raw usage response ---"
echo "$USAGE_RESPONSE" | jq
