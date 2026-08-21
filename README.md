# Bilibili Client (macOS, SwiftUI)

一个原生的 macOS 哔哩哔哩客户端（第一版），SwiftUI 构建，采用 macOS 26 的 Liquid Glass 材质风格。

## 已实现功能

- 扫码登录（二维码生成 + 轮询确认 + Keychain 保存登录态）
- 内容流：首页推荐、分区、热门、关注动态（两列列表可选）、搜索、收藏、历史、稍后再看，全部支持滚动自动加载
- 视频详情与播放：
  - MP4 直链播放（html5 平台，无防盗链限制）
  - DASH 流自动降级：本地轻量 HTTP 代理把 DASH 分片转换成 HLS 播放，自动带上 Referer/Cookie
  - 清晰度切换；弹幕：滚动/顶部/底部、彩色，播放器右上角一键开关（记忆开关状态）
  - 全屏：AVPlayerView 系统原生全屏动画，弹幕层与弹幕开关随全屏一起显示（类似 B 站网页版全屏效果）
- 互动：评论区（含回复展开）、UP 主页与关注/取关、点赞/投币等操作
- 个人中心：用户信息、硬币数量、退出登录
- 菜单栏模式：顶部菜单栏图标弹出卡片，展示用户信息与动态，点击视频跳转主界面播放
- 设置页（系统设置风格）：外观（跟随系统/浅色/深色，Dock 图标随之切换）、列表模式、关闭窗口行为、弹幕速度等
- 动效：卡片/分区/操作按钮悬停放大反馈（系统原生导航与返回键）

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

## 已知限制

- 高清（1080P60 / 4K / HDR / 杜比）需要大会员，未做会员画质选择 UI
- 实时弹幕、直播尚未实现（接口文档已齐备，后续迭代）
- 接口为社区逆向产物，可能随 B 站风控策略变化而失效

## 免责声明

本项目仅用于个人学习与研究，接口数据版权归哔哩哔哩所有。请勿滥用接口，不要用于商业用途。
