# Release Workflow Guide

This document describes the process for building, signing, notarizing, and releasing **OpenCode Bar** for macOS.

## Prerequisites

- **Xcode Command Line Tools**
- **Apple Developer Account** (Enrolled in Apple Developer Program)
- **Developer ID Application Certificate** installed in Keychain
- **GitHub CLI (`gh`)** installed and authenticated
- **App-Specific Password** generated from [appleid.apple.com](https://appleid.apple.com)

## 1. Version Bump

Update the marketing version and build number.

```bash
cd CopilotMonitor
agvtool new-marketing-version <NEW_VERSION>  # e.g. 1.2
agvtool next-version -all                    # Increments build number
```

Commit the version bump:

```bash
git add .
git commit -m "chore: bump version to <NEW_VERSION>"
git push origin main
```

## 2. Build Release Archive

Build the app in Release configuration.

```bash
# Clean build
xcodebuild -scheme CopilotMonitor -configuration Release clean build
```

## 3. Code Signing (Manual)

Sign the app bundle with your **Developer ID Application** certificate.

> **Note**: Replace `<TEAM_ID>` with your Team ID (e.g., `6YQH3QFFK8`).

```bash
# Define paths
APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/CopilotMonitor-*/Build/Products/Release/OpenCode Bar.app"
CERT_ID="Developer ID Application: SANG RAK CHOI (<TEAM_ID>)"

# Sign the app
codesign --force --verify --verbose --sign "$CERT_ID" --options runtime "$APP_PATH"
```

## 4. Package as DMG

Create a DMG disk image for distribution.

```bash
mkdir -p dist
cp -r "$APP_PATH" dist/
hdiutil create -volname "OpenCode Bar" -srcfolder dist -ov -format UDZO OpenCode-Bar.dmg
```

Sign the DMG file itself:

```bash
codesign --force --sign "$CERT_ID" OpenCode-Bar.dmg
```

## 5. Notarization (Crucial for Gatekeeper)

Submit the DMG to Apple's notarization service.

> **Requirement**: Create an App-Specific Password at [appleid.apple.com](https://appleid.apple.com).

```bash
# Submit for notarization
xcrun notarytool submit OpenCode-Bar.dmg \
  --apple-id "<YOUR_APPLE_ID>" \
  --password "<APP_SPECIFIC_PASSWORD>" \
  --team-id "<TEAM_ID>" \
  --wait
```

If successful (`Accepted`), staple the ticket to the DMG:

```bash
xcrun stapler staple OpenCode-Bar.dmg
```

## 6. GitHub Release

Create a release and upload the notarized DMG.

```bash
# Create tag and release
gh release create v<NEW_VERSION> --title "v<NEW_VERSION>: Release Title" --notes "Release notes here..."

# Upload the signed & notarized DMG
gh release upload v<NEW_VERSION> OpenCode-Bar.dmg --clobber
```

## Troubleshooting

### "App is damaged" Error
If notarization was skipped or failed, users can bypass Gatekeeper:
```bash
xattr -cr "/Applications/OpenCode Bar.app"
```

### Keychain Access
If `codesign` fails with authentication errors, unlock the keychain:
```bash
security unlock-keychain
```
