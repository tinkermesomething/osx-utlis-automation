#!/usr/bin/env bash
# Builds the app bundle and produces:
#   dist/osx-utils-automation-{version}.pkg          (installer)
#   dist/osx-utils-automation-uninstaller-{version}.pkg  (uninstaller)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="osx-utils-automation"
PLIST_LABEL="com.local.$APP_NAME"
VERSION="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"

BINARY="$SCRIPT_DIR/.build/release/$APP_NAME"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
DIST_DIR="$SCRIPT_DIR/dist"
PKG_ROOT="$SCRIPT_DIR/pkg-root"

echo "==> Building $APP_NAME v$VERSION"

# ── 1. Compile ────────────────────────────────────────────────────────────────
echo "==> Compiling..."
swift build -c release 2>&1

# ── 2. Build app bundle ───────────────────────────────────────────────────────
echo "==> Building app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY"                                          "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Resources/AppIcon.icns"               "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
sed "s|VERSION_PLACEHOLDER|$VERSION|g" "$SCRIPT_DIR/Resources/Info.plist" > "$APP_BUNDLE/Contents/Info.plist"
# Bundle the LaunchAgent template so postinstall can find it
cp "$SCRIPT_DIR/com.local.$APP_NAME.plist"            "$APP_BUNDLE/Contents/Resources/$PLIST_LABEL.plist"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ── 3. Stage pkg root ─────────────────────────────────────────────────────────
echo "==> Staging package root..."
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_BUNDLE" "$PKG_ROOT/Applications/"

# ── 4. Build installer .pkg ───────────────────────────────────────────────────
echo "==> Building installer pkg..."
mkdir -p "$DIST_DIR"

INSTALLER_PKG="$DIST_DIR/${APP_NAME}-${VERSION}.pkg"

pkgbuild \
    --root        "$PKG_ROOT" \
    --identifier  "com.local.$APP_NAME" \
    --version     "$VERSION" \
    --install-location "/" \
    --scripts     "$SCRIPT_DIR/scripts" \
    "$INSTALLER_PKG"

# ── 5. Build uninstaller .pkg ─────────────────────────────────────────────────
echo "==> Building uninstaller pkg..."

UNINSTALL_SCRIPTS="$SCRIPT_DIR/uninstall-scripts"
rm -rf "$UNINSTALL_SCRIPTS"
mkdir -p "$UNINSTALL_SCRIPTS"
# pkgbuild requires a script named exactly "postinstall" for the uninstaller
cp "$SCRIPT_DIR/scripts/uninstall" "$UNINSTALL_SCRIPTS/postinstall"
chmod +x "$UNINSTALL_SCRIPTS/postinstall"

# Empty payload pkg — just runs the postinstall script
EMPTY_ROOT="$SCRIPT_DIR/empty-root"
rm -rf "$EMPTY_ROOT"
mkdir -p "$EMPTY_ROOT"

UNINSTALLER_PKG="$DIST_DIR/${APP_NAME}-uninstaller-${VERSION}.pkg"

pkgbuild \
    --root        "$EMPTY_ROOT" \
    --identifier  "com.local.$APP_NAME.uninstaller" \
    --version     "$VERSION" \
    --scripts     "$UNINSTALL_SCRIPTS" \
    "$UNINSTALLER_PKG"

# ── 6. Clean up temp dirs ─────────────────────────────────────────────────────
rm -rf "$PKG_ROOT" "$UNINSTALL_SCRIPTS" "$EMPTY_ROOT"

echo ""
echo "Done."
echo "  Installer:   $INSTALLER_PKG"
echo "  Uninstaller: $UNINSTALLER_PKG"
