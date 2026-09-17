#!/bin/bash
# Contract tests for the OpenCode Go usage-window parser in query-opencode-go.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../query-opencode-go.sh
source "$REPO_ROOT/scripts/query-opencode-go.sh"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

failures=0

assert_windows() {
    local fixture="$1"
    local jq_filter="$2"
    local expected="$3"
    local description="$4"
    local fixture_file="$TEMP_DIR/fixture.json"
    printf '%s' "$fixture" > "$fixture_file"
    local actual
    if ! actual="$(parse_go_windows "$fixture_file" | jq -c "$jq_filter")"; then
        echo "FAIL: $description (parser exited non-zero)" >&2
        failures=$((failures + 1))
        return
    fi
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $description (expected $expected, got $actual)" >&2
        failures=$((failures + 1))
    else
        echo "PASS: $description"
    fi
}

assert_parse_error() {
    local fixture="$1"
    local description="$2"
    local fixture_file="$TEMP_DIR/fixture.json"
    printf '%s' "$fixture" > "$fixture_file"
    if parse_go_windows "$fixture_file" >/dev/null 2>&1; then
        echo "FAIL: $description (expected parse failure)" >&2
        failures=$((failures + 1))
    else
        echo "PASS: $description"
    fi
}

assert_windows \
    '{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-17T05:42:46.182Z"},"weekly":{"status":"ok","percent":"8","resetsAt":"2026-09-21T00:00:00Z"},"monthly":{"status":"ok","percent":2}}}' \
    '{rolling: .windows.rolling.usage_percent, weekly: .windows.weekly.usage_percent, monthly: .windows.monthly.usage_percent, rollingReset: .windows.rolling.resets_at, weeklyReset: .windows.weekly.resets_at, monthlyReset: .windows.monthly.resets_at}' \
    '{"rolling":4,"weekly":8,"monthly":2,"rollingReset":"2026-09-17T05:42:46.182Z","weeklyReset":"2026-09-21T00:00:00Z","monthlyReset":null}' \
    "fractional/string/missing resets with neutral field names"

assert_windows \
    '{"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-17T05:42:46.182Z"}}}' \
    '.windows.rolling.field' \
    '"rolling"' \
    "api field uses neutral window name"

assert_parse_error \
    '{"usage":{"rolling":{"status":"ok","percent":true},"weekly":{"status":"expired","percent":8}}}' \
    "boolean percent and non-ok status yield no windows"

assert_parse_error \
    '{"usage":{}}' \
    "empty usage object fails"

assert_parse_error \
    '{"something":"else"}' \
    "missing usage key fails with structured error"

assert_parse_error \
    'not json' \
    "invalid JSON fails"

if (( failures > 0 )); then
    echo "$failures failure(s)" >&2
    exit 1
fi
echo "All OpenCode Go parser tests passed."
