# AI Usage API Reference

> AI usage API reference for OpenCode users

## Token Locations

| Provider | Token File |
|----------|-----------|
| Claude, Codex, Copilot | `~/.local/share/opencode/auth.json` |
| Antigravity (Gemini) | `~/.config/opencode/antigravity-accounts.json` |

---

## 1. Claude (Anthropic)

**Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`

```bash
ACCESS=$(jq -r '.anthropic.access' ~/.local/share/opencode/auth.json)

curl -s "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $ACCESS" \
  -H "anthropic-beta: oauth-2025-04-20"
```

**Response:**
```json
{
  "five_hour": { "utilization": 23.0, "resets_at": "2026-01-29T20:00:00Z" },
  "seven_day": { "utilization": 4.0, "resets_at": "2026-02-05T15:00:00Z" },
  "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
  "seven_day_opus": null,
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 5000,
    "used_credits": 0.0,
    "utilization": null
  }
}
```

| Field | Description |
|-------|-------------|
| `five_hour.utilization` | 5-hour window utilization (%) |
| `seven_day.utilization` | 7-day window utilization (%) |
| `extra_usage.is_enabled` | Whether extra usage is enabled |
| `extra_usage.monthly_limit` | Extra usage monthly limit in cents (e.g., `5000` = `$50.00`) |
| `extra_usage.used_credits` | Extra usage credits used this month (cents) |
| `extra_usage.utilization` | Extra usage utilization percent (nullable) |

---

## 2. Codex (OpenAI/ChatGPT)

**Endpoint:** `GET https://chatgpt.com/backend-api/wham/usage`

```bash
ACCESS=$(jq -r '.openai.access' ~/.local/share/opencode/auth.json)
ACCOUNT_ID=$(jq -r '.openai.accountId' ~/.local/share/opencode/auth.json)

curl -s "https://chatgpt.com/backend-api/wham/usage" \
  -H "Authorization: Bearer $ACCESS" \
  -H "ChatGPT-Account-Id: $ACCOUNT_ID"
```

**Response:**
```json
{
  "plan_type": "pro",
  "rate_limit": {
    "primary_window": {
      "used_percent": 9,
      "reset_after_seconds": 7252
    },
    "secondary_window": {
      "used_percent": 3,
      "reset_after_seconds": 265266
    }
  },
  "credits": { "balance": "0", "unlimited": false }
}
```

| Field | Description |
|-------|-------------|
| `primary_window.used_percent` | Primary rate limit utilization (%) |
| `secondary_window.used_percent` | Secondary rate limit utilization (%) |

---

## 3. GitHub Copilot

**Endpoint:** `GET https://api.github.com/copilot_internal/user`

```bash
ACCESS=$(jq -r '."github-copilot".access' ~/.local/share/opencode/auth.json)

curl -s "https://api.github.com/copilot_internal/user" \
  -H "Authorization: token $ACCESS" \
  -H "Accept: application/json" \
  -H "Editor-Version: vscode/1.96.2" \
  -H "X-Github-Api-Version: 2025-04-01"
```

**Response:**
```json
{
  "copilot_plan": "individual_pro",
  "quota_reset_date": "2026-02-01",
  "quota_snapshots": {
    "chat": { "entitlement": -1, "remaining": -1 },
    "completions": { "entitlement": -1, "remaining": -1 },
    "premium_interactions": { 
      "entitlement": 1500, 
      "remaining": -3821,
      "overage_permitted": true
    }
  }
}
```

| Field | Description |
|-------|-------------|
| `premium_interactions.entitlement` | Monthly premium request entitlement |
| `premium_interactions.remaining` | Remaining request count (negative = overage) |

---

## 4. Antigravity (Dual Quota System)

Antigravity has **two independent quota systems**:

| System | API | Models | Reset |
|--------|-----|--------|-------|
| **Gemini CLI** | `cloudcode-pa.googleapis.com` | gemini-2.0/2.5-flash/pro | ~17 hours |
| **Antigravity Local** | Language Server (localhost) | Claude 4.5, Gemini 3, GPT-OSS | ~7 days |

### 4a. Gemini CLI Quota

**Token:** `~/.config/opencode/antigravity-accounts.json`

**Endpoint:** `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

```bash
REFRESH=$(jq -r '.accounts[0].refreshToken' ~/.config/opencode/antigravity-accounts.json)

# Use the public Google OAuth client credentials for CLI/installed apps
# See: https://developers.google.com/identity/protocols/oauth2/native-app
ACCESS=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
  -d "client_id=$GEMINI_CLIENT_ID" \
  -d "client_secret=$GEMINI_CLIENT_SECRET" \
  -d "refresh_token=$REFRESH" \
  -d "grant_type=refresh_token" | jq -r '.access_token')

curl -s -X POST "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota" \
  -H "Authorization: Bearer $ACCESS" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response:**
```json
{
  "buckets": [
    { "modelId": "gemini-2.0-flash", "remainingFraction": 1, "resetTime": "2026-01-30T17:05:02Z" },
    { "modelId": "gemini-2.5-flash", "remainingFraction": 1, "resetTime": "2026-01-30T17:05:02Z" },
    { "modelId": "gemini-2.5-pro", "remainingFraction": 0.85, "resetTime": "2026-01-30T17:05:02Z" }
  ]
}
```

### 4b. Antigravity Local Quota (Language Server)

**Requires:** Antigravity app running

**Endpoint:** `POST http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus`

```bash
# 1. Find language_server process and extract CSRF token
PROCESS=$(ps -ax -o pid=,command= | grep language_server_macos | grep antigravity | head -1)
PID=$(echo "$PROCESS" | awk '{print $1}')
CSRF=$(echo "$PROCESS" | grep -oE '\-\-csrf_token[= ]+[^ ]+' | sed 's/--csrf_token[= ]*//')

# 2. Find listening ports
PORTS=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PID" | grep -oE ':[0-9]+' | sed 's/://' | sort -u)

# 3. Call API (try each port)
for port in $PORTS; do
  curl -s -k -X POST "https://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/GetUserStatus" \
    -H "Content-Type: application/json" \
    -H "Connect-Protocol-Version: 1" \
    -H "X-Codeium-Csrf-Token: $CSRF" \
    -d '{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}' && break
done
```

**Response:**
```json
{
  "userStatus": {
    "email": "user@example.com",
    "userTier": { "name": "Free" },
    "cascadeModelConfigData": {
      "clientModelConfigs": [
        {
          "label": "Claude Sonnet 4.5",
          "modelOrAlias": { "model": "MODEL_CLAUDE_4_5_SONNET" },
          "quotaInfo": { "remainingFraction": 0.85, "resetTime": "2026-02-05T17:11:17Z" }
        },
        {
          "label": "Gemini 3 Pro (High)",
          "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M8" },
          "quotaInfo": { "remainingFraction": 1, "resetTime": "2026-02-05T17:11:17Z" }
        }
      ]
    }
  }
}
```

---

## OAuth Credentials

### Anthropic (Claude)
```
# Public OAuth client ID - extracted from official Claude Code CLI
# This is NOT a secret - it's embedded in the public CLI binary
Client ID: 9d1c250a-e61b-44d9-88ed-5944d1962f5e
```

### OpenAI (Codex)
```
# Public OAuth client ID - extracted from official Codex CLI
# This is NOT a secret - it's embedded in the public CLI binary
Client ID: app_EMoamEEZ73f0CkXaXp7hrann
```

### Antigravity
```
# Public Google OAuth client for CLI/installed apps
# These are NOT secrets - see https://developers.google.com/identity/protocols/oauth2/native-app
Client ID:     Set GEMINI_CLIENT_ID environment variable
Client Secret: Set GEMINI_CLIENT_SECRET environment variable
```

---

## Token File Structures

### OpenCode Auth (`~/.local/share/opencode/auth.json`)

```json
{
  "anthropic": {
    "type": "oauth",
    "access": "sk-ant-oat01-...",
    "refresh": "sk-ant-ort01-...",
    "expires": 1769729563641
  },
  "openai": {
    "type": "oauth",
    "access": "eyJ...",
    "refresh": "rt_...",
    "expires": 1770563557150,
    "accountId": "uuid"
  },
  "github-copilot": {
    "type": "oauth",
    "access": "gho_...",
    "refresh": "gho_...",
    "expires": 0
  }
}
```

### Antigravity Accounts (`~/.config/opencode/antigravity-accounts.json`)

```json
{
  "version": 3,
  "accounts": [
    {
      "email": "user@example.com",
      "refreshToken": "1//...",
      "projectId": "project-id",
      "rateLimitResetTimes": {
        "claude": 1769094487111,
        "gemini-cli:gemini-3-flash-preview": 1769700023092,
        "gemini-antigravity:antigravity-gemini-3-flash": 1768908899182
      }
    }
  ],
  "activeIndex": 0
}
```

---

## Scripts

Test scripts are located in the `scripts/` folder:

| Script | Provider |
|--------|----------|
| `query-claude.sh` | Claude (Anthropic) |
| `query-codex.sh` | Codex (OpenAI) |
| `query-copilot.sh` | GitHub Copilot |
| `query-gemini-cli.sh` | Antigravity - Gemini CLI quota |
| `query-gemini-oauth-creds.sh` | Gemini CLI oauth_creds identity/token inspection |
| `query-antigravity-local.sh` | Antigravity - Local quota |
| `query-all.sh` | All providers |

```bash
./scripts/query-all.sh
```

---

## Swift Implementation Example

```swift
import Foundation

// OpenCode Auth (Claude, Codex, Copilot)
struct OpenCodeAuth: Codable {
    struct OAuth: Codable {
        let type: String
        let access: String
        let refresh: String
        let expires: Int64
        let accountId: String?
    }
    
    let anthropic: OAuth?
    let openai: OAuth?
    let githubCopilot: OAuth?
    
    enum CodingKeys: String, CodingKey {
        case anthropic, openai
        case githubCopilot = "github-copilot"
    }
}

// Antigravity Accounts
struct AntigravityAccounts: Codable {
    struct Account: Codable {
        let email: String
        let refreshToken: String
        let projectId: String
        let rateLimitResetTimes: [String: Int64]?
    }
    
    let version: Int
    let accounts: [Account]
    let activeIndex: Int
}

// Load functions
func loadOpenCodeAuth() -> OpenCodeAuth? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")
    guard let data = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(OpenCodeAuth.self, from: data)
}

func loadAntigravityAccounts() -> AntigravityAccounts? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/opencode/antigravity-accounts.json")
    guard let data = try? Data(contentsOf: path) else { return nil }
    return try? JSONDecoder().decode(AntigravityAccounts.self, from: data)
}
```

---

## References

- [CodexBar](https://github.com/steipete/CodexBar) - macOS menu bar app for AI usage tracking
- [opencode-antigravity-auth](https://github.com/NoeFabris/opencode-antigravity-auth) - OpenCode Antigravity plugin
- [AntigravityQuotaWatcher](https://github.com/wusimpl/AntigravityQuotaWatcher) - Antigravity quota monitoring
