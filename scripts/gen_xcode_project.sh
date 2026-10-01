#!/bin/bash
# 生成 `BilibiliClient.xcodeproj`（只用于在 Xcode 里连真机调试 + 签名）。
#
# 为什么需要这个脚本而不是直接 `xcodegen generate`：
# 版本号要从 `version.txt` / git 历史注入到工程设置里，避免和命令行打包的版本漂移。
#
# 改动 `project.yml` 后重新跑一次本脚本即可。工程文件本身也提交进仓库，
# 这样别人 clone 下来不需要装 xcodegen 也能直接打开。
#
# 与 `scripts/build_app.sh` / `build_ios_app.sh` 完全独立：那两条线走 `swift build`，
# 不读这个工程。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 xcodegen，请先安装：brew install xcodegen" >&2
  exit 1
fi

VERSION="$(cat version.txt)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "生成 Xcode 工程：版本 ${VERSION}（构建 ${BUILD}）"
MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" xcodegen generate

echo
echo "完成：BilibiliClient.xcodeproj"
echo "在 Xcode 里：选 scheme「BilibiliClientIOS」→ 选你的 iPad → Run"
echo "首次需要在 Xcode ▸ Settings ▸ Accounts 登录 Apple ID，自动签名才能签发 profile。"
