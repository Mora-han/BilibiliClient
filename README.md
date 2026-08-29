# Bilibili Client

一个面向 macOS 的原生哔哩哔哩客户端，使用 SwiftUI 构建并遵循 macOS 26 设计语言。

> 当前版本：**1.1.9** · 最低系统要求：**macOS 26.0**

## 功能

- 扫码登录，登录状态安全保存在 macOS 钥匙串中
- 首页推荐、热门、分区、关注动态、搜索
- 收藏夹、历史记录、稍后再看
- 系统原生全屏播放与弹幕显示
- 点赞、投币、收藏、稍后再看、分享
- 评论、回复、UP 主主页、关注与取消关注
- 菜单栏模式常驻展示用户关注动态
- 浅色/深色/跟随系统、卡片/列表显示模式
- 原生悬停动画，支持系统“减少动态效果”

## 安装

从 [Releases](https://github.com/Mora-han/BilibiliClient/releases) 下载 `BilibiliClient-v1.1.9.app.zip`，解压后将 App 移动到“应用程序”文件夹。

首次使用需要自行扫码登录。登录信息仅保存在当前 Mac 的本地钥匙串中，不会随安装包分享。

### **如果提示被系统拦截，打开系统设置，隐私与安全性，找到”安全性"，找到 BilibiliClient，点 "仍要打开"**

## 从源码运行

要求 macOS 26.0+、Xcode 26 或匹配版本的 Swift 工具链。用 Xcode 打开 `Package.swift`，或执行：

```bash
swift run
./scripts/build_app.sh release
```

构建产物位于 `dist/`，版本归档位于 `dist/archive/<版本>/`。

## 技术实现

- SwiftUI、AVFoundation / AVKit 和原生 macOS 窗口行为
- 本地 HTTP 代理将部分 DASH 分片转换为 HLS
- Bilibili Web REST API 与 WBI 签名（`w_rid` / `wts`）
- macOS Keychain Cookie、URLCache 图片缓存和 SwiftUI Lazy 容器
- Icon Composer + `actool` 编译原生 `Assets.car`

接口实现参考 [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)。

## 未来功能

- 直播功能
- 发送弹幕，评论
- 很多还没想到的功能
- ...

## 免责声明

本项目仅用于个人学习与研究。请遵守 Bilibili 用户协议和相关法律法规，不要滥用接口或用于未经授权的商业用途。
