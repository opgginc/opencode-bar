#!/usr/bin/env bash
# Query OpenCode Go API-key status and quota usage.
#
# OpenCode stores the Go model API key in the OpenCode data auth file under:
#   ~/.local/share/opencode/auth.json -> ["opencode-go"].key
#
# Usage windows come from the key-based usage API (no workspace ID,
# browser cookies, or extra setup needed):
#   GET https://opencode.ai/zen/go/v1/usage
#   Authorization: Bearer <api-key>
# -> {"usage": {"rolling": {"percent": N, "resetsAt": ISO}, ...}}

set -euo pipefail

PROVIDER_ID="opencode-go"
MODELS_URL="https://opencode.ai/zen/go/v1/models"
USAGE_URL="https://opencode.ai/zen/go/v1/usage"

JSON_OUTPUT=false
MODELS_ONLY=false
AUTH_FILE_OVERRIDE="${OPENCODE_GO_AUTH_FILE:-${OPENCODE_AUTH_FILE:-}}"
API_KEY="${OPENCODE_GO_API_KEY:-${OPENCODE_API_KEY:-}}"
API_KEY_SOURCE=""

usage() {
    cat <<'EOF'
Usage: scripts/query-opencode-go.sh [options]

Options:
  --json                    Print machine-readable JSON
  --models-only             Validate the OpenCode Go API key only
  --auth-file PATH          Read OpenCode auth from PATH
  -h, --help                Show this help

Environment:
  OPENCODE_GO_API_KEY       OpenCode Go API key override
  OPENCODE_API_KEY          OpenCode API key override used by the Go provider
  OPENCODE_GO_AUTH_FILE     OpenCode auth.json path override
  OPENCODE_AUTH_FILE        OpenCode auth.json path override
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

mask_secret() {
    local value="$1"
    local length=${#value}

    if (( length <= 8 )); then
        printf '***'
        return
    fi

    local prefix="${value:0:6}"
    local suffix_start=$((length - 4))
    local suffix="${value:suffix_start:4}"
    printf '%s...%s' "$prefix" "$suffix"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --models-only)
                MODELS_ONLY=true
                shift
                ;;
            --auth-file)
                [[ $# -ge 2 ]] || fail "--auth-file requires a path"
                AUTH_FILE_OVERRIDE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "Unknown option: $1"
                ;;
        esac
    done
}

auth_file_candidates() {
    if [[ -n "$AUTH_FILE_OVERRIDE" ]]; then
        printf '%s\n' "$AUTH_FILE_OVERRIDE"
    fi

    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
        printf '%s\n' "$XDG_DATA_HOME/opencode/auth.json"
    fi

    printf '%s\n' "$HOME/.local/share/opencode/auth.json"
    printf '%s\n' "$HOME/Library/Application Support/opencode/auth.json"
}

find_auth_file() {
    local candidate
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(auth_file_candidates)

    return 1
}

load_api_key() {
    if [[ -n "$API_KEY" ]]; then
        API_KEY_SOURCE="environment"
        return
    fi

    local auth_file
    auth_file="$(find_auth_file)" || {
        fail "OpenCode auth file not found. Expected ~/.local/share/opencode/auth.json or set OPENCODE_GO_API_KEY."
    }

    API_KEY="$(jq -r --arg provider "$PROVIDER_ID" '.[$provider].key // empty' "$auth_file")"
    [[ -n "$API_KEY" ]] || {
        fail "No OpenCode Go API key found at $auth_file under key \"$PROVIDER_ID\"."
    }

    API_KEY_SOURCE="$auth_file"
}

api_get() {
    local url="$1"
    local body_file="$2"

    local status
    status="$(
        curl -sS -L -o "$body_file" -w '%{http_code}' "$url" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Accept: application/json" || true
    )"
    printf '%s' "$status"
}

validate_models_api() {
    local body_file
    body_file="$(mktemp)"

    local status
    status="$(api_get "$MODELS_URL" "$body_file")"

    if [[ ! "$status" =~ ^2 ]]; then
        local message
        message="$(jq -r '.error.message // .message // .error // empty' "$body_file" 2>/dev/null || true)"
        rm -f "$body_file"
        [[ -n "$message" ]] || message="HTTP $status from $MODELS_URL"
        fail "OpenCode Go API key validation failed: $message"
    fi

    local model_count
    model_count="$(jq -r '(.data // .models // []) | length' "$body_file")"
    rm -f "$body_file"
    printf '%s\n' "$model_count"
}

fetch_usage() {
    local body_file
    body_file="$(mktemp)"

    local status
    status="$(api_get "$USAGE_URL" "$body_file")"

    if [[ ! "$status" =~ ^2 ]]; then
        local message
        message="$(jq -r '.error.message // .message // .error // empty' "$body_file" 2>/dev/null || true)"
        rm -f "$body_file"
        [[ -n "$message" ]] || message="HTTP $status from $USAGE_URL"
        echo "Error: OpenCode Go usage request failed: $message" >&2
        return 1
    fi

    python3 - "$body_file" <<'PY'
import datetime as dt
import json
import sys

path = sys.argv[1]
payload = json.load(open(path))

fields = {
    "rolling": ("rolling", "5h"),
    "weekly": ("weekly", "Weekly"),
    "monthly": ("monthly", "Monthly"),
}

usage = payload.get("usage") or {}
now = dt.datetime.now(dt.timezone.utc)
windows = {}

def parse_reset(value):
    if not value:
        return None
    text = str(value).replace("Z", "+00:00")
    try:
        return dt.datetime.fromisoformat(text)
    except ValueError:
        return None

def duration(seconds):
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"

for key, (field, label) in fields.items():
    entry = usage.get(field) or {}
    try:
        usage_percent = float(entry.get("percent"))
    except (TypeError, ValueError):
        continue
    reset_at = parse_reset(entry.get("resetsAt"))
    reset_seconds = max(0, int((reset_at - now).total_seconds())) if reset_at else 0
    windows[key] = {
        "field": field,
        "label": label,
        "usage_percent": usage_percent,
        "percent_remaining": max(0.0, 100.0 - usage_percent),
        "reset_in_seconds": reset_seconds,
        "reset_in": duration(reset_seconds),
        "resets_at": reset_at.isoformat().replace("+00:00", "Z") if reset_at else None,
    }

if not windows:
    print(json.dumps({"error": "No OpenCode Go usage windows found in API response"}))
    sys.exit(2)

print(json.dumps({"windows": windows}, sort_keys=True))
PY

    local parse_status=$?
    rm -f "$body_file"
    return "$parse_status"
}

print_text_result() {
    local model_count="$1"
    local usage_json="${2:-}"

    echo "=== OpenCode Go Usage ==="
    echo ""
    echo "Auth source: $API_KEY_SOURCE"
    echo "API key: $(mask_secret "$API_KEY")"
    echo "Model API: OK ($model_count models available)"

    if [[ "$MODELS_ONLY" == true ]]; then
        return
    fi

    echo ""
    if [[ -z "$usage_json" ]]; then
        echo "Usage: not available (usage API request failed)"
        return
    fi

    echo "Usage source: OpenCode Go API (zen/go/v1/usage)"
    echo "$usage_json" | jq -r '
        def pct: ((. * 100 | round) / 100 | tostring);
        .windows
        | to_entries[]
        | "\(.value.label): \(.value.usage_percent | pct)% used, \(.value.percent_remaining | pct)% left, resets in \(.value.reset_in) (\(.value.resets_at // "unknown"))"
    '
}

print_json_result() {
    local model_count="$1"
    local usage_json="${2:-null}"

    jq -n \
        --arg provider "$PROVIDER_ID" \
        --arg auth_source "$API_KEY_SOURCE" \
        --arg key_preview "$(mask_secret "$API_KEY")" \
        --arg models_url "$MODELS_URL" \
        --arg usage_url "$USAGE_URL" \
        --argjson model_count "$model_count" \
        --argjson usage "$usage_json" \
        '{
            provider: $provider,
            auth: {
                source: $auth_source,
                key_preview: $key_preview
            },
            models: {
                endpoint: $models_url,
                status: "ok",
                count: $model_count
            },
            usage: $usage,
            usage_source: "OpenCode Go API (zen/go/v1/usage)",
            usage_endpoint: $usage_url
        }'
}

main() {
    parse_args "$@"
    require_command curl
    require_command jq
    require_command python3

    load_api_key

    local model_count
    model_count="$(validate_models_api)"

    if [[ "$MODELS_ONLY" == true ]]; then
        if [[ "$JSON_OUTPUT" == true ]]; then
            print_json_result "$model_count"
        else
            print_text_result "$model_count"
        fi
        return
    fi

    local usage_json=""
    if ! usage_json="$(fetch_usage)"; then
        usage_json=""
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        if [[ -n "$usage_json" ]]; then
            print_json_result "$model_count" "$usage_json"
        else
            print_json_result "$model_count"
        fi
    else
        print_text_result "$model_count" "$usage_json"
    fi
}

main "$@"
