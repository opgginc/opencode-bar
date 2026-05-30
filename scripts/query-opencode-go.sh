#!/usr/bin/env bash
# Query OpenCode Go API-key status and dashboard usage.
#
# OpenCode stores the Go model API key in the OpenCode data auth file under:
#   ~/.local/share/opencode/auth.json -> ["opencode-go"].key
#
# The key validates access to the OpenCode Go model API. Usage windows are
# exposed by the web dashboard. This script first uses explicit dashboard
# config, then falls back to Chromium browser auth cookies and workspace
# history from Chrome, Brave, Arc, or Edge.

set -euo pipefail

PROVIDER_ID="opencode-go"
MODELS_URL="https://opencode.ai/zen/go/v1/models"
DASHBOARD_BASE_URL="https://opencode.ai/workspace"

JSON_OUTPUT=false
MODELS_ONLY=false
AUTH_FILE_OVERRIDE="${OPENCODE_GO_AUTH_FILE:-${OPENCODE_AUTH_FILE:-}}"
CONFIG_FILE_OVERRIDE="${OPENCODE_GO_CONFIG_FILE:-}"
API_KEY="${OPENCODE_GO_API_KEY:-${OPENCODE_API_KEY:-}}"
API_KEY_SOURCE=""
WORKSPACE_ID="${OPENCODE_GO_WORKSPACE_ID:-}"
AUTH_COOKIE="${OPENCODE_GO_AUTH_COOKIE:-}"
USAGE_CONFIG_SOURCE=""

usage() {
    cat <<'EOF'
Usage: scripts/query-opencode-go.sh [options]

Options:
  --json                    Print machine-readable JSON
  --models-only             Validate the OpenCode Go API key only
  --auth-file PATH          Read OpenCode auth from PATH
  --config-file PATH        Read dashboard usage config from PATH
  --workspace-id ID         OpenCode workspace ID for dashboard usage scraping
  --auth-cookie COOKIE      Browser auth cookie value for dashboard usage scraping
  -h, --help                Show this help

Environment:
  OPENCODE_GO_API_KEY       OpenCode Go API key override
  OPENCODE_API_KEY          OpenCode API key override used by the Go provider
  OPENCODE_GO_AUTH_FILE     OpenCode auth.json path override
  OPENCODE_AUTH_FILE        OpenCode auth.json path override
  OPENCODE_GO_CONFIG_FILE   Dashboard config JSON path override
  OPENCODE_GO_WORKSPACE_ID  Workspace ID for https://opencode.ai/workspace/<id>/go
  OPENCODE_GO_AUTH_COOKIE   Browser auth cookie value for the OpenCode dashboard

Config file:
  ~/.config/opencode-bar/opencode-go.json or ~/.config/opencode-quota/opencode-go.json
  with fields: {"workspaceId":"...","authCookie":"..."}

Fallback:
  If dashboard config is not set, the script tries to read the opencode.ai
  auth cookie and recent /workspace/<id>/go visits from Chromium browser
  profiles on this Mac.
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
            --config-file)
                [[ $# -ge 2 ]] || fail "--config-file requires a path"
                CONFIG_FILE_OVERRIDE="$2"
                shift 2
                ;;
            --workspace-id)
                [[ $# -ge 2 ]] || fail "--workspace-id requires a value"
                WORKSPACE_ID="$2"
                shift 2
                ;;
            --auth-cookie)
                [[ $# -ge 2 ]] || fail "--auth-cookie requires a value"
                AUTH_COOKIE="$2"
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

dashboard_config_candidates() {
    if [[ -n "$CONFIG_FILE_OVERRIDE" ]]; then
        printf '%s\n' "$CONFIG_FILE_OVERRIDE"
    fi

    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        printf '%s\n' "$XDG_CONFIG_HOME/opencode-bar/opencode-go.json"
        printf '%s\n' "$XDG_CONFIG_HOME/opencode-quota/opencode-go.json"
    fi

    printf '%s\n' "$HOME/.config/opencode-bar/opencode-go.json"
    printf '%s\n' "$HOME/.config/opencode-quota/opencode-go.json"
    printf '%s\n' "$HOME/Library/Application Support/opencode-bar/opencode-go.json"
    printf '%s\n' "$HOME/Library/Application Support/opencode-quota/opencode-go.json"
}

load_dashboard_config() {
    if [[ -n "$WORKSPACE_ID" && -n "$AUTH_COOKIE" ]]; then
        USAGE_CONFIG_SOURCE="environment"
        return
    fi

    local candidate
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        [[ -f "$candidate" ]] || continue

        local workspace_id auth_cookie
        workspace_id="$(jq -r '.workspaceId // .workspaceID // .workspace_id // empty' "$candidate" 2>/dev/null || true)"
        auth_cookie="$(jq -r '.authCookie // .auth_cookie // .cookie // empty' "$candidate" 2>/dev/null || true)"

        if [[ -n "$workspace_id" && -n "$auth_cookie" ]]; then
            [[ -n "$WORKSPACE_ID" ]] || WORKSPACE_ID="$workspace_id"
            [[ -n "$AUTH_COOKIE" ]] || AUTH_COOKIE="$auth_cookie"
            USAGE_CONFIG_SOURCE="$candidate"
            return
        fi
    done < <(dashboard_config_candidates)
}

validate_models_api() {
    local body_file
    body_file="$(mktemp)"

    local status
    status="$(
        curl -sS -L -o "$body_file" -w '%{http_code}' "$MODELS_URL" \
            -H "Authorization: Bearer $API_KEY" \
            -H "Accept: application/json" || true
    )"

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

fetch_dashboard_usage() {
    [[ -n "$WORKSPACE_ID" ]] || return 3
    [[ -n "$AUTH_COOKIE" ]] || return 3

    local dashboard_url="$DASHBOARD_BASE_URL/$WORKSPACE_ID/go"
    local cookie_header="auth=$AUTH_COOKIE"
    if [[ "$AUTH_COOKIE" == *"auth="* ]]; then
        cookie_header="$AUTH_COOKIE"
    fi

    local html_file
    html_file="$(mktemp)"

    local status
    status="$(
        curl -sS -L -o "$html_file" -w '%{http_code}' "$dashboard_url" \
            -H "Accept: text/html,application/xhtml+xml" \
            -H "Cookie: $cookie_header" \
            -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36" || true
    )"

    if [[ ! "$status" =~ ^2 ]]; then
        rm -f "$html_file"
        return 4
    fi

    python3 - "$html_file" <<'PY'
import datetime as dt
import html
import json
import re
import sys

path = sys.argv[1]
raw = open(path, "r", encoding="utf-8", errors="ignore").read()
text = html.unescape(raw).replace('\\"', '"')

fields = {
    "rolling": ("rollingUsage", "5h"),
    "weekly": ("weeklyUsage", "Weekly"),
    "monthly": ("monthlyUsage", "Monthly"),
}

number = r'"?(-?\d+(?:\.\d+)?)"?'
now = dt.datetime.now(dt.timezone.utc)
windows = {}

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
    object_match = re.search(rf'["\']?{re.escape(field)}["\']?\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\{{(?P<body>[^{{}}]*)\}}', text, re.DOTALL)
    if not object_match:
        continue

    body = object_match.group("body")
    usage_match = re.search(rf'["\']?usagePercent["\']?\s*:\s*{number}', body)
    reset_match = re.search(rf'["\']?resetInSec["\']?\s*:\s*{number}', body)
    if not usage_match or not reset_match:
        continue

    usage_percent = float(usage_match.group(1))
    reset_seconds = int(float(reset_match.group(1)))
    reset_at = now + dt.timedelta(seconds=reset_seconds)
    windows[key] = {
        "field": field,
        "label": label,
        "usage_percent": usage_percent,
        "percent_remaining": max(0.0, 100.0 - usage_percent),
        "reset_in_seconds": reset_seconds,
        "reset_in": duration(reset_seconds),
        "resets_at": reset_at.isoformat().replace("+00:00", "Z"),
    }

if not windows:
    print(json.dumps({"error": "No OpenCode Go usage windows found in dashboard HTML"}))
    sys.exit(2)

print(json.dumps({"windows": windows}, sort_keys=True))
PY

    local parse_status=$?
    rm -f "$html_file"
    return "$parse_status"
}

discover_browser_dashboard_candidates() {
    python3 <<'PY'
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from hashlib import pbkdf2_hmac
from pathlib import Path

try:
    from Crypto.Cipher import AES
    CRYPTO_BACKEND = "pycryptodome"
except ImportError:
    try:
        from cryptography.hazmat.backends import default_backend
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        CRYPTO_BACKEND = "cryptography"
    except ImportError:
        CRYPTO_BACKEND = None


@dataclass
class Browser:
    name: str
    base: Path
    keychain_service: str
    keychain_account: str


BROWSERS = [
    Browser("Chrome", Path("~/Library/Application Support/Google/Chrome").expanduser(), "Chrome Safe Storage", "Chrome"),
    Browser("Brave", Path("~/Library/Application Support/BraveSoftware/Brave-Browser").expanduser(), "Brave Safe Storage", "Brave"),
    Browser("Arc", Path("~/Library/Application Support/Arc/User Data").expanduser(), "Arc Safe Storage", "Arc"),
    Browser("Edge", Path("~/Library/Application Support/Microsoft Edge").expanduser(), "Microsoft Edge Safe Storage", "Microsoft Edge"),
]


def fail_quietly():
    sys.exit(0)


if CRYPTO_BACKEND is None:
    print("note: install pycryptodome or cryptography to enable browser cookie discovery", file=sys.stderr)
    fail_quietly()


def profiles(browser):
    if not browser.base.exists():
        return []
    result = []
    for child in browser.base.iterdir():
        if child.name == "Default" or child.name.startswith("Profile "):
            if (child / "Cookies").exists() and (child / "History").exists():
                result.append(child)
    return result


def key_for(browser):
    password = subprocess.check_output(
        [
            "security",
            "find-generic-password",
            "-s",
            browser.keychain_service,
            "-a",
            browser.keychain_account,
            "-w",
        ],
        stderr=subprocess.DEVNULL,
    ).rstrip(b"\n")
    return pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)


def decrypt_cookie(encrypted_value, key):
    if not encrypted_value:
        return ""
    if not encrypted_value.startswith((b"v10", b"v11")):
        try:
            return encrypted_value.decode("utf-8")
        except UnicodeDecodeError:
            return ""

    encrypted_value = encrypted_value[3:]
    iv = b" " * 16
    if CRYPTO_BACKEND == "pycryptodome":
        decrypted = AES.new(key, AES.MODE_CBC, iv).decrypt(encrypted_value)
    else:
        decryptor = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend()).decryptor()
        decrypted = decryptor.update(encrypted_value) + decryptor.finalize()

    padding = decrypted[-1]
    if 1 <= padding <= 16 and decrypted.endswith(bytes([padding]) * padding):
        decrypted = decrypted[:-padding]

    if len(decrypted) > 32 and decrypted[32:].startswith(b"Fe26."):
        decrypted = decrypted[32:]
    elif len(decrypted) > 32:
        candidate = decrypted[32:]
        if all((byte >= 32 or byte in (9, 10, 13)) for byte in candidate[:16]):
            decrypted = candidate

    try:
        return decrypted.decode("utf-8")
    except UnicodeDecodeError:
        return ""


def copy_db(path):
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".db")
    tmp.close()
    shutil.copy2(path, tmp.name)
    return tmp.name


def auth_cookie(profile, key):
    tmp_path = copy_db(profile / "Cookies")
    try:
        conn = sqlite3.connect(tmp_path)
        rows = conn.execute(
            """
            SELECT encrypted_value, value
            FROM cookies
            WHERE host_key LIKE '%opencode.ai' AND name = 'auth'
            ORDER BY expires_utc DESC
            LIMIT 1
            """
        ).fetchall()
        conn.close()
    finally:
        os.unlink(tmp_path)

    if not rows:
        return ""

    encrypted_value, plain_value = rows[0]
    if plain_value:
        return plain_value
    return decrypt_cookie(encrypted_value, key)


def workspace_history(profile):
    tmp_path = copy_db(profile / "History")
    try:
        conn = sqlite3.connect(tmp_path)
        rows = conn.execute(
            """
            SELECT url, last_visit_time
            FROM urls
            WHERE url LIKE 'https://opencode.ai/workspace/%'
            ORDER BY last_visit_time DESC
            LIMIT 100
            """
        ).fetchall()
        conn.close()
    finally:
        os.unlink(tmp_path)

    seen = set()
    result = []
    for url, last_visit_time in rows:
        match = re.search(r"/workspace/(wrk_[A-Z0-9]+)", url)
        if not match:
            continue
        workspace_id = match.group(1)
        if workspace_id in seen:
            continue
        seen.add(workspace_id)
        result.append((workspace_id, last_visit_time))
    return result


all_candidates = []
for browser in BROWSERS:
    try:
        key = key_for(browser)
    except Exception:
        continue

    for profile in profiles(browser):
        try:
            cookie = auth_cookie(profile, key)
            workspaces = workspace_history(profile)
        except Exception:
            continue

        if not cookie or not workspaces:
            continue

        for workspace_id, last_visit_time in workspaces:
            all_candidates.append(
                {
                    "workspaceId": workspace_id,
                    "authCookie": cookie,
                    "source": f"Browser Cookies ({browser.name} {profile.name})",
                    "lastVisitTime": last_visit_time,
                }
            )

seen = set()
for candidate in sorted(all_candidates, key=lambda item: item["lastVisitTime"], reverse=True):
    key = (candidate["workspaceId"], candidate["authCookie"])
    if key in seen:
        continue
    seen.add(key)
    print(json.dumps(candidate, separators=(",", ":")))
PY
}

fetch_browser_dashboard_usage() {
    local candidates_file
    candidates_file="$(mktemp)"
    discover_browser_dashboard_candidates > "$candidates_file"

    if [[ ! -s "$candidates_file" ]]; then
        rm -f "$candidates_file"
        return 3
    fi

    local line
    local found_usage_json=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        WORKSPACE_ID="$(jq -r '.workspaceId // empty' <<<"$line")"
        AUTH_COOKIE="$(jq -r '.authCookie // empty' <<<"$line")"
        USAGE_CONFIG_SOURCE="$(jq -r '.source // "Browser Cookies"' <<<"$line")"

        [[ -n "$WORKSPACE_ID" && -n "$AUTH_COOKIE" ]] || continue

        local usage_json
        if usage_json="$(fetch_dashboard_usage)"; then
            found_usage_json="$(
                jq --arg source "$USAGE_CONFIG_SOURCE" '. + {_usage_source: $source}' <<<"$usage_json"
            )"
            break
        fi
    done < "$candidates_file"

    rm -f "$candidates_file"

    if [[ -n "$found_usage_json" ]]; then
        printf '%s\n' "$found_usage_json"
        return 0
    fi

    return 4
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
        if [[ -n "$usage_error" ]]; then
            echo "Reason: $usage_error"
        else
            echo "Reason: dashboard usage requires a browser login/history match, OPENCODE_GO_WORKSPACE_ID and OPENCODE_GO_AUTH_COOKIE, or ~/.config/opencode-bar/opencode-go.json."
        fi
        echo "Note: no public API-key-only usage endpoint was found for OpenCode Go."
        return
    fi

    if [[ -n "$USAGE_CONFIG_SOURCE" ]]; then
        echo "Usage source: $USAGE_CONFIG_SOURCE"
    fi
    echo "$usage_json" | jq -r '
        def pct: ((. * 100 | round) / 100 | tostring);
        .windows
        | to_entries[]
        | "\(.value.label): \(.value.usage_percent | pct)% used, \(.value.percent_remaining | pct)% left, resets in \(.value.reset_in) (\(.value.resets_at))"
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
        --arg usage_source "$USAGE_CONFIG_SOURCE" \
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
    require_command python3

    load_api_key
    load_dashboard_config

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
    if usage_json="$(fetch_dashboard_usage)"; then
        :
    else
        local status=$?
        if usage_json="$(fetch_browser_dashboard_usage)"; then
            :
        else
            local browser_status=$?
            case "$status:$browser_status" in
                3:3)
                    usage_error="Dashboard usage requires a browser login/history match, OPENCODE_GO_WORKSPACE_ID and OPENCODE_GO_AUTH_COOKIE, or ~/.config/opencode-bar/opencode-go.json."
                    ;;
                4:3|4:4)
                    usage_error="Dashboard request failed. Check workspace ID and auth cookie, or log in to opencode.ai and visit the Go dashboard once."
                    ;;
                *)
                    usage_error="$(printf '%s' "$usage_json" | jq -r '.error // "Dashboard usage parsing failed."' 2>/dev/null || true)"
                    [[ -n "$usage_error" ]] || usage_error="Dashboard usage parsing failed."
                    ;;
            esac
            usage_json=""
        fi
    fi

    if [[ -n "$usage_json" ]]; then
        local embedded_usage_source
        embedded_usage_source="$(jq -r '._usage_source // empty' <<<"$usage_json" 2>/dev/null || true)"
        if [[ -n "$embedded_usage_source" ]]; then
            USAGE_CONFIG_SOURCE="$embedded_usage_source"
            usage_json="$(jq 'del(._usage_source)' <<<"$usage_json")"
        fi
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

main "$@"
