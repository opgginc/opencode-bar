#!/usr/bin/env bash
# Query OpenCode Go API-key status and usage.
#
# OpenCode stores the Go model API key in the OpenCode data auth file under:
#   ~/.local/share/opencode/auth.json -> ["opencode-go"].key
#
# The key validates access to the OpenCode Go model API. Usage windows come
# from the official usage API (https://opencode.ai/zen/go/v1/usage) with the
# same API key.

set -euo pipefail

PROVIDER_ID="opencode-go"
# Mirrored in OpenCodeGoAPI (Providers/OpenCodeGoProvider.swift).
# Update both when the endpoint moves.
MODELS_URL="https://opencode.ai/zen/go/v1/models"
USAGE_API_URL="https://opencode.ai/zen/go/v1/usage"

JSON_OUTPUT=false
MODELS_ONLY=false
AUTH_FILE_OVERRIDE="${OPENCODE_GO_AUTH_FILE:-${OPENCODE_AUTH_FILE:-}}"
API_KEY="${OPENCODE_GO_API_KEY:-${OPENCODE_API_KEY:-}}"
API_KEY_SOURCE=""
USAGE_SOURCE="OpenCode Go API (zen/go/v1/usage)"

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
http_get_to_file() {
    local url="$1"
    local dest="$2"
    shift 2
    local status
    status="$(
        curl -sS -L -o "$dest" -w '%{http_code}' "$url" "$@" || true
    )"
    printf '%s' "$status"
    [[ "$status" =~ ^2 ]]
}

# Extract a server error message from a JSON failure body.
json_error_message() {
    jq -r '.error.message // .message // .error // empty' "$1" 2>/dev/null || true
}

validate_models_api() {
    local body_file
    body_file="$(mktemp)"
    local status
    if ! status="$(http_get_to_file "$MODELS_URL" "$body_file" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json")"; then
        local message
        message="$(json_error_message "$body_file")"
        rm -f "$body_file"
        [[ -n "$message" ]] || message="HTTP $status from $MODELS_URL"
        fail "OpenCode Go API key validation failed: $message"
    fi

    local model_count
    model_count="$(jq -r '(.data // .models // []) | length' "$body_file")"
    rm -f "$body_file"
    printf '%s\n' "$model_count"
}

fetch_usage_api() {
    local body_file
    body_file="$(mktemp)"
    local status
    if ! status="$(http_get_to_file "$USAGE_API_URL" "$body_file" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json")"; then
        local message
        message="$(json_error_message "$body_file")"
        rm -f "$body_file"
        [[ -n "$message" ]] || message="OpenCode Go usage API request failed (HTTP $status)"
        jq -n --arg message "$message" '{"error": $message}'
        return 4
    fi

    parse_go_windows "$body_file"
    local parse_status=$?
    rm -f "$body_file"
    return "$parse_status"
}

# Usage-window parser for the usage API response. Pure jq: no Python needed.
# Usage: parse_go_windows <file>
# Prints {"windows": {...}} on success or {"error": ...} on failure.
parse_go_windows() {
    jq '
def parse_reset:
  if type != "string" or length == 0 then null
  else ((. | sub("\\.[0-9]+Z$"; "Z")) | try fromdateiso8601 catch null) as $t
    | if $t == null then null else {epoch: $t} end
  end;
def duration:
  (. | floor | if . < 0 then 0 else . end) as $s
  | ($s / 86400 | floor) as $d
  | (($s % 86400) / 3600 | floor) as $h
  | (($s % 3600) / 60 | floor) as $m
  | if $d > 0 then "\($d)d \($h)h"
    elif $h > 0 then "\($h)h \($m)m"
    else "\($m)m" end;
def parse_percent:
  if type == "boolean" or . == null then null
  elif type == "number" then .
  elif type == "string" then (try tonumber catch null)
  else null end;
(now | floor) as $now
| ((.usage | select(type == "object")) // {}) as $u | (["rolling", "weekly", "monthly"] | map(
      . as $k
      | ($u[$k] | select(type == "object")) as $e
      | select($e != null)
      | select((($e.status | type) != "string") or (($e.status | ascii_downcase) == "ok"))
      | ($e.percent | parse_percent) as $p
      | select($p != null)
      | ($e.resetsAt | parse_reset) as $r
      | {
          key: $k,
          value: {
            field: $k,
            label: ({"rolling": "5h", "weekly": "Weekly", "monthly": "Monthly"}[$k]),
            usage_percent: $p,
            percent_remaining: ([0, 100 - $p] | max),
            reset_in_seconds: (if $r == null then null else ([$r.epoch - $now, 0] | max | floor) end),
            reset_in: (if $r == null then null else ($r.epoch - $now | duration) end),
            resets_at: $e.resetsAt
          }
        }
    ) | from_entries) as $w
| if ($w | length) == 0 then {error: "No OpenCode Go usage windows found in API response"} | ., halt_error
  else {windows: $w} end
' "$1"
}

print_text_result() {
    local model_count="$1"
    local usage_json="${2:-}"
    local usage_error="${3:-}"

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
        echo "Usage: not available"
        echo "Reason: ${usage_error:-usage API request failed}"
        return
    fi

    echo "Usage source: $USAGE_SOURCE"
    echo "$usage_json" | jq -r '
        def pct: ((. * 100 | round) / 100 | tostring);
        .windows
        | to_entries[]
        | "\(.value.label): \(.value.usage_percent | pct)% used, \(.value.percent_remaining | pct)% left, resets in \(.value.reset_in // "unknown") (\(.value.resets_at // "unknown"))"
    '
}

print_json_result() {
    local model_count="$1"
    local usage_json="${2:-null}"
    local usage_error="${3:-}"

    jq -n \
        --arg provider "$PROVIDER_ID" \
        --arg auth_source "$API_KEY_SOURCE" \
        --arg key_preview "$(mask_secret "$API_KEY")" \
        --arg models_url "$MODELS_URL" \
        --arg usage_source "$USAGE_SOURCE" \
        --argjson model_count "$model_count" \
        --argjson usage "$usage_json" \
        --arg usage_error "$usage_error" \
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
            usage_source: (if $usage_source == "" then null else $usage_source end),
            usage_error: (if $usage_error == "" then null else $usage_error end)
        }'
}

main() {
    parse_args "$@"
    require_command curl
    require_command jq

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
    local usage_error=""
    local api_output=""
    if ! api_output="$(fetch_usage_api)"; then
        usage_error="$(jq -r '.error // empty' <<<"$api_output" 2>/dev/null || true)"
        [[ -n "$usage_error" ]] || usage_error="usage API request failed"
    else
        usage_json="$api_output"
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        if [[ -n "$usage_json" ]]; then
            print_json_result "$model_count" "$usage_json"
        else
            print_json_result "$model_count" "null" "$usage_error"
        fi
    else
        print_text_result "$model_count" "$usage_json" "$usage_error"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
