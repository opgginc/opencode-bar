#!/usr/bin/env bash
# Query Grok identity, billing usage, and local session signals.
#
# Data source order:
#   1. ~/.grok/auth.json for identity (including email) and bearer token
#   2. `grok agent stdio` JSON-RPC method `x.ai/billing`
#   3. grok.com gRPC-web billing endpoint via cookie header or bearer token
#   4. ~/.grok/sessions/**/signals.json local usage signals

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Usage: scripts/${SCRIPT_NAME} [options]

Options:
  --json                    Print machine-readable JSON
  --identity-only           Read auth identity only; skip billing fetches
  --no-rpc                  Skip grok agent stdio billing
  --no-web                  Skip grok.com gRPC-web billing fallback
  --allow-browser-cookies   Import grok.com cookies from Chromium profiles
  --auth-file PATH          Read Grok auth from PATH
  --cookie-header VALUE     Cookie header for grok.com billing
  -h, --help                Show this help

Environment:
  GROK_AUTH_FILE            Grok auth file override
  GROK_HOME                 Grok home directory override, default ~/.grok
  GROK_ACCESS_TOKEN         Bearer token override for web billing
  GROK_COOKIE_HEADER        Full Cookie header for grok.com
  GROK_AUTH_COOKIE          grok.com auth cookie value; converted to "auth=..."
  CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT=1
                            Import grok.com Chromium cookies without the flag
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
done

python3 - "$@" <<'PY'
import argparse
import datetime as dt
import json
import math
import os
import re
import select
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

ENDPOINT = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
OIDC_SCOPE_PREFIX = "https://auth.x.ai::"
LEGACY_SCOPE = "https://accounts.x.ai/sign-in"


class QueryError(Exception):
    pass


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def isoformat(value):
    if value is None:
        return None
    if isinstance(value, dt.datetime):
        return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    return str(value)


def parse_datetime(raw):
    if not raw:
        return None
    if not isinstance(raw, str):
        return None
    value = raw.strip()
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


def percent_text(value):
    if value is None:
        return "unknown"
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return f"{text}% used"


def read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def first_non_empty(*values):
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def select_auth_entry(root):
    if not isinstance(root, dict):
        raise QueryError("Grok auth JSON root is not an object")

    if isinstance(root.get("key"), str) and root.get("key"):
        return "direct", root

    oidc = None
    legacy = None
    fallback = None
    for scope, entry in root.items():
        if not isinstance(entry, dict):
            continue
        if not isinstance(entry.get("key"), str) or not entry.get("key"):
            continue
        current = (scope, entry)
        if isinstance(scope, str) and scope.startswith(OIDC_SCOPE_PREFIX):
            oidc = current
        elif scope == LEGACY_SCOPE or (isinstance(scope, str) and "/sign-in" in scope):
            legacy = current
        elif fallback is None:
            fallback = current

    selected = oidc or legacy or fallback
    if selected is None:
        raise QueryError("Grok auth file exists but contains no access token")
    return selected


def resolve_auth_file(args):
    if args.auth_file:
        return Path(args.auth_file).expanduser()
    if os.environ.get("GROK_AUTH_FILE"):
        return Path(os.environ["GROK_AUTH_FILE"]).expanduser()
    grok_home = Path(os.environ.get("GROK_HOME", "~/.grok")).expanduser()
    return grok_home / "auth.json"


def load_credentials(args):
    auth_file = resolve_auth_file(args)
    if not auth_file.exists():
        raise QueryError(f"Grok auth file not found at {auth_file}. Run `grok login`.")
    if not os.access(auth_file, os.R_OK):
        raise QueryError(f"Grok auth file is not readable at {auth_file}")

    root = read_json(auth_file)
    scope, entry = select_auth_entry(root)
    expires_at = parse_datetime(entry.get("expires_at"))
    display_name = " ".join(
        part for part in [entry.get("first_name"), entry.get("last_name")]
        if isinstance(part, str) and part.strip()
    ) or None
    auth_mode = first_non_empty(entry.get("auth_mode"))
    login_method = "SuperGrok" if (auth_mode or "").lower() == "oidc" else auth_mode

    return {
        "source": str(auth_file),
        "scope": scope,
        "access_token": entry["key"],
        "refresh_token_present": bool(first_non_empty(entry.get("refresh_token"))),
        "auth_mode": auth_mode,
        "login_method": login_method,
        "email": first_non_empty(entry.get("email")),
        "team_id": first_non_empty(entry.get("team_id")),
        "user_id": first_non_empty(entry.get("user_id")),
        "display_name": display_name,
        "expires_at": isoformat(expires_at),
        "expired": bool(expires_at and utc_now() >= expires_at),
        "create_time": isoformat(parse_datetime(entry.get("create_time"))),
        "oidc_issuer": first_non_empty(entry.get("oidc_issuer")),
        "oidc_client_id": first_non_empty(entry.get("oidc_client_id")),
    }


def money_val(obj):
    if isinstance(obj, dict):
        value = obj.get("val")
        if isinstance(value, (int, float)):
            return value
    return None


def normalize_rpc_billing(result):
    usage = result.get("usage") or {}
    cycle = result.get("billingCycle") or {}
    monthly_limit = money_val(result.get("monthlyLimit"))
    total_used = money_val(usage.get("totalUsed"))
    used_percent = None
    if monthly_limit and monthly_limit > 0 and total_used is not None:
        used_percent = max(0.0, min(100.0, float(total_used) / float(monthly_limit) * 100.0))
    remaining_percent = None if used_percent is None else max(0.0, 100.0 - used_percent)
    return {
        "source": "grok agent stdio",
        "monthly_used_percent": used_percent,
        "monthly_remaining_percent": remaining_percent,
        "resets_at": cycle.get("billingPeriodEnd"),
        "billing_period_start": cycle.get("billingPeriodStart"),
        "billing_period_end": cycle.get("billingPeriodEnd"),
        "monthly_limit": monthly_limit,
        "included_used": money_val(usage.get("includedUsed")),
        "on_demand_used": money_val(usage.get("onDemandUsed")),
        "total_used": total_used,
        "disabled_by_config": result.get("disabledByConfig"),
        "on_demand_enabled": result.get("on_demand_enabled"),
    }


def json_rpc_request(proc, request_id, method, params=None, timeout=12):
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params or {},
    }
    raw = json.dumps(payload, separators=(",", ":")) + "\n"
    proc.stdin.write(raw)
    proc.stdin.flush()

    deadline = dt.datetime.now().timestamp() + timeout
    while dt.datetime.now().timestamp() < deadline:
        remaining = max(0.0, deadline - dt.datetime.now().timestamp())
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            break
        line = proc.stdout.readline()
        if not line:
            break
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("id") != request_id:
            continue
        if "error" in message:
            error = message["error"]
            if isinstance(error, dict):
                raise QueryError(error.get("message") or json.dumps(error))
            raise QueryError(str(error))
        if "result" not in message:
            raise QueryError("JSON-RPC response missing result")
        return message["result"]

    raise TimeoutError(f"`{method}` timed out")


def fetch_rpc_billing(args):
    grok_binary = shutil.which("grok")
    if not grok_binary:
        raise QueryError("grok binary not found on PATH")

    env = os.environ.copy()
    proc = subprocess.Popen(
        [grok_binary, "agent", "stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    try:
        json_rpc_request(
            proc,
            1,
            "initialize",
            {
                "protocolVersion": "1",
                "clientCapabilities": {
                    "fs": {"readTextFile": False, "writeTextFile": False},
                    "terminal": False,
                },
            },
            timeout=8,
        )
        result = json_rpc_request(proc, 2, "x.ai/billing", {}, timeout=12)
        if not isinstance(result, dict):
            raise QueryError("x.ai/billing result is not an object")
        return normalize_rpc_billing(result)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()


def grpc_web_data_frames(data):
    frames = []
    index = 0
    while index + 5 <= len(data):
        flags = data[index]
        length = int.from_bytes(data[index + 1:index + 5], "big")
        start = index + 5
        end = start + length
        if end > len(data):
            break
        if flags & 0x80 == 0:
            frames.append(data[start:end])
        index = end
    return frames


def grpc_web_trailer_fields(data):
    fields = {}
    index = 0
    while index + 5 <= len(data):
        flags = data[index]
        length = int.from_bytes(data[index + 1:index + 5], "big")
        start = index + 5
        end = start + length
        if end > len(data):
            break
        if flags & 0x80:
            text = data[start:end].decode("utf-8", errors="ignore")
            for line in re.split(r"\r?\n", text):
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                fields[key.strip().lower()] = value.strip()
        index = end
    return fields


def validate_grpc_status(data, headers):
    header_status = headers.get("grpc-status")
    if header_status and header_status != "0":
        message = urllib.parse.unquote(headers.get("grpc-message", ""))
        raise QueryError(f"gRPC status {header_status}: {message}")
    trailers = grpc_web_trailer_fields(data)
    trailer_status = trailers.get("grpc-status")
    if trailer_status and trailer_status != "0":
        message = urllib.parse.unquote(trailers.get("grpc-message", ""))
        raise QueryError(f"gRPC status {trailer_status}: {message}")


def read_varint(data, index):
    value = 0
    shift = 0
    while index < len(data) and shift < 64:
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, index
        shift += 7
    return None, index


@dataclass
class ProtoScan:
    varints: list
    fixed32: list


def scan_protobuf(data, depth=0, path=None, order=0):
    if path is None:
        path = []
    scan = ProtoScan([], [])
    index = 0
    next_order = order
    while index < len(data):
        field_start = index
        key, index = read_varint(data, index)
        if not key:
            index = field_start + 1
            continue
        field_number = key >> 3
        wire_type = key & 0x07
        field_path = path + [field_number]

        if wire_type == 0:
            value, index = read_varint(data, index)
            if value is None:
                index = field_start + 1
                continue
            scan.varints.append({"path": field_path, "value": value})
        elif wire_type == 1:
            if index + 8 > len(data):
                break
            index += 8
        elif wire_type == 2:
            length, index = read_varint(data, index)
            if length is None or length > len(data) - index:
                index = field_start + 1
                continue
            start = index
            end = index + int(length)
            if depth < 4:
                nested, next_order = scan_protobuf(data[start:end], depth + 1, field_path, next_order)
                scan.varints.extend(nested.varints)
                scan.fixed32.extend(nested.fixed32)
            index = end
        elif wire_type == 5:
            if index + 4 > len(data):
                break
            raw = data[index:index + 4]
            index += 4
            try:
                value = struct.unpack("<f", raw)[0]
            except struct.error:
                continue
            if math.isfinite(value):
                scan.fixed32.append({"path": field_path, "value": value, "order": next_order})
                next_order += 1
        else:
            index = field_start + 1
    return scan, next_order


def parse_grpc_web_billing(data):
    frames = grpc_web_data_frames(data)
    if not frames:
        raise QueryError("Grok web billing returned no protobuf data frames")

    merged = ProtoScan([], [])
    order = 0
    for frame in frames:
        scan, order = scan_protobuf(frame, order=order)
        merged.varints.extend(scan.varints)
        merged.fixed32.extend(scan.fixed32)

    candidates = [
        field for field in merged.fixed32
        if field["path"] and field["path"][-1] == 1 and 0 <= field["value"] <= 100
    ]
    candidates.sort(key=lambda field: (len(field["path"]), field["order"]))
    used_percent = float(candidates[0]["value"]) if candidates else None

    now = utc_now()
    reset_candidates = []
    for field in merged.varints:
        raw = field["value"]
        if 1_700_000_000 <= raw <= 2_100_000_000:
            date = dt.datetime.fromtimestamp(raw, dt.timezone.utc)
            if date > now:
                reset_candidates.append((field["path"], date))

    preferred_resets = [date for path, date in reset_candidates if path == [1, 5, 1]]
    all_resets = [date for _, date in reset_candidates]
    reset_at = min(preferred_resets or all_resets) if (preferred_resets or all_resets) else None

    has_local_reset_marker = any(field["path"][:2] == [1, 6] for field in merged.varints)
    if used_percent is None and not merged.fixed32 and reset_at and has_local_reset_marker:
        used_percent = 0.0
    if used_percent is None:
        raise QueryError("Could not parse Grok web billing usage")

    return {
        "source": "grok.com gRPC-web",
        "monthly_used_percent": used_percent,
        "monthly_remaining_percent": max(0.0, 100.0 - used_percent),
        "resets_at": isoformat(reset_at),
    }


def grok_cookie_from_value(value):
    if not value:
        return None
    value = value.strip()
    if not value:
        return None
    if "=" in value and (";" in value or value.startswith("auth=")):
        return value
    return f"auth={value}"


def chromium_cookie_candidates():
    browsers = [
        ("Chrome", Path("~/Library/Application Support/Google/Chrome").expanduser(), "Chrome Safe Storage", "Chrome"),
        ("Brave", Path("~/Library/Application Support/BraveSoftware/Brave-Browser").expanduser(), "Brave Safe Storage", "Brave"),
        ("Arc", Path("~/Library/Application Support/Arc/User Data").expanduser(), "Arc Safe Storage", "Arc"),
        ("Edge", Path("~/Library/Application Support/Microsoft Edge").expanduser(), "Microsoft Edge Safe Storage", "Microsoft Edge"),
    ]
    for name, base, service, account in browsers:
        if not base.exists():
            continue
        for profile in base.iterdir():
            if profile.name != "Default" and not profile.name.startswith("Profile "):
                continue
            cookies = profile / "Cookies"
            if cookies.exists():
                yield name, profile, service, account


def derive_chromium_key(service, account):
    password = subprocess.check_output(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        stderr=subprocess.DEVNULL,
    ).rstrip(b"\n")
    import hashlib
    return hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)


def decrypt_chromium_cookie(encrypted_value, key):
    if not encrypted_value:
        return ""
    if not encrypted_value.startswith((b"v10", b"v11")):
        return encrypted_value.decode("utf-8", errors="ignore")

    try:
        from Crypto.Cipher import AES
        decryptor = lambda raw: AES.new(key, AES.MODE_CBC, b" " * 16).decrypt(raw)
    except ImportError:
        try:
            from cryptography.hazmat.backends import default_backend
            from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        except ImportError:
            return ""

        def decryptor(raw):
            cipher = Cipher(algorithms.AES(key), modes.CBC(b" " * 16), backend=default_backend())
            ctx = cipher.decryptor()
            return ctx.update(raw) + ctx.finalize()

    decrypted = decryptor(encrypted_value[3:])
    if decrypted:
        padding = decrypted[-1]
        if 1 <= padding <= 16 and decrypted.endswith(bytes([padding]) * padding):
            decrypted = decrypted[:-padding]
    if len(decrypted) > 32:
        decrypted = decrypted[32:]
    return decrypted.decode("utf-8", errors="ignore")


def copy_db(path):
    temp = tempfile.NamedTemporaryFile(delete=False, suffix=".db")
    temp.close()
    shutil.copy2(path, temp.name)
    return temp.name


def browser_cookie_headers():
    for browser_name, profile, service, account in chromium_cookie_candidates():
        try:
            key = derive_chromium_key(service, account)
        except Exception:
            continue

        tmp_path = copy_db(profile / "Cookies")
        try:
            conn = sqlite3.connect(tmp_path)
            rows = conn.execute(
                """
                SELECT name, encrypted_value, value
                FROM cookies
                WHERE host_key LIKE '%grok.com%'
                ORDER BY expires_utc DESC
                """
            ).fetchall()
            conn.close()
        except Exception:
            rows = []
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

        cookies = []
        for name, encrypted_value, plain_value in rows:
            value = plain_value or decrypt_chromium_cookie(encrypted_value, key)
            if value:
                cookies.append(f"{name}={value}")
        if cookies:
            yield "; ".join(cookies), f"Browser Cookies ({browser_name} {profile.name})"


def resolve_cookie_headers(args):
    explicit = first_non_empty(args.cookie_header, os.environ.get("GROK_COOKIE_HEADER"))
    if explicit:
        return [(explicit, "GROK_COOKIE_HEADER")]
    auth_cookie = grok_cookie_from_value(os.environ.get("GROK_AUTH_COOKIE"))
    if auth_cookie:
        return [(auth_cookie, "GROK_AUTH_COOKIE")]
    if args.allow_browser_cookies or os.environ.get("CODEXBAR_ALLOW_BROWSER_COOKIE_IMPORT") == "1":
        return list(browser_cookie_headers())
    return []


def fetch_web_billing(args, credentials):
    attempts = []
    for cookie_header, source in resolve_cookie_headers(args):
        attempts.append(("cookie", cookie_header, source))

    bearer = first_non_empty(os.environ.get("GROK_ACCESS_TOKEN"), credentials.get("access_token"))
    if bearer:
        attempts.append(("bearer", f"Bearer {bearer}", "GROK_ACCESS_TOKEN" if os.environ.get("GROK_ACCESS_TOKEN") else credentials.get("source")))

    errors = []
    for kind, value, source in attempts:
        request = urllib.request.Request(
            ENDPOINT,
            data=b"\x00\x00\x00\x00\x00",
            method="POST",
            headers={
                "Origin": "https://grok.com",
                "Referer": "https://grok.com/?_s=usage",
                "Accept": "*/*",
                "Content-Type": "application/grpc-web+proto",
                "x-grpc-web": "1",
                "x-user-agent": "connect-es/2.1.1",
                "User-Agent": "OpenCode Bar query-grok.sh",
            },
        )
        if kind == "cookie":
            request.add_header("Cookie", value)
        else:
            request.add_header("Authorization", value)

        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                data = response.read()
                headers = {key.lower(): value for key, value in response.headers.items()}
                validate_grpc_status(data, headers)
                parsed = parse_grpc_web_billing(data)
                parsed["credential_source"] = source
                return parsed
        except urllib.error.HTTPError as error:
            body = error.read(400).decode("utf-8", errors="ignore")
            errors.append(f"{source}: HTTP {error.code} {body}".strip())
        except Exception as error:
            errors.append(f"{source}: {error}")

    if attempts:
        raise QueryError("; ".join(errors) if errors else "Grok web billing failed")
    raise QueryError("No grok.com cookie header found and no bearer token available")


def summarize_local_sessions(args):
    auth_file = resolve_auth_file(args)
    root = auth_file.parent / "sessions"
    cutoff = utc_now() - dt.timedelta(days=30)
    session_count = 0
    total_tokens = 0
    last_session_at = None
    model_counts = {}

    if not root.exists():
        return {
            "source": str(root),
            "lookback_days": 30,
            "session_count": 0,
            "total_tokens": 0,
            "last_session_at": None,
            "primary_model": None,
            "models": [],
        }

    for path in root.rglob("signals.json"):
        try:
            mtime = dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc)
        except OSError:
            continue
        if mtime < cutoff:
            continue
        try:
            data = read_json(path)
        except Exception:
            continue
        if not isinstance(data, dict):
            continue

        session_count += 1
        total_tokens += int(data.get("totalTokensBeforeCompaction") or 0)
        total_tokens += int(data.get("contextTokensUsed") or 0)
        if last_session_at is None or mtime > last_session_at:
            last_session_at = mtime

        primary = first_non_empty(data.get("primaryModelId"))
        if primary:
            model_counts[primary] = model_counts.get(primary, 0) + 1
        for model in data.get("modelsUsed") or []:
            if isinstance(model, str) and model.strip():
                model_counts[model.strip()] = model_counts.get(model.strip(), 0) + 1

    models = [name for name, _ in sorted(model_counts.items(), key=lambda item: item[1], reverse=True)]
    return {
        "source": str(root),
        "lookback_days": 30,
        "session_count": session_count,
        "total_tokens": total_tokens,
        "last_session_at": isoformat(last_session_at),
        "primary_model": models[0] if models else None,
        "models": models,
    }


def print_text(result):
    auth = result["auth"]
    billing = result.get("billing")
    local = result.get("local_sessions") or {}

    print("=== Grok Usage ===")
    print(f"Auth source: {auth['source']}")
    if auth.get("email"):
        print(f"Email: {auth['email']}")
    if auth.get("display_name"):
        print(f"Name: {auth['display_name']}")
    if auth.get("team_id"):
        print(f"Team ID: {auth['team_id']}")
    if auth.get("login_method"):
        print(f"Login Method: {auth['login_method']}")
    if auth.get("expires_at"):
        suffix = " (expired)" if auth.get("expired") else ""
        print(f"Token Expires: {auth['expires_at']}{suffix}")

    print("")
    if billing:
        print(f"Billing source: {billing['source']}")
        if billing.get("credential_source"):
            print(f"Credential source: {billing['credential_source']}")
        print(f"Monthly: {percent_text(billing.get('monthly_used_percent'))}")
        if billing.get("monthly_remaining_percent") is not None:
            remaining = billing["monthly_remaining_percent"]
            remaining_text = f"{remaining:.2f}".rstrip("0").rstrip(".")
            print(f"Monthly left: {remaining_text}% left")
        if billing.get("resets_at"):
            print(f"Resets At: {billing['resets_at']}")
    else:
        print("Billing: not available")
        if result.get("billing_error"):
            print(f"Reason: {result['billing_error']}")

    print("")
    print(
        "Local sessions: "
        f"{local.get('session_count', 0)} sessions, "
        f"{local.get('total_tokens', 0)} tokens"
    )
    if local.get("primary_model"):
        print(f"Primary local model: {local['primary_model']}")
    if local.get("last_session_at"):
        print(f"Last local session: {local['last_session_at']}")


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--identity-only", action="store_true")
    parser.add_argument("--no-rpc", action="store_true")
    parser.add_argument("--no-web", action="store_true")
    parser.add_argument("--allow-browser-cookies", action="store_true")
    parser.add_argument("--auth-file")
    parser.add_argument("--cookie-header")
    parser.add_argument("-h", "--help", action="store_true")
    args, unknown = parser.parse_known_args()
    if unknown:
        raise QueryError(f"Unknown option: {' '.join(unknown)}")

    credentials = load_credentials(args)
    result = {
        "provider": "grok",
        "auth": {key: value for key, value in credentials.items() if key != "access_token"},
        "billing": None,
        "billing_error": None,
        "local_sessions": summarize_local_sessions(args),
    }

    billing_errors = []
    if not args.identity_only:
        if not args.no_rpc:
            try:
                result["billing"] = fetch_rpc_billing(args)
            except Exception as error:
                billing_errors.append(f"RPC: {error}")
        if result["billing"] is None and not args.no_web:
            try:
                result["billing"] = fetch_web_billing(args, credentials)
            except Exception as error:
                billing_errors.append(f"Web: {error}")
    if result["billing"] is None and billing_errors:
        result["billing_error"] = "; ".join(billing_errors)

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print_text(result)


if __name__ == "__main__":
    try:
        main()
    except QueryError as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
PY
