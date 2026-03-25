#!/bin/bash
# Query Claude usage with the latest Claude Code-compatible OAuth headers.

set -euo pipefail

CLAUDE_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
CLAUDE_BETA_HEADER="${ANTHROPIC_OAUTH_BETA:-oauth-2025-04-20}"
CLAUDE_CODE_VERSION="${ANTHROPIC_CLI_VERSION:-2.1.80}"
CLAUDE_USER_AGENT="${ANTHROPIC_CODE_USER_AGENT:-claude-code/${CLAUDE_CODE_VERSION}}"

AUTH_SOURCE=""
AUTH_RECORD=""

extract_auth_from_json() {
    local input="$1"
    jq -cer '
        def token_from($obj):
            $obj.access
            // $obj.accessToken
            // $obj.oauth.access
            // $obj.oauth.accessToken
            // $obj.claudeAiOAuth.access
            // $obj.claudeAiOAuth.accessToken
            // $obj.claudeOAuth.access
            // $obj.claudeOAuth.accessToken
            // $obj.anthropic.access
            // $obj.anthropic.accessToken
            // $obj.token
            // $obj.oauthToken;
        def account_id_from($obj):
            $obj.accountID
            // $obj.accountId
            // $obj.userID
            // $obj.userId
            // $obj.id
            // $obj.oauth.accountID
            // $obj.oauth.accountId
            // $obj.claudeAiOAuth.accountID
            // $obj.claudeAiOAuth.accountId
            // $obj.claudeOAuth.accountID
            // $obj.claudeOAuth.accountId
            // $obj.anthropic.accountID
            // $obj.anthropic.accountId;
        def email_from($obj):
            $obj.email
            // $obj.userEmail
            // $obj.username
            // $obj.login
            // $obj.oauth.email
            // $obj.claudeAiOAuth.email
            // $obj.claudeOAuth.email
            // $obj.anthropic.email;
        def record($obj):
            token_from($obj) as $access
            | select($access != null and $access != "")
            | {
                access: $access,
                accountId: (account_id_from($obj) // null),
                email: (email_from($obj) // null)
            };
        def candidate_objects($obj):
            [
                $obj,
                $obj.oauth?,
                $obj.claudeAiOAuth?,
                $obj.claudeOAuth?,
                $obj.anthropic?
            ]
            | map(select(type == "object"));
        def first_record($obj):
            ([candidate_objects($obj)[] | record(.)]
             | map(select(. != null)))[0];
        if (.accounts? | type) == "array" then
            ([.accounts[]
              | select(.enabled != false)
              | first_record(.)]
             | map(select(. != null)))[0]
        else
            first_record(.)
        end
        | select(.access != null and .access != "")
    ' <<<"$input" 2>/dev/null || true
}

resolve_auth_from_file() {
    local path="$1"
    [[ -r "$path" ]] || return 1

    local record
    record="$(extract_auth_from_json "$(cat "$path")")"
    [[ -n "$record" ]] || return 1

    AUTH_SOURCE="$path"
    AUTH_RECORD="$record"
    return 0
}

resolve_auth_from_keychain() {
    local service="$1"
    local secret

    secret="$(security find-generic-password -s "$service" -w 2>/dev/null)" || return 1
    [[ -n "$secret" ]] || return 1

    local record=""
    if jq -e . >/dev/null 2>&1 <<<"$secret"; then
        record="$(extract_auth_from_json "$secret")"
    elif [[ "$secret" =~ ^sk-ant-oat[0-9]{2}- ]]; then
        record="$(jq -cn --arg access "$secret" '{access: $access, accountId: null, email: null}')"
    fi

    [[ -n "$record" ]] || return 1

    AUTH_SOURCE="Keychain (${service})"
    AUTH_RECORD="$record"
    return 0
}

resolve_latest_claude_auth() {
    if [[ -n "${CLAUDE_ACCESS_TOKEN:-}" ]]; then
        AUTH_SOURCE="CLAUDE_ACCESS_TOKEN"
        AUTH_RECORD="$(jq -cn --arg access "$CLAUDE_ACCESS_TOKEN" '{access: $access, accountId: null, email: null}')"
        return 0
    fi

    local -a candidate_files=()
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        candidate_files+=("$XDG_CONFIG_HOME/opencode/opencode-anthropic-auth/accounts.json")
    fi
    candidate_files+=("$HOME/.config/opencode/opencode-anthropic-auth/accounts.json")

    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        candidate_files+=("$XDG_DATA_HOME/opencode/auth.json")
    fi
    candidate_files+=("$HOME/.local/share/opencode/auth.json")
    candidate_files+=("$HOME/Library/Application Support/opencode/auth.json")
    candidate_files+=("$HOME/.config/claude-code/auth.json")

    local path
    for path in "${candidate_files[@]}"; do
        if resolve_auth_from_file "$path"; then
            return 0
        fi
    done

    local -a keychain_services=("Claude Code-credentials" "Claude Code")
    local service
    for service in "${keychain_services[@]}"; do
        if resolve_auth_from_keychain "$service"; then
            return 0
        fi
    done

    return 1
}

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required"
    exit 1
fi

if ! resolve_latest_claude_auth; then
    echo "Error: No Claude OAuth token found in the supported auth locations"
    exit 1
fi

ACCESS="$(jq -r '.access' <<<"$AUTH_RECORD")"
ACCOUNT_ID="$(jq -r '.accountId // empty' <<<"$AUTH_RECORD")"
EMAIL="$(jq -r '.email // empty' <<<"$AUTH_RECORD")"

echo "=== Claude (Anthropic) Usage ==="
echo "Auth Source: $AUTH_SOURCE"
[[ -n "$EMAIL" ]] && echo "Email: $EMAIL"
[[ -n "$ACCOUNT_ID" ]] && echo "Account ID: $ACCOUNT_ID"
echo "User-Agent: $CLAUDE_USER_AGENT"
echo "Cookie: disabled"
echo ""

RESPONSE="$(
    curl -fsS "$CLAUDE_USAGE_URL" \
        -H "Authorization: Bearer $ACCESS" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "User-Agent: $CLAUDE_USER_AGENT" \
        -H "anthropic-beta: $CLAUDE_BETA_HEADER"
)"

if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    echo "Error: $(echo "$RESPONSE" | jq -r '.error.message // .error')"
    exit 1
fi

echo "$RESPONSE" | jq '
{
    "5h_usage": ((.five_hour.utilization // 0) | tostring + "%"),
    "5h_reset": .five_hour.resets_at,
    "7d_usage": ((.seven_day.utilization // 0) | tostring + "%"),
    "7d_reset": .seven_day.resets_at,
    "7d_sonnet": ((.seven_day_sonnet.utilization // 0) | tostring + "%"),
    "7d_opus": ((.seven_day_opus.utilization // 0) | tostring + "%"),
    "extra_usage_enabled": .extra_usage.is_enabled
}'
