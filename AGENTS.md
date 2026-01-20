## Language
- All of comments, commit message, PR should be in English.
- **UI Language**: All user-facing text in the app MUST be in English.

## UI Styling Rules
- **No colors for text emphasis**: Do NOT use `NSColor` attributes like `.foregroundColor` for menu items or labels.
- **Use instead**:
  - **Bold**: `NSFont.boldSystemFont(ofSize:)` for important text
  - **Underline**: `.underlineStyle: NSUnderlineStyle.single.rawValue` for critical warnings
  - **SF Symbols**: Use `NSImage(systemSymbolName:accessibilityDescription:)` for menu item icons
- **Do NOT use**:
  - **Emoji**: Never use emoji for menu item icons. Always use SF Symbols instead.
- **Exception**: Progress bars and status indicators can use color (green/yellow/orange/red).

## Requirements
- Get the data from API only, not from DOM.
- Get useful session information (cookie, bearer and etc) from DOM/HTML if needed.
- Login should be webview and ask to the user to login.

## Reference
- Copilot Usage (HTML)
  - https://github.com/settings/billing/premium_requests_usage

## Instruction
- Always compile and run again after each change, and then ask to the user to see it. (Kill the existing process before running)

## Release Policy
- **Workflow**: STRICTLY follow `docs/RELEASE_WORKFLOW.md` for versioning, building, signing, and notarizing.
- **Signing**: All DMGs distributed via GitHub Releases **MUST** be signed with Developer ID and **NOTARIZED** to pass macOS Gatekeeper.
- **Documentation**: Update `README.md` and screenshots if UI changes significantly before release.