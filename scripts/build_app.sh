#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BilibiliClient"
CONFIG="${1:-release}"
VERSION="$(cat version.txt)"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# Prefer a CLT SDK that matches the installed compiler; fall back to xcrun.
if [ -z "${SDKROOT:-}" ]; then
  if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  else
    SDKROOT="$(xcrun --show-sdk-path)"
  fi
fi

echo "Using SDK: $SDKROOT"

# 生成构建信息（版本号单点来源：version.txt）
mkdir -p "Sources/BilibiliClient/Support"
cat > "Sources/BilibiliClient/Support/BuildInfo.generated.swift" <<SWIFT
// 由 scripts/build_app.sh 自动生成，请勿手改。
enum BuildInfo {
    static let version = "$VERSION"
    static let build = "$BUILD"
}
SWIFT

if ! swift build -c "$CONFIG" --disable-sandbox; then
  if [ "$CONFIG" = "release" ]; then
    echo "Release build failed (环境沙箱可能阻止 dSYM 生成), 回退到 debug 构建..."
    CONFIG="debug"
    swift build -c "$CONFIG" --disable-sandbox
  else
    exit 1
  fi
fi

OUT_DIR="$(pwd)/dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/$CONFIG/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BilibiliClient</string>
    <key>CFBundleIdentifier</key>
    <string>com.codex.bilibili-client</string>
    <key>CFBundleName</key>
    <string>Bilibili Client</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR" 2>/dev/null || true
echo "Built: $APP_DIR"

# 按版本归档，方便直接回退到任意历史版本
ARCHIVE_DIR="dist/archive/$VERSION"
mkdir -p "$ARCHIVE_DIR"
ARCHIVE="$ARCHIVE_DIR/$APP_NAME-v$VERSION.app.zip"
ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE"
echo "Archived: $ARCHIVE"
