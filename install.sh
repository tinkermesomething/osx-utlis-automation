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

echo "==> Ad-hoc signing app bundle..."
# macOS 13+ requires at least an ad-hoc signature for UNUserNotificationCenter
# to grant notification permissions. No certificate required — '-' identity signs
# the binary in-place. Without this, requestAuthorization returns UNError Code=1
# ("Notifications are not allowed for this application").
codesign --sign - --force --deep "$APP_DST"

echo "==> Installing LaunchAgent plist to $PLIST_DST"
sed \
    -e "s|BINARY_PATH_PLACEHOLDER|$BINARY_DST|g" \
    -e "s|LOG_PATH_PLACEHOLDER|$LOG_FILE|g" \
    "$SCRIPT_DIR/com.local.$APP_NAME.plist" > "$PLIST_DST"

# When run via sudo, id -u returns 0 (root) — use SUDO_UID to get the real user.
USER_UID="${SUDO_UID:-$(id -u)}"

echo "==> Registering app bundle with LaunchServices..."
# lsregister updates the LS database so the bundle ID is known to the system.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP_DST"

echo "==> Launching app once via 'open' to register with Notification Center..."
# macOS only adds an app to the NC permission database the first time it's
# launched through LaunchServices (i.e. via 'open'), not when a binary is
# exec'd directly by launchd. One short open-and-kill primes the database so
# the permission dialog appears on the next real launch.
# launchctl asuser ensures the open command runs inside the user's GUI session
# (correct bootstrap namespace) — sudo -u alone does not guarantee this.
launchctl asuser "$USER_UID" /usr/bin/open -a "$APP_DST" --background 2>/dev/null || true
sleep 3
launchctl asuser "$USER_UID" /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> Loading LaunchAgent..."
# Always attempt bootout first — even if the agent appears stopped, it may be
# in a broken state (e.g. binary was deleted without a proper unload).
launchctl bootout "gui/$USER_UID/$PLIST_LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$USER_UID" "$PLIST_DST"
echo "==> Agent loaded."

echo ""
echo "Done. App: $APP_DST"
echo "Logs: tail -f $LOG_FILE"
echo ""
echo "IMPORTANT: Grant Input Monitoring permission for the keyboard switcher:"
echo "  System Settings > Privacy & Security > Input Monitoring"
echo "  Add: $BINARY_DST"
echo "  (Use Cmd+Shift+G in the file picker to navigate to the path)"
