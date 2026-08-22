#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BilibiliClient"
CONFIG="${1:-release}"
VERSION="$(cat version.txt)"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ICON_SOURCE="assets/Bilibiliclient.icon"
ICON_NAME="Bilibiliclient"
ACTOOL="${ACTOOL:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool}"

# Prefer a CLT SDK that matches the installed compiler; fall back to xcrun.
if [ -z "${SDKROOT:-}" ]; then
  if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  else
    export SDKROOT="$(xcrun --show-sdk-path)"
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

if ! build_log=$(swift build -c "$CONFIG" --disable-sandbox 2>&1); then
  # 沙箱环境偶发阻止 dSYM 生成：只要 release 二进制已产出且失败点确实是 dSYM，就直接使用
  if [ "$CONFIG" = "release" ] && [ -x ".build/out/Products/Release/$APP_NAME" ] \
     && printf '%s' "$build_log" | grep -q "GenerateDSYMFile"; then
    echo "Release 二进制已生成（仅 dSYM 符号文件被环境沙箱阻止，已跳过）"
  elif [ "$CONFIG" = "release" ]; then
    echo "Release build failed, 回退到 debug 构建..."
    CONFIG="debug"
    swift build -c "$CONFIG" --disable-sandbox
  else
    printf '%s\n' "$build_log" | tail -30
    exit 1
  fi
fi

OUT_DIR="$(pwd)/dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/$CONFIG/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
# 发布 App 不需要调试符号；剥离后保留完整运行时功能并降低分发体积。
if [ "$CONFIG" = "release" ]; then
  strip -x "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi
# 使用 Icon Composer 原生资源编译流程，保留 macOS 26 的分层、明暗和材质效果。
ICON_BUILD_DIR="$(mktemp -d)"
"$ACTOOL" --compile "$ICON_BUILD_DIR" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon "$ICON_NAME" \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  "$ICON_SOURCE" >/dev/null
test -f "$ICON_BUILD_DIR/Assets.car"
cp "$ICON_BUILD_DIR/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconName</key>
    <string>${ICON_NAME}</string>
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
