#!/bin/bash
# Inspect Gemini OAuth credentials from ~/.gemini/oauth_creds.json
# This script is for local verification of account identity metadata
# (email/sub account ID) and basic token usability.

set -euo pipefail

CREDS_FILE="${1:-$HOME/.gemini/oauth_creds.json}"
USERINFO_URL="https://www.googleapis.com/oauth2/v1/userinfo?alt=json"
TOKEN_ENDPOINT="https://oauth2.googleapis.com/token"

# Public clients used by Gemini CLI / installed app OAuth flows.
# These are not secrets. Users can override with GEMINI_CLIENT_ID/SECRET.
DEFAULT_CLIENT_ID="1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
DEFAULT_CLIENT_SECRET="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"
PLUGIN_CLIENT_ID="681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
PLUGIN_CLIENT_SECRET="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"
CLIENT_ID="${GEMINI_CLIENT_ID:-$DEFAULT_CLIENT_ID}"
CLIENT_SECRET="${GEMINI_CLIENT_SECRET:-$DEFAULT_CLIENT_SECRET}"

if [[ ! -f "$CREDS_FILE" ]]; then
    echo "Error: oauth_creds.json not found at $CREDS_FILE"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required"
    exit 1
fi

decode_base64() {
    if base64 --help 2>/dev/null | grep -q -- "-d"; then
        base64 -d
    else
        base64 -D
    fi
}

decode_jwt_payload() {
    local token="$1"
    local payload
    payload=$(echo "$token" | cut -d'.' -f2 | tr '_-' '/+')
    local mod=$(( ${#payload} % 4 ))
    if [[ $mod -eq 2 ]]; then
        payload="${payload}=="
    elif [[ $mod -eq 3 ]]; then
        payload="${payload}="
    elif [[ $mod -eq 1 ]]; then
        payload="${payload}==="
    fi
    echo "$payload" | decode_base64 2>/dev/null || true
}

mask_token() {
    local token="$1"
    local len=${#token}
    if [[ $len -le 12 ]]; then
        echo "<redacted>"
        return
    fi
    local prefix=${token:0:6}
    local suffix=${token: -4}
    echo "${prefix}...${suffix}"
}

call_userinfo() {
    local access_token="$1"
    curl -sS "$USERINFO_URL" \
        -H "Authorization: Bearer $access_token" \
        -H "Accept: application/json"
}

echo "=== Gemini OAuth Creds Inspection ==="
echo "File: $CREDS_FILE"
echo ""

EXPIRY_DATE=$(jq -r '.expiry_date // empty' "$CREDS_FILE")
TOKEN_TYPE=$(jq -r '.token_type // empty' "$CREDS_FILE")
ACCESS_TOKEN=$(jq -r '.access_token // empty' "$CREDS_FILE")
REFRESH_TOKEN=$(jq -r '.refresh_token // empty' "$CREDS_FILE")
ID_TOKEN=$(jq -r '.id_token // empty' "$CREDS_FILE")
SCOPE=$(jq -r '.scope // empty' "$CREDS_FILE")
ID_PAYLOAD=""

echo "Token type: ${TOKEN_TYPE:-unknown}"
echo "Scope: ${SCOPE:-unknown}"
if [[ -n "$EXPIRY_DATE" ]]; then
    echo "Expiry (ms): $EXPIRY_DATE"
fi
echo "Has access token: $([[ -n "$ACCESS_TOKEN" ]] && echo YES || echo NO)"
echo "Has refresh token: $([[ -n "$REFRESH_TOKEN" ]] && echo YES || echo NO)"
echo "Has id token: $([[ -n "$ID_TOKEN" ]] && echo YES || echo NO)"
echo ""

if [[ -n "$ID_TOKEN" ]]; then
    echo "=== Identity (from id_token payload) ==="
    ID_PAYLOAD=$(decode_jwt_payload "$ID_TOKEN")
    if [[ -n "$ID_PAYLOAD" ]]; then
        echo "$ID_PAYLOAD" | jq '{
            issuer: .iss,
            audience: .aud,
            email: .email,
            account_id: .sub,
            email_verified: .email_verified,
            expires_at_epoch: .exp
        }'
    else
        echo "Failed to decode id_token payload"
    fi
    echo ""
fi

if [[ -z "${GEMINI_CLIENT_ID:-}" && -n "$ID_PAYLOAD" ]]; then
    AUDIENCE=$(echo "$ID_PAYLOAD" | jq -r '.aud // empty')
    if [[ "$AUDIENCE" == "$PLUGIN_CLIENT_ID" ]]; then
        CLIENT_ID="$PLUGIN_CLIENT_ID"
        CLIENT_SECRET="$PLUGIN_CLIENT_SECRET"
    elif [[ "$AUDIENCE" == "$DEFAULT_CLIENT_ID" ]]; then
        CLIENT_ID="$DEFAULT_CLIENT_ID"
        CLIENT_SECRET="$DEFAULT_CLIENT_SECRET"
    fi
fi

echo "Refresh client: $CLIENT_ID"
echo ""

if [[ -n "$ACCESS_TOKEN" ]]; then
    echo "=== UserInfo (current access token) ==="
    USERINFO_RESPONSE=$(call_userinfo "$ACCESS_TOKEN")
    if echo "$USERINFO_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        echo "Access token userinfo call failed:"
        echo "$USERINFO_RESPONSE" | jq .
    else
        echo "$USERINFO_RESPONSE" | jq '{email, id, verified_email, hd}'
    fi
    echo ""
fi

if [[ -n "$REFRESH_TOKEN" ]]; then
    echo "=== Refresh Token Check ==="
    REFRESH_RESPONSE=$(curl -sS -X POST "$TOKEN_ENDPOINT" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "refresh_token=$REFRESH_TOKEN" \
        -d "grant_type=refresh_token")

    if echo "$REFRESH_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
        NEW_ACCESS=$(echo "$REFRESH_RESPONSE" | jq -r '.access_token')
        EXPIRES_IN=$(echo "$REFRESH_RESPONSE" | jq -r '.expires_in // "unknown"')
        echo "Refresh succeeded"
        echo "Access token: $(mask_token "$NEW_ACCESS")"
        echo "Expires in: ${EXPIRES_IN}s"

        echo ""
        echo "=== UserInfo (refreshed token) ==="
        REFRESHED_USERINFO=$(call_userinfo "$NEW_ACCESS")
        if echo "$REFRESHED_USERINFO" | jq -e '.error' >/dev/null 2>&1; then
            echo "Refreshed token userinfo call failed:"
            echo "$REFRESHED_USERINFO" | jq .
        else
            echo "$REFRESHED_USERINFO" | jq '{email, id, verified_email, hd}'
        fi
    elif echo "$REFRESH_RESPONSE" | jq -e '.error == "unauthorized_client"' >/dev/null 2>&1; then
        # Automatic fallback for environments where oauth_creds was issued with
        # a different public OAuth client.
        ALT_CLIENT_ID="$PLUGIN_CLIENT_ID"
        ALT_CLIENT_SECRET="$PLUGIN_CLIENT_SECRET"
        if [[ "$CLIENT_ID" == "$PLUGIN_CLIENT_ID" ]]; then
            ALT_CLIENT_ID="$DEFAULT_CLIENT_ID"
            ALT_CLIENT_SECRET="$DEFAULT_CLIENT_SECRET"
        fi

        echo "Refresh unauthorized for client $CLIENT_ID, retrying with $ALT_CLIENT_ID"
        RETRY_RESPONSE=$(curl -sS -X POST "$TOKEN_ENDPOINT" \
            -d "client_id=$ALT_CLIENT_ID" \
            -d "client_secret=$ALT_CLIENT_SECRET" \
            -d "refresh_token=$REFRESH_TOKEN" \
            -d "grant_type=refresh_token")

        if echo "$RETRY_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
            NEW_ACCESS=$(echo "$RETRY_RESPONSE" | jq -r '.access_token')
            EXPIRES_IN=$(echo "$RETRY_RESPONSE" | jq -r '.expires_in // "unknown"')
            echo "Refresh succeeded (fallback client)"
            echo "Access token: $(mask_token "$NEW_ACCESS")"
            echo "Expires in: ${EXPIRES_IN}s"

            echo ""
            echo "=== UserInfo (refreshed token) ==="
            REFRESHED_USERINFO=$(call_userinfo "$NEW_ACCESS")
            if echo "$REFRESHED_USERINFO" | jq -e '.error' >/dev/null 2>&1; then
                echo "Refreshed token userinfo call failed:"
                echo "$REFRESHED_USERINFO" | jq .
            else
                echo "$REFRESHED_USERINFO" | jq '{email, id, verified_email, hd}'
            fi
        else
            echo "Refresh failed after fallback:"
            echo "$RETRY_RESPONSE" | jq .
            exit 1
        fi
    else
        echo "Refresh failed:"
        echo "$REFRESH_RESPONSE" | jq .
        exit 1
    fi
fi
