#!/bin/bash
set -e

# Install OpenCode Bar CLI to /usr/local/bin
# This script copies the CLI binary from the app bundle to /usr/local/bin

APP_PATH="/Applications/CopilotMonitor.app"
CLI_SOURCE="$APP_PATH/Contents/MacOS/opencodebar-cli"
CLI_DEST="/usr/local/bin/opencodebar"

# Verify CLI binary exists in app bundle
if [ ! -f "$CLI_SOURCE" ]; then
    echo "❌ Error: CLI binary not found at $CLI_SOURCE"
    echo "Make sure OpenCode Bar is installed in /Applications/"
    exit 1
fi

# Create /usr/local/bin if it doesn't exist
mkdir -p /usr/local/bin

# Copy CLI binary to /usr/local/bin
cp "$CLI_SOURCE" "$CLI_DEST"
chmod +x "$CLI_DEST"

echo "✅ CLI installed successfully to $CLI_DEST"
echo "Run 'opencodebar --help' to see available commands"
