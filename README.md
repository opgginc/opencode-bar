# Copilot Monitor

<p align="center">
  <img src="docs/screenshot.png" alt="Copilot Monitor Screenshot" width="480">
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
- **Add-on Cost Tracking**: Shows additional costs when exceeding the limit
- **Auto Refresh**: Configurable auto-update intervals from 10 seconds to 30 minutes
- **Launch at Login**: Option to automatically start on macOS login
- **GitHub OAuth Authentication**: Secure WebView-based login

## Installation

### Download (Recommended)

Download the latest `.dmg` file from the [**Releases**](https://github.com/kargnas/copilot-usage-monitor/releases/latest) page.

### Build from Source

```bash
# Clone the repository
git clone https://github.com/kargnas/copilot-usage-monitor.git
cd copilot-usage-monitor

# Open in Xcode
open CopilotMonitor/CopilotMonitor.xcodeproj

# Build (⌘B) and Run (⌘R) in Xcode
```

**Requirements:**
- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+

## Usage

1. **Launch the app**: Run `CopilotMonitor.app`
2. **Sign in**: Click "Sign In" from the menu and log in with your GitHub account
3. **Monitor**: Check your real-time usage from the menu bar

### Menu Options

| Menu Item | Description | Shortcut |
|-----------|-------------|----------|
| Refresh | Manually refresh usage data | `⌘R` |
| Auto Refresh | Set auto-refresh interval (10s~30min) | - |
| Open Billing | Open GitHub billing page | `⌘B` |
| Launch at Login | Toggle auto-start on login | - |
| Quit | Quit the app | `⌘Q` |

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
