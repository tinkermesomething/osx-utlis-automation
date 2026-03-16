#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="osx-utils-automation"
APP_BUNDLE="$APP_NAME.app"
INSTALL_DIR="/Applications"
APP_DST="$INSTALL_DIR/$APP_BUNDLE"
BINARY_DST="$APP_DST/Contents/MacOS/$APP_NAME"
PLIST_LABEL="com.local.$APP_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_FILE="$HOME/Library/Logs/$APP_NAME.log"

echo "==> Compiling $APP_NAME..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1
cd - > /dev/null

echo "==> Building app bundle at $APP_DST"
VERSION="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
mkdir -p "$APP_DST/Contents/MacOS"
mkdir -p "$APP_DST/Contents/Resources"
cp "$SCRIPT_DIR/.build/release/$APP_NAME" "$BINARY_DST"
sed "s|VERSION_PLACEHOLDER|$VERSION|g" "$SCRIPT_DIR/Resources/Info.plist" > "$APP_DST/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_DST/Contents/Resources/AppIcon.icns"
chmod +x "$BINARY_DST"

echo "==> Installing LaunchAgent plist to $PLIST_DST"
sed \
    -e "s|BINARY_PATH_PLACEHOLDER|$BINARY_DST|g" \
    -e "s|LOG_PATH_PLACEHOLDER|$LOG_FILE|g" \
    "$SCRIPT_DIR/com.local.$APP_NAME.plist" > "$PLIST_DST"

echo "==> Loading LaunchAgent..."
# Always attempt bootout first — even if the agent appears stopped, it may be
# in a broken state (e.g. binary was deleted without a proper unload).
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
sleep 1
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
