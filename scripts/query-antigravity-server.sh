#!/bin/bash
# Query Antigravity local usage from the running language_server process.
# This script requires Antigravity app (language_server_macos) to be running.
# Auth/token fields are masked by default.

set -e

PROCESS_NAME="language_server_macos"
CACHE_DB="$HOME/Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
ACCOUNTS_FILE="$HOME/.config/opencode/antigravity-accounts.json"

SHOW_SECRETS="${AG_SHOW_SECRETS:-0}"
KEYCHAIN_SERVICE="${AG_KEYCHAIN_SERVICE:-}"
KEYCHAIN_ENABLED="${AG_KEYCHAIN_ENABLED:-1}"

KEYCHAIN_SERVICE_CANDIDATES=(
    "Antigravity Safe Storage"
    "Code Safe Storage"
)

PID=""
COMMAND=""
CSRF_TOKEN=""
PORTS=""
ACTIVE_PORT=""
ACTIVE_SCHEME=""
RESPONSE=""

CACHE_EMAIL=""
CACHE_NAME=""
CACHE_API_KEY=""

ACCOUNT_INDEX=""
ACCOUNT_EMAIL=""
ACCOUNT_PROJECT_ID=""
ACCOUNT_MANAGED_PROJECT_ID=""
ACCOUNT_ENABLED=""
ACCOUNT_REFRESH_TOKEN=""

KEYCHAIN_LOOKUP=false
KEYCHAIN_ERROR=""
KEYCHAIN_EMAIL=""
KEYCHAIN_TOKEN=""

OAUTH_TOKEN_BLOB=""

usage() {
    cat <<'EOF'
Usage: query-antigravity-server.sh [--show-secrets] [--no-keychain] [--keychain-service <service>]

Options:
  --show-secrets              Include raw token values in output
  --no-keychain               Disable keychain lookup
  --keychain-service <name>   Query one explicit keychain service
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show-secrets)
            SHOW_SECRETS=1
            shift
            ;;
        --keychain-service)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --keychain-service requires a value"
                exit 1
            fi
            KEYCHAIN_SERVICE="$2"
            shift 2
            ;;
        --no-keychain)
            KEYCHAIN_ENABLED=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

for dep in ps awk grep sed lsof curl jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Error: Required command not found: $dep"
        exit 1
    fi
done

mask_secret() {
    local value="$1"
    local len=${#value}

    if [[ $len -eq 0 ]]; then
        echo ""
        return
    fi

    if [[ $len -le 10 ]]; then
        echo "***"
        return
    fi

    local suffix_start=$((len - 4))
    printf "%s...%s" "${value:0:6}" "${value:$suffix_start:4}"
}

build_secret_json() {
    local value="$1"
    local source="$2"
    local present=false
    local length=0
    local masked=""

    if [[ -n "$value" ]]; then
        present=true
        length=${#value}
        masked=$(mask_secret "$value")
    fi

    if [[ "$SHOW_SECRETS" == "1" && -n "$value" ]]; then
        jq -cn \
            --arg source "$source" \
            --arg masked "$masked" \
            --arg value "$value" \
            --argjson present "$present" \
            --argjson length "$length" \
            '{present:$present, length:$length, masked:$masked, value:$value, source:$source}'
    else
        jq -cn \
            --arg source "$source" \
            --arg masked "$masked" \
            --argjson present "$present" \
            --argjson length "$length" \
            '{present:$present, length:$length, masked:$masked, source:$source}'
    fi
}

detect_process_info() {
    local line
    line=$(ps -ax -o pid=,command= | awk -v process_name="$PROCESS_NAME" '
        BEGIN {
            process_name = tolower(process_name)
        }
        {
            lower = tolower($0)
            if (index(lower, process_name) > 0 &&
                index(lower, "antigravity") > 0 &&
                index($0, "--csrf_token") > 0) {
                print $0
                exit
            }
        }
    ')

    if [[ -z "$line" ]]; then
        echo "Error: Antigravity language server not running"
        echo "Launch Antigravity IDE and retry"
        exit 1
    fi

    PID=$(echo "$line" | awk '{print $1}')
    COMMAND=$(echo "$line" | cut -d' ' -f2-)

    CSRF_TOKEN=$(echo "$COMMAND" | grep -oE '\-\-csrf_token[= ]+[^ ]+' | sed 's/--csrf_token[= ]*//')
    if [[ -z "$CSRF_TOKEN" ]]; then
        echo "Error: CSRF token not found in process args"
        exit 1
    fi
}

detect_ports() {
    PORTS=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PID" 2>/dev/null | grep -oE ':[0-9]+' | sed 's/://' | sort -u)
    if [[ -z "$PORTS" ]]; then
        echo "Error: No listening ports found for PID $PID"
        exit 1
    fi
}

make_request() {
    local port=$1
    local scheme=$2
    local body='{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}'

    curl -s -k -X POST "${scheme}://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/GetUserStatus" \
        -H "Content-Type: application/json" \
        -H "Connect-Protocol-Version: 1" \
        -H "X-Codeium-Csrf-Token: $CSRF_TOKEN" \
        -d "$body" \
        --connect-timeout 5 \
        --max-time 10
}

collect_cached_auth() {
    if [[ ! -f "$CACHE_DB" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
        return
    fi

    local cache_auth_json
    cache_auth_json=$(sqlite3 "$CACHE_DB" "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='antigravityAuthStatus';" 2>/dev/null || true)
    if [[ -z "$cache_auth_json" ]]; then
        return
    fi

    CACHE_EMAIL=$(printf "%s" "$cache_auth_json" | jq -r '.email // empty' 2>/dev/null || true)
    CACHE_NAME=$(printf "%s" "$cache_auth_json" | jq -r '.name // empty' 2>/dev/null || true)
    CACHE_API_KEY=$(printf "%s" "$cache_auth_json" | jq -r '.apiKey // empty' 2>/dev/null || true)

    OAUTH_TOKEN_BLOB=$(sqlite3 "$CACHE_DB" "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='antigravityUnifiedStateSync.oauthToken';" 2>/dev/null || true)
    OAUTH_TOKEN_BLOB="${OAUTH_TOKEN_BLOB//$'\n'/}"
    OAUTH_TOKEN_BLOB="${OAUTH_TOKEN_BLOB//$'\r'/}"
}

resolve_keychain_service() {
    if [[ "$KEYCHAIN_ENABLED" != "1" ]]; then
        return
    fi

    if [[ -n "$KEYCHAIN_SERVICE" ]]; then
        return
    fi

    if ! command -v security >/dev/null 2>&1; then
        KEYCHAIN_ENABLED=0
        KEYCHAIN_ERROR="security_binary_not_found"
        return
    fi

    local candidate
    for candidate in "${KEYCHAIN_SERVICE_CANDIDATES[@]}"; do
        if security find-generic-password -s "$candidate" >/dev/null 2>&1; then
            KEYCHAIN_SERVICE="$candidate"
            return
        fi
    done
}

collect_account_auth() {
    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        return
    fi

    local selected
    selected=$(jq -c '
        def pick_index:
            if (.activeAccountIndex // null) != null and (.accounts[.activeAccountIndex] // null) != null then
                .activeAccountIndex
            else
                ([.accounts // [] | to_entries[] | select((.value.enabled // true) == true) | .key] | first // null)
            end;

        if (.accounts | type) != "array" or (.accounts | length) == 0 then
            {}
        else
            (pick_index) as $idx
            | if $idx == null then
                {}
              else
                (.accounts[$idx]) as $acc
                | {
                    index: $idx,
                    email: ($acc.email // ""),
                    projectId: ($acc.projectId // ""),
                    managedProjectId: ($acc.managedProjectId // ""),
                    enabled: ($acc.enabled // true),
                    refreshToken: ($acc.refreshToken // "")
                  }
              end
        end
    ' "$ACCOUNTS_FILE" 2>/dev/null || echo '{}')

    ACCOUNT_INDEX=$(printf "%s" "$selected" | jq -r '.index // empty' 2>/dev/null || true)
    ACCOUNT_EMAIL=$(printf "%s" "$selected" | jq -r '.email // empty' 2>/dev/null || true)
    ACCOUNT_PROJECT_ID=$(printf "%s" "$selected" | jq -r '.projectId // empty' 2>/dev/null || true)
    ACCOUNT_MANAGED_PROJECT_ID=$(printf "%s" "$selected" | jq -r '.managedProjectId // empty' 2>/dev/null || true)
    ACCOUNT_ENABLED=$(printf "%s" "$selected" | jq -r '.enabled // empty' 2>/dev/null || true)
    ACCOUNT_REFRESH_TOKEN=$(printf "%s" "$selected" | jq -r '.refreshToken // empty' 2>/dev/null || true)
}

collect_keychain_auth() {
    if [[ "$KEYCHAIN_ENABLED" != "1" ]]; then
        return
    fi

    if ! command -v security >/dev/null 2>&1; then
        KEYCHAIN_ERROR="security_binary_not_found"
        return
    fi

    if [[ -z "$KEYCHAIN_SERVICE" ]]; then
        return
    fi

    KEYCHAIN_LOOKUP=true

    local keychain_raw
    if keychain_raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null); then
        if printf "%s" "$keychain_raw" | jq -e . >/dev/null 2>&1; then
            KEYCHAIN_TOKEN=$(printf "%s" "$keychain_raw" | jq -r '.refreshToken // .refresh_token // .token // .apiKey // .accessToken // .access // empty' 2>/dev/null || true)
            KEYCHAIN_EMAIL=$(printf "%s" "$keychain_raw" | jq -r '.email // .userEmail // .username // empty' 2>/dev/null || true)
        else
            KEYCHAIN_TOKEN="$keychain_raw"
        fi
    else
        KEYCHAIN_ERROR="not_found_or_locked"
    fi
}

build_auth_json() {
    local csrf_json cache_api_key_json refresh_token_json keychain_token_json oauth_token_blob_json
    local keychain_token_source="Keychain disabled"
    local account_index_json="null"
    local account_enabled_json="null"

    csrf_json=$(build_secret_json "$CSRF_TOKEN" "language_server_macos --csrf_token")
    cache_api_key_json=$(build_secret_json "$CACHE_API_KEY" "$CACHE_DB key=antigravityAuthStatus.apiKey")
    oauth_token_blob_json=$(build_secret_json "$OAUTH_TOKEN_BLOB" "$CACHE_DB key=antigravityUnifiedStateSync.oauthToken")
    refresh_token_json=$(build_secret_json "$ACCOUNT_REFRESH_TOKEN" "$ACCOUNTS_FILE account.refreshToken")
    if [[ "$KEYCHAIN_ENABLED" != "1" ]]; then
        keychain_token_source="Keychain disabled"
    elif [[ -n "$KEYCHAIN_SERVICE" ]]; then
        keychain_token_source="Keychain service: $KEYCHAIN_SERVICE"
    fi
    keychain_token_json=$(build_secret_json "$KEYCHAIN_TOKEN" "$keychain_token_source")

    if [[ -n "$ACCOUNT_INDEX" ]]; then
        account_index_json="$ACCOUNT_INDEX"
    fi

    if [[ "$ACCOUNT_ENABLED" == "true" || "$ACCOUNT_ENABLED" == "false" ]]; then
        account_enabled_json="$ACCOUNT_ENABLED"
    fi

    jq -cn \
        --arg cacheDb "$CACHE_DB" \
        --arg accountsFile "$ACCOUNTS_FILE" \
        --arg cacheEmail "$CACHE_EMAIL" \
        --arg cacheName "$CACHE_NAME" \
        --arg accountEmail "$ACCOUNT_EMAIL" \
        --arg accountProjectId "$ACCOUNT_PROJECT_ID" \
        --arg accountManagedProjectId "$ACCOUNT_MANAGED_PROJECT_ID" \
        --arg keychainService "$KEYCHAIN_SERVICE" \
        --arg keychainEmail "$KEYCHAIN_EMAIL" \
        --arg keychainError "$KEYCHAIN_ERROR" \
        --argjson accountIndex "$account_index_json" \
        --argjson accountEnabled "$account_enabled_json" \
        --argjson keychainLookup "$KEYCHAIN_LOOKUP" \
        --argjson csrfToken "$csrf_json" \
        --argjson cacheApiKey "$cache_api_key_json" \
        --argjson oauthTokenBlob "$oauth_token_blob_json" \
        --argjson refreshToken "$refresh_token_json" \
        --argjson keychainToken "$keychain_token_json" \
        '{
            csrfToken: $csrfToken,
            cacheApiKey: $cacheApiKey,
            oauthTokenBlob: $oauthTokenBlob,
            refreshToken: $refreshToken,
            cacheProfile: {
                source: $cacheDb,
                email: (if $cacheEmail == "" then null else $cacheEmail end),
                name: (if $cacheName == "" then null else $cacheName end)
            },
            account: {
                source: $accountsFile,
                index: $accountIndex,
                enabled: $accountEnabled,
                email: (if $accountEmail == "" then null else $accountEmail end),
                projectId: (if $accountProjectId == "" then null else $accountProjectId end),
                managedProjectId: (if $accountManagedProjectId == "" then null else $accountManagedProjectId end)
            },
            keychain: {
                lookupRequested: $keychainLookup,
                service: (if $keychainService == "" then null else $keychainService end),
                lookupError: (if $keychainError == "" then null else $keychainError end),
                email: (if $keychainEmail == "" then null else $keychainEmail end),
                token: $keychainToken
            }
        }'
}

echo "=== Antigravity Local (Language Server) Usage ==="
echo ""

detect_process_info
detect_ports
collect_cached_auth
collect_account_auth
resolve_keychain_service
collect_keychain_auth

for port in $PORTS; do
    if RESPONSE=$(make_request "$port" "https" 2>/dev/null); then
        ACTIVE_PORT="$port"
        ACTIVE_SCHEME="https"
        break
    fi

    if RESPONSE=$(make_request "$port" "http" 2>/dev/null); then
        ACTIVE_PORT="$port"
        ACTIVE_SCHEME="http"
        break
    fi
done

if [[ -z "$RESPONSE" ]]; then
    echo "Error: Failed to connect to any port"
    exit 1
fi

if echo "$RESPONSE" | jq -e '.code' > /dev/null 2>&1; then
    CODE=$(echo "$RESPONSE" | jq -r '.code // "OK"')
    if [[ "$CODE" != "0" && "$CODE" != "OK" && "$CODE" != "ok" ]]; then
        echo "Error: API returned code $CODE"
        echo "$RESPONSE" | jq .
        exit 1
    fi
fi

AUTH_JSON=$(build_auth_json)

echo "$RESPONSE" | jq \
    --arg source "Antigravity Local Server (language_server_macos)" \
    --arg scheme "$ACTIVE_SCHEME" \
    --argjson pid "$PID" \
    --argjson port "$ACTIVE_PORT" \
    --argjson auth "$AUTH_JSON" '
{
    "source": $source,
    "server": {
        "pid": $pid,
        "port": $port,
        "scheme": $scheme
    },
    "email": (.userStatus.email // .userStatus.account.email // null),
    "plan": (.userStatus.userTier.name // .userStatus.planStatus.planInfo.planDisplayName // "unknown"),
    "models": [
        .userStatus.cascadeModelConfigData.clientModelConfigs[]? |
        select(.quotaInfo) |
        {
            "label": .label,
            "model": .modelOrAlias.model,
            "remaining": ((.quotaInfo.remainingFraction // 1) * 100 | floor | tostring + "%"),
            "reset": .quotaInfo.resetTime
        }
    ],
    "auth": $auth
}'
