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
mkdir -p "Sources/BilibiliClient/Core/Generated"
cat > "Sources/BilibiliClient/Core/Generated/BuildInfo.generated.swift" <<SWIFT
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
    <!-- 声明为简体中文 App：系统提供的菜单（编辑/显示/窗口/帮助等）随之汉化 -->
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
    </array>
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

# 签名身份优先用固定的开发证书，而不是 ad-hoc。
# 原因：ad-hoc 签名的「设计要求」就是 cdhash，而 cdhash 每次编译都会变，
# macOS 因此把每个新构建都当成另一个 App —— 登录 cookie 存在钥匙串里，
# 于是每编译运行一次就弹一次钥匙串授权框。换成固定证书后该要求稳定在
# identifier + 证书主体上，授权过第一次之后就不再打扰。
# 可用 SIGN_IDENTITY=... 覆盖；找不到证书时退回 ad-hoc（功能不受影响）。
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"\(Apple Development\|Developer ID Application\|Mac Developer\)[^"]*"' \
    | head -1 | tr -d '"')"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null \
    || codesign --force --sign - "$APP_DIR" 2>/dev/null || true
  echo "Signed with: $SIGN_IDENTITY"
else
  codesign --force --sign - "$APP_DIR" 2>/dev/null || true
  echo "Signed ad-hoc (未找到开发证书)"
fi
echo "Built: $APP_DIR"

# 历史版本归档：默认不做。任何版本都能用
#   git checkout vX.Y.Z && NO_OPEN=1 ./scripts/build_app.sh release
# 原样重建出来（实测约 20 秒），本地再堆一份 .app zip 只会白占空间；
# 正式发布的版本由 GitHub Releases 留存。需要临时留档时设 KEEP_ARCHIVE=1。
if [ "${KEEP_ARCHIVE:-0}" = "1" ]; then
  ARCHIVE_DIR="dist/archive/$VERSION"
  mkdir -p "$ARCHIVE_DIR"
  ARCHIVE="$ARCHIVE_DIR/$APP_NAME-v$VERSION.app.zip"
  ditto -c -k --keepParent "$APP_DIR" "$ARCHIVE"
  echo "Archived: $ARCHIVE"
else
  echo "Skipped archive (KEEP_ARCHIVE=1 可保留一份本地归档)"
fi

# 编译完成后自动打开最新的 App 方便查看（设 NO_OPEN=1 可跳过）。
# 先结束正在运行的旧实例，确保打开的是本次编译产物而不是旧二进制。
if [ "${NO_OPEN:-0}" != "1" ]; then
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP_DIR"
  echo "Opened: $APP_DIR"
fi
