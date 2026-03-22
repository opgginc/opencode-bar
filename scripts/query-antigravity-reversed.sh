#!/bin/bash
# Query Antigravity usage by reverse-parsing cached protobuf from state.vscdb.
# This script does not require the local language_server process to be running.
# Auth/token fields are masked by default.

set -e

CACHE_DB="$HOME/Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
ACCOUNTS_FILE="$HOME/.config/opencode/antigravity-accounts.json"

SHOW_SECRETS="${AG_SHOW_SECRETS:-0}"
KEYCHAIN_SERVICE="${AG_KEYCHAIN_SERVICE:-}"
KEYCHAIN_ENABLED="${AG_KEYCHAIN_ENABLED:-1}"

KEYCHAIN_SERVICE_CANDIDATES=(
    "Antigravity Safe Storage"
    "Code Safe Storage"
)

OAUTH_TOKEN_BLOB=""

usage() {
    cat <<'EOF'
Usage: query-antigravity-reversed.sh [--show-secrets] [--no-keychain] [--keychain-service <service>]

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

if [[ ! -f "$CACHE_DB" ]]; then
    echo "Error: Cache DB not found at $CACHE_DB"
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "Error: sqlite3 not found"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found"
    exit 1
fi

AUTH_JSON=$(sqlite3 "$CACHE_DB" "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='antigravityAuthStatus';" 2>/dev/null || true)
if [[ -z "$AUTH_JSON" ]]; then
    echo "Error: antigravityAuthStatus not found in cache DB"
    exit 1
fi

OAUTH_TOKEN_BLOB=$(sqlite3 "$CACHE_DB" "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='antigravityUnifiedStateSync.oauthToken';" 2>/dev/null || true)
OAUTH_TOKEN_BLOB="${OAUTH_TOKEN_BLOB//$'\n'/}"
OAUTH_TOKEN_BLOB="${OAUTH_TOKEN_BLOB//$'\r'/}"

if [[ "$KEYCHAIN_ENABLED" == "1" && -z "$KEYCHAIN_SERVICE" ]]; then
    if command -v security >/dev/null 2>&1; then
        for candidate in "${KEYCHAIN_SERVICE_CANDIDATES[@]}"; do
            if security find-generic-password -s "$candidate" >/dev/null 2>&1; then
                KEYCHAIN_SERVICE="$candidate"
                break
            fi
        done
    else
        KEYCHAIN_ENABLED=0
    fi
fi

echo "=== Antigravity Reversed (Cached Proto) Usage ==="
echo ""

AUTH_JSON="$AUTH_JSON" \
CACHE_DB="$CACHE_DB" \
ACCOUNTS_FILE="$ACCOUNTS_FILE" \
SHOW_SECRETS="$SHOW_SECRETS" \
KEYCHAIN_SERVICE="$KEYCHAIN_SERVICE" \
KEYCHAIN_ENABLED="$KEYCHAIN_ENABLED" \
OAUTH_TOKEN_BLOB="$OAUTH_TOKEN_BLOB" \
python3 <<'PY'
import base64
import json
import os
import struct
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple

raw = os.environ.get("AUTH_JSON", "")
cache_db = os.environ.get("CACHE_DB", "")
accounts_file = os.environ.get("ACCOUNTS_FILE", "")
show_secrets = os.environ.get("SHOW_SECRETS", "0") == "1"
keychain_service = os.environ.get("KEYCHAIN_SERVICE", "").strip()
keychain_enabled = os.environ.get("KEYCHAIN_ENABLED", "1") == "1"
oauth_token_blob = os.environ.get("OAUTH_TOKEN_BLOB", "").strip()

if not raw:
    print("Error: empty cache payload")
    sys.exit(1)

try:
    auth = json.loads(raw)
except Exception as exc:
    print(f"Error: invalid cache JSON ({exc})")
    sys.exit(1)

b64 = auth.get("userStatusProtoBinaryBase64")
if not b64:
    print("Error: userStatusProtoBinaryBase64 missing in cache")
    sys.exit(1)

try:
    payload = base64.b64decode(b64)
except Exception as exc:
    print(f"Error: failed to decode cache base64 ({exc})")
    sys.exit(1)

def first_non_empty(values):
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""

def mask_secret(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 10:
        return "***"
    return f"{value[:6]}...{value[-4:]}"

def secret_info(value: str, source: str) -> Dict[str, Any]:
    base: Dict[str, Any] = {
        "present": bool(value),
        "length": len(value or ""),
        "masked": mask_secret(value or ""),
        "source": source
    }
    if show_secrets and value:
        base["value"] = value
    return base

def read_varint(buf, i):
    shift = 0
    value = 0
    while True:
        if i >= len(buf):
            raise ValueError("varint overflow")
        b = buf[i]
        i += 1
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            return value, i
        shift += 7
        if shift > 70:
            raise ValueError("varint too long")

def parse_msg(buf):
    i = 0
    out = {}
    while i < len(buf):
        key, i = read_varint(buf, i)
        field = key >> 3
        wt = key & 7
        if wt == 0:
            value, i = read_varint(buf, i)
        elif wt == 1:
            value = buf[i:i + 8]
            i += 8
        elif wt == 2:
            l, i = read_varint(buf, i)
            value = buf[i:i + l]
            i += l
        elif wt == 5:
            value = buf[i:i + 4]
            i += 4
        else:
            raise ValueError(f"unsupported wire type {wt}")
        out.setdefault(field, []).append((wt, value))
    return out

def decode_utf8(data):
    try:
        s = data.decode("utf-8")
        return s if any(ch.isalpha() for ch in s) else None
    except Exception:
        return None

def parse_timestamp(ts_bytes):
    try:
        m = parse_msg(ts_bytes)
        sec = m.get(1, [(0, 0)])[0][1]
        ns = m.get(2, [(0, 0)])[0][1] if 2 in m else 0
        if isinstance(sec, bytes):
            return None
        dt = datetime.fromtimestamp(sec + (ns / 1e9), tz=timezone.utc)
        return dt.isoformat().replace("+00:00", "Z")
    except Exception:
        return None

def load_accounts(path: str) -> Dict[str, Any]:
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}

def select_account(accounts_json: Dict[str, Any]) -> Tuple[Optional[int], Dict[str, Any]]:
    accounts = accounts_json.get("accounts")
    if not isinstance(accounts, list) or not accounts:
        return None, {}

    active_index = accounts_json.get("activeAccountIndex")
    if isinstance(active_index, int) and 0 <= active_index < len(accounts) and isinstance(accounts[active_index], dict):
        return active_index, accounts[active_index]

    for idx, account in enumerate(accounts):
        if not isinstance(account, dict):
            continue
        if account.get("enabled", True):
            return idx, account

    if isinstance(accounts[0], dict):
        return 0, accounts[0]

    return None, {}

def read_keychain(service: str) -> Dict[str, Any]:
    if not keychain_enabled:
        return {
            "lookupRequested": False,
            "service": service or None,
            "lookupError": None,
            "email": None,
            "token": secret_info("", "Keychain disabled")
        }

    token = ""
    email = ""
    lookup_error = None
    requested = bool(service)

    if service:
        try:
            proc = subprocess.run(
                ["security", "find-generic-password", "-s", service, "-w"],
                capture_output=True,
                text=True
            )
            if proc.returncode != 0:
                lookup_error = "not_found_or_locked"
            else:
                raw_secret = proc.stdout.strip()
                if raw_secret:
                    try:
                        parsed = json.loads(raw_secret)
                        if isinstance(parsed, dict):
                            token = first_non_empty([
                                parsed.get("refreshToken"),
                                parsed.get("refresh_token"),
                                parsed.get("token"),
                                parsed.get("apiKey"),
                                parsed.get("accessToken"),
                                parsed.get("access")
                            ])
                            email = first_non_empty([
                                parsed.get("email"),
                                parsed.get("userEmail"),
                                parsed.get("username")
                            ])
                        else:
                            token = raw_secret
                    except Exception:
                        token = raw_secret
        except FileNotFoundError:
            lookup_error = "security_binary_not_found"

    token_source = f"Keychain service: {service}" if service else "Keychain not configured"
    return {
        "lookupRequested": requested,
        "service": service or None,
        "lookupError": lookup_error,
        "email": email or None,
        "token": secret_info(token, token_source)
    }

root = parse_msg(payload)
proto_email = decode_utf8(root.get(7, [(2, b"")])[0][1]) if 7 in root else None

items = []
for wt33, v33 in root.get(33, []):
    if wt33 != 2:
        continue
    msg33 = parse_msg(v33)
    for wt1, model_blob in msg33.get(1, []):
        if wt1 != 2:
            continue
        model = parse_msg(model_blob)

        label = None
        if 1 in model and model[1][0][0] == 2:
            label = decode_utf8(model[1][0][1])
        if not label:
            continue

        remaining_fraction = None
        reset_time = None
        if 15 in model and model[15][0][0] == 2:
            quota = parse_msg(model[15][0][1])
            if 1 in quota:
                wtq, rawq = quota[1][0]
                if wtq == 5 and len(rawq) == 4:
                    remaining_fraction = struct.unpack("<f", rawq)[0]
                elif wtq == 1 and len(rawq) == 8:
                    remaining_fraction = struct.unpack("<d", rawq)[0]
            if 2 in quota and quota[2][0][0] == 2:
                reset_time = parse_timestamp(quota[2][0][1])

        if remaining_fraction is None:
            continue

        remaining_percent = int(max(0.0, min(1.0, remaining_fraction)) * 100)
        items.append({
            "label": label,
            "model": "cached-proto",
            "remaining": f"{remaining_percent}%",
            "reset": reset_time
        })

dedup = {}
for item in items:
    dedup[item["label"]] = item
models = list(dedup.values())
models.sort(key=lambda x: x["label"])

accounts_json = load_accounts(accounts_file)
account_index, account = select_account(accounts_json)
account_refresh = first_non_empty([account.get("refreshToken") if isinstance(account, dict) else ""])

cache_email = first_non_empty([auth.get("email")])
cache_name = first_non_empty([auth.get("name")])
cache_api_key = first_non_empty([auth.get("apiKey")])

final_email = first_non_empty([proto_email or "", cache_email]) or "unknown"
keychain_info = read_keychain(keychain_service)

result = {
    "email": final_email,
    "plan": "cached",
    "source": "Antigravity Cache (state.vscdb)",
    "models": models,
    "auth": {
        "cacheApiKey": secret_info(cache_api_key, f"{cache_db} key=antigravityAuthStatus.apiKey"),
        "oauthTokenBlob": secret_info(oauth_token_blob, f"{cache_db} key=antigravityUnifiedStateSync.oauthToken"),
        "refreshToken": secret_info(account_refresh, f"{accounts_file} account.refreshToken"),
        "cacheProfile": {
            "source": cache_db,
            "email": cache_email or None,
            "name": cache_name or None
        },
        "account": {
            "source": accounts_file,
            "index": account_index,
            "enabled": account.get("enabled") if isinstance(account, dict) else None,
            "email": first_non_empty([account.get("email") if isinstance(account, dict) else ""]) or None,
            "projectId": first_non_empty([account.get("projectId") if isinstance(account, dict) else ""]) or None,
            "managedProjectId": first_non_empty([account.get("managedProjectId") if isinstance(account, dict) else ""]) or None
        },
        "keychain": keychain_info
    }
}

print(json.dumps(result, ensure_ascii=False, indent=2))
PY
