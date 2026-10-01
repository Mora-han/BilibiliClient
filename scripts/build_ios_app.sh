#!/bin/bash
# 打包 iPadOS / iOS 版本（照 MeloX 的 build_ios_unsigned.sh 思路）。
#
#   ./scripts/build_ios_app.sh                 # 真机 arm64，产出未签名 IPA
#   ./scripts/build_ios_app.sh --simulator     # 模拟器 arm64，产出可装进 iPad/iPhone 模拟器的 .app
#   ./scripts/build_ios_app.sh debug           # debug 配置
#
# 产物（默认写 dist/ios/，不覆盖 macOS 的 dist/BilibiliClient.app）：
#   dist/ios/BilibiliClient.app                App 包
#   dist/ios/BilibiliClient-unsigned.ipa       未签名 IPA（真机构建时）
#
# 与 macOS 的 scripts/build_app.sh 完全独立：那边仍然只用 swift build 打 macOS 包，
# 本脚本不参与、也不影响 macOS 的构建、签名与发布流程。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="BilibiliClient"
PRODUCT="BilibiliClientiOS"          # Package.swift 里的 iOS executableTarget
ICON_NAME="Bilibiliclient"
ICON_SOURCE="assets/Bilibiliclient.icon"
ACTOOL="${ACTOOL:-/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool}"
VERSION="$(cat version.txt)"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

CONFIG="release"
SDK_KIND="iphoneos"
while [ $# -gt 0 ]; do
  case "$1" in
    release|debug) CONFIG="$1" ;;
    --simulator)   SDK_KIND="iphonesimulator" ;;
    -h|--help)     sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（可用：release|debug、--simulator）" >&2; exit 1 ;;
  esac
  shift
done

case "$SDK_KIND" in
  # 这里的版本必须与 Package.swift 的 `.iOS(.v26)` 以及下面 Info.plist 里的
  # MinimumOSVersion 保持一致。曾经写死成 ios27.0，导致 Mach-O 的 minos 变成
  # 27.0：包在 iOS 26 上装得上（plist 写着 26.0）却一启动就崩，报 SwiftUI 符号缺失。
  # 用新版 Xcode SDK 编译时，部署目标决定编译器走不走向后兼容路径，所以这行
  # 不该跟着 SDK 版本水涨船高。改成 26.0 后实测可在 iOS 26.5 模拟器正常运行。
  iphoneos)        TRIPLE="arm64-apple-ios26.0";            SDK_NAME="iphoneos" ;;
  iphonesimulator) TRIPLE="arm64-apple-ios26.0-simulator";  SDK_NAME="iphonesimulator" ;;
esac

# 生成构建信息（版本号单点来源：version.txt，与 macOS 侧共用同一份）
mkdir -p "Sources/BilibiliClientCore/Generated"
cat > "Sources/BilibiliClientCore/Generated/BuildInfo.generated.swift" <<SWIFT
// 由 scripts/build_app.sh / scripts/build_ios_app.sh 自动生成，请勿手改。
public enum BuildInfo {
    public static let version = "$VERSION"
    public static let build = "$BUILD"
}
SWIFT

SDKROOT_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
echo "Using SDK: $SDKROOT_PATH ($TRIPLE)"

# 注意：不要 export SDKROOT —— SwiftPM 连 manifest 都会用它编译，会被 iOS SDK 带偏。
swift build -c "$CONFIG" \
  --disable-automatic-resolution --disable-sandbox \
  --triple "$TRIPLE" --sdk "$SDKROOT_PATH" \
  --product "$PRODUCT"

BIN_PATH="$(swift build -c "$CONFIG" \
  --disable-automatic-resolution --disable-sandbox \
  --triple "$TRIPLE" --sdk "$SDKROOT_PATH" \
  --show-bin-path)/$PRODUCT"

if [ ! -x "$BIN_PATH" ]; then
  # 兜底：不同 SwiftPM 后端的产物目录略有差异
  BIN_PATH="$(find .build -type f -name "$PRODUCT" -perm -111 \
    -path "*$SDK_NAME*" -newer "version.txt" 2>/dev/null | head -1)"
fi
if [ -z "${BIN_PATH:-}" ] || [ ! -x "$BIN_PATH" ]; then
  echo "找不到 iOS 可执行产物 $PRODUCT" >&2
  exit 1
fi
echo "Binary: $BIN_PATH"

OUT_DIR="$(pwd)/dist/ios"
APP_DIR="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp "$BIN_PATH" "$APP_DIR/$APP_NAME"

# ---- 图标：沿用 macOS 的 Icon Composer 资源，actool 直接出 iOS 尺寸与 CFBundleIcons ----
ICON_BUILD_DIR="$(mktemp -d)"
"$ACTOOL" --compile "$ICON_BUILD_DIR" \
  --platform "$SDK_NAME" \
  --minimum-deployment-target 26.0 \
  --app-icon "$ICON_NAME" \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  "$ICON_SOURCE" >/dev/null
test -f "$ICON_BUILD_DIR/Assets.car"
cp "$ICON_BUILD_DIR/Assets.car" "$APP_DIR/Assets.car"
for png in "$ICON_BUILD_DIR"/*.png; do
  [ -f "$png" ] && cp "$png" "$APP_DIR/"
done

# actool 产出的 CFBundleIcons / CFBundleIcons~ipad 直接并进 Info.plist
BUNDLE_ID="${BUNDLE_ID:-com.codex.bilibili-client}"
ICON_PLIST="$ICON_BUILD_DIR/partial.plist"

python3 - "$APP_DIR/Info.plist" "$ICON_PLIST" "$VERSION" "$BUILD" "$BUNDLE_ID" "$APP_NAME" <<'PY'
import plistlib, sys

out_path, icon_plist_path, version, build, bundle_id, app_name = sys.argv[1:7]
with open(icon_plist_path, "rb") as f:
    icons = plistlib.load(f)

plist = {
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleLocalizations": ["zh-Hans"],
    "CFBundleDisplayName": "Bilibili Client",
    "CFBundleName": app_name,
    "CFBundleExecutable": app_name,
    "CFBundleIdentifier": bundle_id,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
    "CFBundleInfoDictionaryVersion": "6.0",
    "LSRequiresIPhoneOS": True,
    "MinimumOSVersion": "26.0",
    # 1=iPhone、2=iPad（MeloX 同款 1,2）
    "UIDeviceFamily": [1, 2],
    # 空启动屏：没有它会跑在兼容模式（iPhone 应用放大模式）下
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    # iPad 全方向支持，才能用 Split View / Stage Manager / 台前调度
    "UISupportedInterfaceOrientations~ipad": [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    "ITSAppUsesNonExemptEncryption": False,
    # HLSProxy 用 http://127.0.0.1 起本地代理转发 HLS，必须豁免 ATS
    "NSAppTransportSecurity": {
        "NSAllowsLocalNetworking": True,
    },
    # 下载产物写在 Documents 下（见 DownloadOptions.defaultOutputDirectory）：
    # 缺这两个键，那些 mp4 在「文件」App 里根本看不到，等于下载进了黑洞。
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
    # 后台继续播放（与 macOS 的「关闭窗口后行为」无关，是 iOS 必需的能力）
    "UIBackgroundModes": ["audio"],
}
plist.update(icons)

with open(out_path, "wb") as f:
    plistlib.dump(plist, f)
print("Wrote", out_path)
PY

# ---- 签名 ----
# 模拟器包必须 ad-hoc 签名才能装；真机 IPA 保持未签名，交给自签工具处理
# （与 MeloX 的 build_ios_unsigned.sh 一致）。
if [ "$SDK_KIND" = "iphonesimulator" ]; then
  codesign --force --sign - "$APP_DIR" 2>/dev/null || true
  echo "Signed ad-hoc (模拟器)"
else
  codesign --force --sign - "$APP_DIR" 2>/dev/null || true
fi

echo "Built: $APP_DIR"

# ---- 未签名 IPA ----
if [ "$SDK_KIND" = "iphoneos" ]; then
  STAGING="$(mktemp -d)"
  mkdir -p "$STAGING/Payload"
  ditto --norsrc "$APP_DIR" "$STAGING/Payload/$APP_NAME.app"
  IPA_PATH="$OUT_DIR/$APP_NAME-unsigned.ipa"
  rm -f "$IPA_PATH"
  ditto -c -k --norsrc --keepParent "$STAGING/Payload" "$IPA_PATH"
  rm -rf "$STAGING"
  unzip -tq "$IPA_PATH"
  ls -lh "$IPA_PATH"
  echo "Generated: $IPA_PATH"
fi
