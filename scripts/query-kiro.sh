#!/usr/bin/env bash

# Query Kiro billing usage through the authenticated Kiro CLI.
# Authentication remains owned by Kiro; this script does not read local token databases.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<USAGE
Usage: scripts/${SCRIPT_NAME} [options]

Options:
  --json       Print machine-readable JSON
  -h, --help   Show this help

Environment:
  KIRO_CLI     Path to kiro-cli. Defaults to PATH discovery and common macOS locations.
USAGE
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
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))")

PLAN_TOTALS = {
    "free": 50.0,
    "pro": 1000.0,
    "pro+": 2000.0,
    "power": 10000.0,
}


def find_kiro_cli():
    override = os.environ.get("KIRO_CLI")
    if override and os.access(os.path.expanduser(override), os.X_OK):
        return os.path.expanduser(override)

    found = shutil.which("kiro-cli")
    if found:
        return found

    shell = os.environ.get("SHELL", "/bin/zsh")
    try:
        login_shell = subprocess.run(
            [shell, "-lc", "command -v kiro-cli 2>/dev/null"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.strip()
        if login_shell and os.access(login_shell, os.X_OK):
            return login_shell
    except Exception:
        pass

    home = str(Path.home())
    for path in [
        f"{home}/.local/bin/kiro-cli",
        "/opt/homebrew/bin/kiro-cli",
        "/usr/local/bin/kiro-cli",
        "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli",
    ]:
        if os.access(path, os.X_OK):
            return path
    raise SystemExit("kiro-cli not found. Install and sign in to Kiro CLI first.")


def clean(text):
    return ANSI_RE.sub("", text).replace("\u00a0", " ")


def parse_number(value):
    return float(value.replace(",", ""))


def normalize_plan(value):
    cleaned = re.sub(r"\s+", " ", value).strip()
    upper = cleaned.upper()
    if "POWER" in upper:
        return "Power"
    if "PRO+" in upper or "PRO PLUS" in upper:
        return "Pro+"
    if "PRO" in upper:
        return "Pro"
    if "FREE" in upper:
        return "Free"
    return cleaned or None


def parse_date(value):
    if not value:
        return None
    if "-" in value:
        return value
    parts = value.split("/")
    if len(parts) != 2:
        return None
    month, day = int(parts[0]), int(parts[1])
    today = dt.date.today()
    candidate = dt.date(today.year, month, day)
    if candidate < today:
        candidate = dt.date(today.year + 1, month, day)
    return candidate.isoformat()


def parse_usage(output):
    text = clean(output)

    plan = None
    for pattern in [
        r"Estimated\s+Usage\s*\|\s*resets\s+on\s+(?:\d{4}-\d{2}-\d{2}|\d{2}/\d{2})\s*\|\s*([A-Za-z0-9 +_-]+)",
        r"\|\s*(KIRO\s+[A-Za-z0-9 +_-]+)",
        r"Plan:\s*([A-Za-z0-9 +_-]+)(?:\s*\([^\n\r)]*\))?",
    ]:
        match = re.search(pattern, text, re.I)
        if match:
            plan = normalize_plan(re.sub(r"\s*\([^)]*\)\s*$", "", match.group(1)))
            break

    credit_match = re.search(
        r"Credits\s*\(\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s+of\s+([0-9][0-9,]*(?:\.[0-9]+)?)(?:\s+covered\s+in\s+plan)?\s*\)",
        text,
        re.I,
    )
    percent_match = re.search(r"(?:█|▓|▒|━|─|■)+\s*([0-9]+(?:\.[0-9]+)?)%", text)

    used = parse_number(credit_match.group(1)) if credit_match else None
    total = parse_number(credit_match.group(2)) if credit_match else None
    if total is None and plan:
        total = PLAN_TOTALS.get(plan.lower())
    if used is None and total is not None and percent_match:
        used = total * parse_number(percent_match.group(1)) / 100.0
    if used is None or total is None or total <= 0:
        raise SystemExit("Kiro usage output did not include monthly credit usage")

    reset_match = re.search(r"resets\s+on\s+(\d{4}-\d{2}-\d{2}|\d{2}/\d{2})", text, re.I)
    overage_match = re.search(r"Overages:\s*([A-Za-z]+)", text, re.I)
    bonus_match = re.search(
        r"Bonus\s+credits:[\s\S]{0,160}?([0-9][0-9,]*(?:\.[0-9]+)?)/([0-9][0-9,]*(?:\.[0-9]+)?)\s+credits\s+used",
        text,
        re.I,
    )
    bonus_expiry_match = re.search(r"expires\s+in\s+(\d+)\s+days?", text, re.I)

    result = {
        "provider": "kiro",
        "plan": plan,
        "used_credits": used,
        "total_credits": total,
        "remaining_credits": total - used,
        "used_percent": min(max((used / total) * 100.0, 0), 999),
        "reset_date": parse_date(reset_match.group(1)) if reset_match else None,
        "overages": overage_match.group(1) if overage_match else None,
    }
    if bonus_match:
        bonus_used = parse_number(bonus_match.group(1))
        bonus_total = parse_number(bonus_match.group(2))
        result["bonus_used_credits"] = bonus_used
        result["bonus_total_credits"] = bonus_total
        result["bonus_used_percent"] = (bonus_used / bonus_total) * 100.0 if bonus_total > 0 else None
    if bonus_expiry_match:
        result["bonus_expiry_days"] = int(bonus_expiry_match.group(1))
    return result


parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--json", action="store_true")
args = parser.parse_args(sys.argv[1:])

binary = find_kiro_cli()
proc = subprocess.run(
    [binary, "chat", "--no-interactive", "/usage"],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    timeout=25,
    check=False,
)
if proc.returncode != 0:
    raise SystemExit(proc.stdout.strip() or f"kiro-cli exited with status {proc.returncode}")

usage = parse_usage(proc.stdout)
usage["cli"] = binary

if args.json:
    print(json.dumps(usage, indent=2, sort_keys=True))
else:
    print(f"Kiro plan: {usage['plan'] or 'unknown'}")
    print(f"Credits used: {usage['used_credits']:.2f} / {usage['total_credits']:.2f} ({usage['used_percent']:.2f}% used)")
    print(f"Credits left: {usage['remaining_credits']:.2f}")
    if usage.get("reset_date"):
        print(f"Resets: {usage['reset_date']}")
    if usage.get("overages"):
        print(f"Overages: {usage['overages']}")
    if "bonus_used_credits" in usage:
        print(f"Bonus credits used: {usage['bonus_used_credits']:.2f} / {usage['bonus_total_credits']:.2f}")
    if "bonus_expiry_days" in usage:
        print(f"Bonus expires in: {usage['bonus_expiry_days']} days")
PY
