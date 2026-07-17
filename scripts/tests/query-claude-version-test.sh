#!/bin/bash
# Contract tests for Claude Code version detection used by query-claude.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/claude-version.sh"

TEMP_DIR="$(mktemp -d)"
FAKE_BIN="$TEMP_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf "$TEMP_DIR"' EXIT

write_fake_claude() {
    local command_body="$1"
    printf '%s\n%s\n' '#!/bin/bash' "$command_body" > "$FAKE_BIN/claude"
    chmod +x "$FAKE_BIN/claude"
}

assert_version() {
    local expected="$1"
    local description="$2"
    local actual=""
    actual="$(PATH="$FAKE_BIN:/usr/bin:/bin" resolve_claude_code_version)"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: $description (expected $expected, got $actual)" >&2
        exit 1
    fi
}

unset ANTHROPIC_CLI_VERSION

write_fake_claude 'printf "%s\n" "2.1.199 (Claude Code)"'
assert_version "2.1.199" "official Claude Code output"

write_fake_claude 'printf "%s\n" "Claude Code 2.1.199"'
assert_version "$CLAUDE_DEFAULT_CODE_VERSION" "prefixed output fallback"

write_fake_claude 'printf "2.1.199\nunexpected\n"'
assert_version "$CLAUDE_DEFAULT_CODE_VERSION" "multiline output fallback"

write_fake_claude 'printf "%s\n" "2.1.199-beta"'
assert_version "$CLAUDE_DEFAULT_CODE_VERSION" "prerelease output fallback"

write_fake_claude 'printf "%s\n" "٢.١.١٩٩"'
assert_version "$CLAUDE_DEFAULT_CODE_VERSION" "Unicode digit output fallback"

write_fake_claude 'exit 1'
assert_version "$CLAUDE_DEFAULT_CODE_VERSION" "command failure fallback"

write_fake_claude 'printf "%s\n" "2.1.199 (Claude Code)"'
ANTHROPIC_CLI_VERSION="invalid" assert_version "2.1.199" "invalid override fallback"
ANTHROPIC_CLI_VERSION="3.0.0" assert_version "3.0.0" "valid override"

echo "Claude version shell tests passed"
