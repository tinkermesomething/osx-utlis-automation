#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="osx-utils-automation"
APP_BUNDLE="$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
APP_DST="$INSTALL_DIR/$APP_BUNDLE"
BINARY_DST="$APP_DST/Contents/MacOS/$APP_NAME"
PLIST_LABEL="com.local.$APP_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/$APP_NAME.log"

echo "==> Compiling $APP_NAME..."
swiftc -swift-version 5 \
    -framework AppKit \
    -framework IOKit \
    -framework Carbon \
    -framework Foundation \
    "$SCRIPT_DIR/Sources/main.swift" \
    "$SCRIPT_DIR/Sources/Config.swift" \
    "$SCRIPT_DIR/Sources/AppDelegate.swift" \
    "$SCRIPT_DIR/Sources/MenuBarController.swift" \
    "$SCRIPT_DIR/Sources/SettingsWindowController.swift" \
    "$SCRIPT_DIR/Sources/automations/Automation.swift" \
    "$SCRIPT_DIR/Sources/automations/KeyboardSwitcher.swift" \
    "$SCRIPT_DIR/Sources/automations/DockWatcher.swift" \
    -o "$SCRIPT_DIR/$APP_NAME"

echo "==> Building app bundle at $APP_DST"
mkdir -p "$APP_DST/Contents/MacOS"
cp "$SCRIPT_DIR/$APP_NAME"         "$BINARY_DST"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DST/Contents/"
chmod +x "$BINARY_DST"

echo "==> Installing LaunchAgent plist to $PLIST_DST"
sed \
    -e "s|BINARY_PATH_PLACEHOLDER|$BINARY_DST|g" \
    -e "s|LOG_PATH_PLACEHOLDER|$LOG_FILE|g" \
    "$SCRIPT_DIR/com.local.$APP_NAME.plist" > "$PLIST_DST"

echo "==> Loading LaunchAgent..."
# Always bootout first so plist changes (e.g. KeepAlive) are picked up.
# kickstart -k only restarts the binary; it does NOT reload the plist.
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
fi
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
echo "==> Agent loaded."

echo ""
echo "Done. App: $APP_DST"
echo "Logs: tail -f $LOG_FILE"
echo ""
echo "IMPORTANT: Grant Input Monitoring permission for the keyboard switcher:"
echo "  System Settings > Privacy & Security > Input Monitoring"
echo "  Add: $BINARY_DST"
echo "  (Use Cmd+Shift+G in the file picker to navigate to the path)"
