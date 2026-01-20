# Copilot Monitor

<p align="center">
  <img src="docs/screenshot.jpeg" alt="Copilot Monitor Screenshot" width="480">
</p>

<p align="center">
  <strong>Monitor your GitHub Copilot premium request usage in real-time from the macOS menu bar.</strong>
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

- **Real-time Menu Bar Display**: View current usage and limits directly from the menu bar icon
- **Visual Progress Indicator**: Color changes based on usage (green → yellow → orange → red)
- **Usage History & Prediction**: Track daily usage and predict end-of-month totals with estimated costs
- **Add-on Cost Tracking**: Shows additional costs when exceeding the limit
- **Auto Refresh**: Configurable auto-update intervals from 10 seconds to 30 minutes
- **Launch at Login**: Option to automatically start on macOS login
- **GitHub OAuth Authentication**: Secure WebView-based login

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

1. **Launch the app**: Run `CopilotMonitor.app`
2. **Sign in**: Click "Sign In" from the menu and log in with your GitHub account
3. **Monitor**: Check your real-time usage from the menu bar

### Menu Options

| Menu Item | Description | Shortcut |
|-----------|-------------|----------|
| Usage History | View daily history and end-of-month predictions | - |
| Refresh | Manually refresh usage data | `⌘R` |
| Auto Refresh | Set auto-refresh interval (10s~30min) | - |
| Open Billing | Open GitHub billing page | `⌘B` |
| Launch at Login | Toggle auto-start on login | - |
| Quit | Quit the app | `⌘Q` |

### Usage History & Prediction

The app tracks your daily usage to provide smart predictions:

- **📈 Predicted EOM**: Estimates your total requests by the end of the month based on recent patterns
- **💸 Predicted Add-on**: Warns you if you're likely to exceed your plan limit and incur extra costs
- **⚙️ Prediction Period**: Configure the prediction algorithm to use the last 7, 14, or 21 days of data (weighted average)
- **Daily Log**: View your request count for the past 7 days

## How It Works

Copilot Monitor fetches usage data using GitHub's internal API:

1. **Authentication**: GitHub OAuth authentication via WebView
2. **Data Collection**: Calls the `/settings/billing/copilot_usage_card` API
3. **Caching**: Uses cached data when network errors occur

> **Note**: This app uses GitHub's internal web API, not the official GitHub API. Functionality may change based on GitHub UI updates.

## Privacy & Security

- **Local Storage**: All data is stored locally only
- **Direct Communication**: Communicates directly with GitHub servers without third-party intermediaries
- **OAuth Authentication**: Uses GitHub OAuth session without storing passwords

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
