#!/bin/bash
# Query Codex (OpenAI/ChatGPT) usage via Codex CLI native auth
# Token: ~/.codex/auth.json

set -e

AUTH_FILE="$HOME/.codex/auth.json"

if [[ ! -f "$AUTH_FILE" ]]; then
    echo "Error: Codex CLI auth file not found at $AUTH_FILE"
    exit 1
fi

ACCESS=$(jq -r '.tokens.access_token // empty' "$AUTH_FILE")
ACCOUNT_ID=$(jq -r '.tokens.account_id // empty' "$AUTH_FILE")

if [[ -z "$ACCESS" ]]; then
    echo "Error: No access token found in $AUTH_FILE"
    exit 1
fi

echo "=== Codex (OpenAI) Usage ==="
echo ""

# Decode JWT to extract user info (email, plan, etc.)
decode_jwt_payload() {
    local token="$1"
    local payload=$(echo "$token" | cut -d'.' -f2)
    local mod=$((${#payload} % 4))
    if [ $mod -eq 2 ]; then
        payload="${payload}=="
    elif [ $mod -eq 3 ]; then
        payload="${payload}="
    fi
    echo "$payload" | base64 -d 2>/dev/null
}

JWT_PAYLOAD=$(decode_jwt_payload "$ACCESS")
if [[ -n "$JWT_PAYLOAD" ]]; then
    echo "=== Account Info (from JWT) ==="
    echo "$JWT_PAYLOAD" | jq '{
        "email": ."https://api.openai.com/profile".email,
        "email_verified": ."https://api.openai.com/profile".email_verified,
        "plan_type": ."https://api.openai.com/auth".chatgpt_plan_type,
        "user_id": ."https://api.openai.com/auth".chatgpt_user_id,
        "mfa_required": ."https://api.openai.com/mfa".required,
        "token_expires_at": (.exp | todate),
        "token_issued_at": (.iat | todate)
    }'
    echo ""
fi

HEADERS=(-H "Authorization: Bearer $ACCESS")
if [[ -n "$ACCOUNT_ID" ]]; then
    HEADERS+=(-H "ChatGPT-Account-Id: $ACCOUNT_ID")
fi

RESPONSE=$(curl -s "https://chatgpt.com/backend-api/wham/usage" "${HEADERS[@]}")

if echo "$RESPONSE" | jq -e '.detail' > /dev/null 2>&1; then
    echo "Error: $(echo "$RESPONSE" | jq -r '.detail')"
    exit 1
fi

echo "=== Usage Stats ==="
echo "$RESPONSE" | jq '
{
    "plan": .plan_type,
    "primary_used": (.rate_limit.primary_window.used_percent | tostring + "%"),
    "primary_reset_seconds": .rate_limit.primary_window.reset_after_seconds,
    "secondary_used": (.rate_limit.secondary_window.used_percent | tostring + "%"),
    "secondary_reset_seconds": .rate_limit.secondary_window.reset_after_seconds,
    "credits_balance": .credits.balance,
    "credits_unlimited": .credits.unlimited
}'
