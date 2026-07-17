#!/bin/bash
# Shared Claude Code version policy for shell diagnostics.

CLAUDE_DEFAULT_CODE_VERSION="2.1.80"

normalize_claude_code_version() {
    local raw="${1:-}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"

    [[ -n "$raw" ]] || return 1
    [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1

    if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(\ \(Claude\ Code\))?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

detect_claude_code_version() {
    local claude_bin=""
    local output=""
    claude_bin="$(command -v claude 2>/dev/null || true)"
    [[ -n "$claude_bin" ]] || return 1

    output="$("$claude_bin" --version 2>/dev/null)" || return 1
    normalize_claude_code_version "$output"
}

resolve_claude_code_version() {
    local override="${ANTHROPIC_CLI_VERSION:-}"
    local version=""

    if version="$(normalize_claude_code_version "$override")"; then
        printf '%s\n' "$version"
        return 0
    fi

    if version="$(detect_claude_code_version)"; then
        printf '%s\n' "$version"
        return 0
    fi

    printf '%s\n' "$CLAUDE_DEFAULT_CODE_VERSION"
}
