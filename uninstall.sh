#!/usr/bin/env bash
set -euo pipefail

APP_NAME="osx-utils-automation"
PLIST_LABEL="com.local.$APP_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
APP_DST="/Applications/$APP_NAME.app"

echo "==> Unloading LaunchAgent..."
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || \
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    echo "==> Agent unloaded."
else
    echo "==> Agent was not running."
fi

echo "==> Removing files..."
rm -f  "$PLIST_DST"
rm -rf "$APP_DST"

echo "Done."
echo "Note: remove Input Monitoring permission manually in System Settings > Privacy & Security > Input Monitoring"
