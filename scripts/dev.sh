#!/bin/bash
# Development helper: watch swift build output, package it as an app, and relaunch automatically
# Usage: bash scripts/dev.sh
# Press ⌘B in Xcode; this script detects the new build, packages it, and relaunches the app

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXEC="$PROJECT_DIR/.build/debug/open-maestri"
APP_DIR="/tmp/maestri-app-build/open-maestri.app"
SPARKLE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

package_and_launch() {
    echo "[dev.sh] Packaging..."
    mkdir -p "$APP_DIR/Contents/MacOS"
    mkdir -p "$APP_DIR/Contents/Resources"
    mkdir -p "$APP_DIR/Contents/Frameworks"

    cp "$EXEC" "$APP_DIR/Contents/MacOS/open-maestri"
    cp "$PROJECT_DIR/Sources/Info.plist" "$APP_DIR/Contents/Info.plist"

    if [ -d "$SPARKLE" ]; then
        rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
        cp -R "$SPARKLE" "$APP_DIR/Contents/Frameworks/"
        install_name_tool -add_rpath "@executable_path/../Frameworks" \
            "$APP_DIR/Contents/MacOS/open-maestri" 2>/dev/null || true
        codesign --force --sign - "$APP_DIR/Contents/Frameworks/Sparkle.framework" 2>/dev/null
    fi

    codesign --force --sign - \
        --entitlements "$PROJECT_DIR/Sources/open-maestri.entitlements" \
        "$APP_DIR" 2>/dev/null

    # Stop the previous instance
    pkill -x "open-maestri" 2>/dev/null || true
    sleep 0.3

    echo "[dev.sh] Launching $APP_DIR"
    open "$APP_DIR"
}

echo "[dev.sh] Watching $EXEC for changes. Press Ctrl+C to stop."
echo "[dev.sh] Tip: Press ⌘B in Xcode to build, this script will auto-relaunch."

LAST_MOD=""
while true; do
    if [ -f "$EXEC" ]; then
        MOD=$(stat -f "%m" "$EXEC" 2>/dev/null)
        if [ "$MOD" != "$LAST_MOD" ]; then
            LAST_MOD="$MOD"
            package_and_launch
        fi
    fi
    sleep 1
done
