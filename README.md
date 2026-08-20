# Bilibili Client (macOS, SwiftUI)

一个原生的 macOS 哔哩哔哩客户端（第一版），SwiftUI 构建，采用 macOS 26 的 Liquid Glass 材质风格。

## 已实现功能

- 扫码登录（二维码生成 + 轮询确认 + Keychain 保存登录态）
- 首页推荐视频流（WBI 签名 + 分页加载）
- 视频详情与播放：
  - MP4 直链播放（html5 平台，无防盗链限制）
  - DASH 流自动降级：本地轻量 HTTP 代理把 DASH 分片转换成 HLS 播放，自动带上 Referer/Cookie
  - 弹幕：支持滚动/顶部/底部弹幕、彩色弹幕，播放器右上角可一键开关（记忆开关状态）
- 关注动态流（图文、视频、转发），支持分页
- 个人中心：用户信息、退出登录

## 运行要求

- macOS 26 或更高版本
- Swift 6.2+（Xcode 26 或 Command Line Tools）

## 运行方式

方式一（命令行）：

```bash
swift run
```

方式二（Xcode）：直接打开 `Package.swift`，选择 BilibiliClient scheme 运行。

打包成 App（生成 `dist/BilibiliClient.app`）：

```bash
./scripts/build_app.sh
```

如果 Command Line Tools 的默认 SDK 与编译器版本不匹配，脚本会自动使用 `MacOSX26.5.sdk` 编译。

## 版本管理与回退

工程使用 git 做版本管理，语义化版本号（`version.txt` 单点维护），每个发布版本打一个 tag：

```bash
# 发布一个新版本
echo "0.2.0" > version.txt
./scripts/build_app.sh          # 构建 + 自动归档 dist/archive/0.2.0/
git add -A && git commit -m "release: 0.2.0"
git tag v0.2.0
```

回退到任意历史版本：

```bash
git checkout v0.1.0            # 源码回到 v0.1.0（临时查看）
git switch -c hotfix/v0.1.0 v0.1.0   # 基于旧版本开分支修 bug
```

每次构建都会在 `dist/archive/<版本>/` 生成 `BilibiliClient-v<版本>.app.zip`，
旧版 App 直接解压双击即可运行，不需要重新编译。`dist/` 与 `.build/` 已加入
`.gitignore`（构建产物不入库），版本历史通过 git 标签保存。

注意：App 的 bundle id 固定为 `com.codex.bilibili-client`，Keychain 里的登录
Cookie 在所有版本间通用，回退不会导致掉登录；如果以后改变数据结构，需要写迁移代码。

## 技术要点

- 全部使用 Web 端 REST 接口，按 [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect) 文档实现
- WBI 签名（`w_rid`/`wts`）完整实现，密钥每日缓存刷新
- Cookie 保存在 macOS Keychain
- 图片走 URLCache 磁盘缓存；列表使用 Lazy 容器，保证滚动性能

## 已知限制（第一版）

- 高清（1080P60 / 4K / HDR / 杜比）需要大会员，未做会员画质选择 UI
- 播放清晰度固定为 720P（MP4）或 DASH 最高可用非会员档
- 实时弹幕、评论、搜索、稍后再看等尚未实现（接口文档已齐备，后续迭代）
- 接口为社区逆向产物，可能随 B 站风控策略变化而失效

## 免责声明

本项目仅用于个人学习与研究，接口数据版权归哔哩哔哩所有。请勿滥用接口，不要用于商业用途。
