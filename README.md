# AI Usage Monitor (formerly Copilot Monitor)

<p align="center">
  <img src="docs/screenshot.jpeg" alt="AI Usage Monitor Screenshot" width="480">
</p>

<p align="center">
  <strong>Monitor multiple AI provider usage (Copilot, Claude, Codex, Gemini CLI) in real-time from the macOS menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/kargnas/copilot-usage-monitor/releases/latest">
    <img src="https://img.shields.io/github/v/release/kargnas/copilot-usage-monitor?style=flat-square" alt="Release">
  </a>
  <a href="https://github.com/kargnas/copilot-usage-monitor/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/kargnas/copilot-usage-monitor?style=flat-square" alt="License">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square" alt="Swift">
</p>

---

## Features

### Multi-Provider Support
- **4 AI Providers**: GitHub Copilot, Anthropic Claude, OpenAI Codex, Google Gemini CLI
- **Unified Dashboard**: View all providers in a single menu dropdown
- **Provider Toggle**: Enable/disable individual providers in Settings
- **Smart Categorization**: 
  - Pay-as-you-go providers (Codex) show utilization %
  - Quota-based providers (Copilot, Claude, Gemini CLI) show remaining quota %

### Monitoring & Alerts
- **Real-time Menu Bar Display**: View current usage and limits directly from the menu bar icon
- **Visual Progress Indicator**: Color changes based on usage (green → yellow → orange → red)
- **Quota Alerts**: Red-tinted icons when remaining quota <20%
- **Usage History & Prediction**: Track daily usage and predict end-of-month totals with estimated costs (Copilot only)
- **Add-on Cost Tracking**: Shows additional costs when exceeding the limit (Copilot only)

### Convenience
- **Auto Refresh**: Configurable auto-update intervals from 10 seconds to 30 minutes
- **Launch at Login**: Option to automatically start on macOS login
- **Secure Authentication**: Uses existing OpenCode auth tokens (no additional login required)

## Installation

### Download (Recommended)

Download the latest `.dmg` file from the [**Releases**](https://github.com/kargnas/copilot-usage-monitor/releases/latest) page.

> **Note**: If you see a "App is damaged" error, run this command in Terminal:
> ```bash
> xattr -cr /Applications/CopilotMonitor.app
> ```

### Build from Source (Xcode)

```bash
# Clone the repository
git clone https://github.com/kargnas/copilot-usage-monitor.git
cd copilot-usage-monitor

# Open in Xcode
open CopilotMonitor/CopilotMonitor.xcodeproj

# Build (⌘B) and Run (⌘R) in Xcode
```

### Build from Source (CLI)

For development without Xcode GUI (e.g., using VS Code, Cursor, or other editors):

```bash
# Kill existing process, build, and run
pkill -x CopilotMonitor; xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build && open ~/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Debug/CopilotMonitor.app
```

Or step by step:

```bash
# 1. Kill existing process (if running)
pkill -x CopilotMonitor

# 2. Build
xcodebuild -project CopilotMonitor/CopilotMonitor.xcodeproj -scheme CopilotMonitor -configuration Debug build

# 3. Run
open ~/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Debug/CopilotMonitor.app
```

**Requirements:**
- macOS 13.0+
- Xcode 15.0+ (Command Line Tools required)
- Swift 5.9+

## Usage

### Initial Setup

1. **Launch the app**: Run `CopilotMonitor.app`
2. **Configure providers**: 
   - For **Copilot**: Click "Sign In" and log in with your GitHub account
   - For **Claude, Codex, Gemini CLI**: Ensure you have OpenCode installed with valid auth tokens at `~/.local/share/opencode/auth.json`
3. **Enable/Disable providers**: Go to Settings → Enabled Providers and toggle providers as needed
4. **Monitor**: Check your real-time usage from the menu bar

### Menu Structure

```
─────────────────────────────
[Copilot Usage View]
─────────────────────────────
Pay-as-you-go
  Codex          45.2%
─────────────────────────────
Quota Status
  Claude         5% ⚠️
  Copilot        78%
  Gemini CLI     92%
─────────────────────────────
Usage History ▸
Sign In
Reset Login
Refresh (⌘R)
Check for Updates...
Auto Refresh ▸
Open Billing (⌘B)
─────────────────────────────
Settings
  Enabled Providers ▸
  Launch at Login
─────────────────────────────
Version X.X.X
Quit (⌘Q)
```

### Menu Options

| Menu Item | Description | Shortcut |
|-----------|-------------|----------|
| Pay-as-you-go | Shows utilization % for pay-as-you-go providers | - |
| Quota Status | Shows remaining quota % for quota-based providers | - |
| Usage History | View daily history and end-of-month predictions (Copilot only) | - |
| Refresh | Manually refresh usage data for all enabled providers | `⌘R` |
| Auto Refresh | Set auto-refresh interval (10s~30min) | - |
| Open Billing | Open GitHub billing page | `⌘B` |
| Enabled Providers | Toggle individual providers on/off | - |
| Launch at Login | Toggle auto-start on login | - |
| Quit | Quit the app | `⌘Q` |

### Usage History & Prediction

The app tracks your daily usage to provide smart predictions:

- **📈 Predicted EOM**: Estimates your total requests by the end of the month based on recent patterns
- **💸 Predicted Add-on**: Warns you if you're likely to exceed your plan limit and incur extra costs
- **⚙️ Prediction Period**: Configure the prediction algorithm to use the last 7, 14, or 21 days of data (weighted average)
- **Daily Log**: View your request count for the past 7 days

## How It Works

### Provider Data Sources

| Provider | Authentication | API Endpoint | Data Format |
|----------|---------------|--------------|-------------|
| **Copilot** | GitHub OAuth (WebView) | `/settings/billing/copilot_usage_card` | Quota-based with overage |
| **Claude** | OpenCode auth token | `https://api.anthropic.com/api/oauth/usage` | Quota-based (7-day window) |
| **Codex** | OpenCode auth token | `https://chatgpt.com/backend-api/wham/usage` | Pay-as-you-go utilization |
| **Gemini CLI** | OpenCode OAuth token | `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` | Quota-based (per-model buckets) |

### Architecture

1. **Protocol-based Design**: All providers implement `ProviderProtocol` for unified interface
2. **Parallel Fetching**: Uses Swift Concurrency to fetch all providers simultaneously (10s timeout per provider)
3. **Graceful Degradation**: Returns partial results if some providers fail
4. **Caching**: Uses cached data when network errors occur

> **Note**: This app uses internal/unofficial APIs for some providers. Functionality may change based on provider updates.

## Privacy & Security

- **Local Storage**: All data is stored locally only
- **No Third-party Servers**: Communicates directly with provider APIs
- **Token Security**: Uses existing OpenCode auth tokens (read-only access)
- **OAuth Authentication**: GitHub Copilot uses OAuth session without storing passwords

## Contributing

Contributions are welcome! Please submit a Pull Request.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

MIT License - See [LICENSE](LICENSE) file for details.

## Related

- [GitHub Copilot](https://github.com/features/copilot)
- [Copilot Billing Documentation](https://docs.github.com/en/billing/managing-billing-for-github-copilot)

---

<p align="center">
  Made with ❤️ for Copilot power users
</p>
