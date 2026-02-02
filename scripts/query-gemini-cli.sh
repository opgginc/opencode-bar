#!/bin/bash
# Query Antigravity (Gemini Cloud Code) usage
# Token: ~/.config/opencode/antigravity-accounts.json
# Antigravity requires token refresh - access tokens expire in 1 hour

set -e

ACCOUNTS_FILE="$HOME/.config/opencode/antigravity-accounts.json"
CLIENT_ID="1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
CLIENT_SECRET="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"

if [[ ! -f "$ACCOUNTS_FILE" ]]; then
    echo "Error: Antigravity accounts file not found at $ACCOUNTS_FILE"
    exit 1
fi

ACCOUNT_COUNT=$(jq -r '.accounts | length' "$ACCOUNTS_FILE")
ACTIVE_INDEX=$(jq -r '.activeIndex // 0' "$ACCOUNTS_FILE")

if [[ "$ACCOUNT_COUNT" -eq 0 ]]; then
    echo "Error: No accounts found in $ACCOUNTS_FILE"
    exit 1
fi

echo "=== Antigravity (Gemini Cloud Code) Usage ==="
echo "Total accounts: $ACCOUNT_COUNT"
echo ""

for ((i=0; i<ACCOUNT_COUNT; i++)); do
    REFRESH=$(jq -r ".accounts[$i].refreshToken // empty" "$ACCOUNTS_FILE")
    EMAIL=$(jq -r ".accounts[$i].email // \"unknown\"" "$ACCOUNTS_FILE")
    PROJECT_ID=$(jq -r ".accounts[$i].projectId // empty" "$ACCOUNTS_FILE")
    
    if [[ "$i" -eq "$ACTIVE_INDEX" ]]; then
        ACTIVE_MARKER=" (active)"
    else
        ACTIVE_MARKER=""
    fi
    
    echo "--- Account $((i+1)): $EMAIL$ACTIVE_MARKER ---"
    
    if [[ -z "$REFRESH" ]]; then
        echo "  Error: No refresh token found"
        echo ""
        continue
    fi
    
    TOKEN_RESPONSE=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "refresh_token=$REFRESH" \
        -d "grant_type=refresh_token")
    
    ACCESS=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
    
    if [[ -z "$ACCESS" ]]; then
        echo "  Error: Failed to refresh access token"
        echo "$TOKEN_RESPONSE" | jq .
        echo ""
        continue
    fi
    
    # project parameter is required to get all models including gemini-3 variants
    curl -s -X POST "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota" \
        -H "Authorization: Bearer $ACCESS" \
        -H "Content-Type: application/json" \
        -d "{\"project\": \"$PROJECT_ID\"}" | jq '
    {
        "quotas": [.buckets[] | {
            "model": .modelId,
            "remaining": ((.remainingFraction * 100 | floor | tostring) + "%"),
            "reset": .resetTime
        }]
    }'
    
    echo ""
done
