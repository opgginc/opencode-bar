#!/usr/bin/env bash
# Build Token King (Release), ad-hoc sign, and install to /Applications.
# Personal fork — ad-hoc signing means Gatekeeper needs a one-time right-click-Open
# on first launch after each rebuild, but settings (UserDefaults keyed by bundle id
# com.tokenking.app) and Launch-at-Login survive rebuilds because the bundle id and
# install path are fixed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/CopilotMonitor"
SCHEME="CopilotMonitor"
APP_NAME="Token King"
DERIVED="/tmp/tk-release"
DST="/Applications/$APP_NAME.app"

echo "==> Building $APP_NAME (Release)…"
rm -rf "$DERIVED"
xcodebuild build \
  -project "$PROJECT_DIR/CopilotMonitor.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  2>&1 | tail -3

SRC="$DERIVED/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$SRC" ]; then
  echo "ERROR: build product not found at $SRC" >&2
  exit 1
fi

echo "==> Stopping running instance…"
pkill -f "${DST}/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "==> Installing to ${DST}…"
rm -rf "$DST"
cp -R "$SRC" "$DST"

echo "==> Ad-hoc re-signing at final path…"
codesign --force --deep --sign - "$DST"

echo "==> Cleaning temporary build directory to avoid duplicate Launch Services entries…"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  # Unregister the temporary build app before deleting it, then delete.
  "$LSREGISTER" -u "$SRC" 2>/dev/null || true
  "$LSREGISTER" -u "${SRC}/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
fi

rm -rf "$DERIVED"

if [ -x "$LSREGISTER" ]; then
  # Force-register the final /Applications app.
  "$LSREGISTER" -f "$DST" 2>/dev/null || true
fi

echo "==> Verifying…"
BUNDLE_ID=$(defaults read "$DST/Contents/Info.plist" CFBundleIdentifier)
echo "    bundle id : $BUNDLE_ID"
echo "    signature : $(codesign -dv "$DST" 2>&1 | grep -i '^Signature' || echo adhoc)"

echo ""
echo "Done. Launch with:  open \"$DST\""
echo "First launch after a rebuild may need: right-click the app → Open (Gatekeeper)."
