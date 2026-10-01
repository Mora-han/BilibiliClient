# Bilibili Client

一个原生哔哩哔哩客户端，使用 SwiftUI 构建，同时面向 **macOS 与 iPadOS / iOS**：
业务代码共享一份（`BilibiliClientCore`），只在真正跨不过去的平台能力处做分支。

> 当前版本：**1.7.7** · 最低系统要求：**macOS 26.0** 或 **iOS / iPadOS 26.0**

## 功能

- 扫码登录，登录状态安全保存在 macOS 钥匙串中
- 首页推荐、热门、分区、关注动态、搜索
- 收藏夹、历史记录、稍后再看
- 系统原生全屏播放与弹幕显示
- 视频/直播默认就是页面里的普通播放组件，滚动、缩放随页面自然变化；点“分离窗口”才按需创建独立窗口并把同一播放组件搬进去，关闭窗口即收回页面
- 播放画面与全屏沿用系统 `AVPlayerView`，播放控件改为自绘的液态玻璃圆角矩形控制栏：顶部一整排调进度，下面一排放播放、倍速、弹幕开关、弹幕设置、清晰度、画中画、全屏，鼠标移动时浮现、播放中闲置片刻自动收起，深浅外观随系统自适应，画面其余区域完全干净
- 全屏一律交给系统：控制栏上的全屏按钮（或双击画面）走 AVKit 原生全屏，画面从当前位置平滑放大铺满屏幕、退出缩回原位，弹幕全程跟随；控制栏在全屏里同样可用
- 分离窗口保留标准标题栏，绿色按钮与 Esc 都能进出全屏（悬停屏幕顶部即可呼出标题栏与绿键），不再出现“进了全屏出不来”
- 画面上不放多余按钮：观看人数、弹幕设置、分离窗口统一收在视频下方那一行（与清晰度切换同排）；直播的控制栏自动变体为无时间轴的简洁版
- 清晰度切换与投币、分享一样使用液态玻璃小卡片弹层，风格统一
- 进出全屏时弹幕与画面严丝合缝：缩放跟随就发生在系统重新布局播放器的那一拍里（与画面同一次 CA 事务），不做任何“追赶画面”的近似动画，因此既不抖动也不滞后；滚动/顶部与底部弹幕分别绕画面顶边、底边缩放，配合后台预热的目标尺寸位图与一帧原子重建，全程没有瞬移、闪断，文字始终清晰
- 顶部菜单栏整体汉化，并新增“播放”菜单：进入视频播放页后可直接开关弹幕、分离/吸附窗口、进出视频全屏（⌘D / ⌘⇧D / ⌘F）
- 弹幕挂在画面之上、控制栏之下，互不遮挡；空格播放/暂停、←→ 快退快进、长按 → 2 倍速等页面快捷键照旧可用
- 直播入口与直播间（热门/推荐列表、实时弹幕区）
- 点赞、投币、收藏、稍后再看、分享
- 评论、回复、UP 主主页、关注与取消关注
- 菜单栏模式常驻展示用户关注动态
- 浅色/深色/跟随系统、卡片/列表显示模式
- 原生悬停动画，支持系统“减少动态效果”

## 安装

### macOS

从 [Releases](https://github.com/Mora-han/BilibiliClient/releases) 下载 `BilibiliClient-<版本>.zip`，解压后将 App 移动到“应用程序”文件夹。

已经在用旧版本的话不用手动下载：App 内置 Sparkle 自动更新，设置页里也有「检查更新」入口。

首次使用需要自行扫码登录。登录信息仅保存在当前 Mac 的本地钥匙串中，不会随安装包分享。

### iPhone / iPad

从同一个 Releases 页面下载 `BilibiliClient-<版本>-unsigned.ipa`。

- 要求 **iOS / iPadOS 26.0** 及以上，同时支持 iPhone 与 iPad
- 这是**未签名包**，系统不会直接安装，需要用自签工具（[AltStore](https://altstore.io)、[Sideloadly](https://sideloadly.io)、TrollStore 或 Xcode）以你自己的 Apple ID 重签名后再装
- 免费 Apple ID 的签名 7 天后过期，到期重新签一次即可，数据不会丢
- iOS 版**没有应用内自动更新**（不支持 Sparkle），升级要重新下载 IPA 覆盖安装
- 功能与 macOS 版一致，播放器、导航等平台差异见下方「平台差异」

### **如果提示被系统拦截，打开系统设置，隐私与安全性，找到“安全性”，找到 BilibiliClient，点 “仍要打开”**

## 从源码运行

要求 macOS 26.0+ / iOS 26.0+、Xcode 26 或匹配版本的 Swift 工具链。

```bash
# macOS
swift run
./scripts/build_app.sh release

# iOS / iPadOS（模拟器加 --simulator；默认产出未签名 IPA）
./scripts/build_ios_app.sh --simulator debug
./scripts/build_ios_app.sh release
```

macOS 构建产物位于 `dist/`，iOS 产物位于 `dist/ios/`。

### 在 Xcode 里连真机调试

**请打开 `BilibiliClient.xcodeproj`，不要直接打开 `Package.swift`。**

包工程有两个坑，都来自「SwiftPM 的 `.executableTarget` 在真机平台只产出裸可执行文件、
不产 `.app` bundle」这一点：

1. 直接开 `Package.swift` 时默认选中的是 `BilibiliClient-Package`（聚合 scheme，构建
   所有 target）。它会尝试为 iOS 构建 macOS 专属的 `BilibiliClient`，从而把
   **Sparkle**（其 XCFramework 没有 iOS slice）拉进来，报
   `no library for this platform was found in ... Sparkle.xcframework`。
2. 就算换对 scheme，SwiftPM 也不产 `.app`，Xcode 没有可签名的对象，真机安装报
   **`The executable is not codesigned`**。`build_ios_app.sh` 是手工拼 bundle 再
   ad-hoc 签名，只够模拟器用。

`BilibiliClient.xcodeproj` 只含一个 iOS App target，引用现有源码（不复制），并且
**只依赖 `BilibiliClientCore` 这一个 product**，所以 Sparkle 根本不会进入 iOS 构建。
打开它 → scheme 选 `BilibiliClientIOS` → 选你的 iPad → Run 即可。

首次需要在 **Xcode ▸ Settings ▸ Accounts** 登录 Apple ID，自动签名才能签发
provisioning profile（只装了证书、没登录账号时会报 `No Account for Team`）。

工程由 `project.yml` 描述，改完跑：

```bash
./scripts/gen_xcode_project.sh     # 需要 brew install xcodegen
```

它会从 `version.txt` 注入版本号，避免和命令行打包的版本漂移。生成的
`BilibiliClient.xcodeproj` 也提交进仓库，因此不装 xcodegen 也能直接打开。
`build_app.sh` / `build_ios_app.sh` 走的是 `swift build`，与本工程完全无关。

## 平台差异

同一份业务代码跑在两个平台上，凡是「系统本来就长不一样」的地方按各平台惯例走；
真正的功能取舍只有下面这几条，都是明确决定过的：

| | macOS | iPadOS / iOS |
| --- | --- | --- |
| 播放器 | `AVPlayerView` + 自绘液态玻璃控制栏 | `AVPlayerViewController` **系统控制栏**（进度/倍速/全屏/画中画），不自绘 |
| 把画面带离页面 | 「分离窗口」独立窗口 | 系统**画中画** |
| 导航 | `NavigationSplitView` 侧边栏 | iPhone 底部标签栏；iPad 顶部标签栏可一键切侧边栏（Apple Music 式） |
| 登录 | 扫二维码 | 保留二维码；iPhone 上额外提示「请用另一台设备扫码」 |
| 自动更新 | Sparkle，设置里有更新入口 | 无（不做应用内更新入口） |
| 关闭窗口行为 | 菜单栏常驻 / 询问 / 完全退出 | 无此项（iOS 没有窗口与菜单栏概念） |

其余一切（首页/热门/分区/直播/动态/搜索/收藏/历史/稍后再看、弹幕、评论、UP 主、投币点赞等）两个平台完全一致。

## 技术实现

- SwiftUI、AVFoundation / AVKit 与各平台原生窗口/播放行为
- 本地 HTTP 代理将部分 DASH 分片转换为 HLS
- Bilibili Web REST API 与 WBI 签名（`w_rid` / `wts`）
- macOS Keychain Cookie（iOS 用 Keychain 同一套）、URLCache 图片缓存和 SwiftUI Lazy 容器
- Icon Composer + `actool` 编译原生 `Assets.car`

接口实现参考 [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)。

## 未来功能

- 发送弹幕，评论
- 很多还没想到的功能
- ...

## 免责声明

本项目仅用于个人学习与研究。请遵守 Bilibili 用户协议和相关法律法规，不要滥用接口或用于未经授权的商业用途。
