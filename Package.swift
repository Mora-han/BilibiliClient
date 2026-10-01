// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BilibiliClient",
    // macOS 是原有目标平台；iOS（iPhone / iPad）是新增平台，仅新增声明，
    // 不改变 macOS 侧的构建、产物与发布流程。
    platforms: [.macOS(.v26), .iOS(.v26)],
    // 显式声明产品。虽然 SwiftPM 会为每个 target 隐式生成同名产物，但 Xcode 的
    // 工程引用（`Xcode/BilibiliClient.xcodeproj` 里对 `BilibiliClientCore` 的依赖）
    // 必须能找到显式声明的 library product，否则报 "Missing package product"。
    // 对命令行 `swift build` 无影响。
    products: [
        .library(name: "BilibiliClientCore", targets: ["BilibiliClientCore"]),
        .executable(name: "BilibiliClient", targets: ["BilibiliClient"]),
        .executable(name: "BilibiliClientiOS", targets: ["BilibiliClientiOS"]),
    ],
    dependencies: [
        // 图片加载：后台解码 + 按尺寸降采样、预取、可见性优先级与取消、两级缓存
        .package(url: "https://github.com/kean/Nuke.git", from: "12.8.0"),
        // 自动更新：EdDSA 签名校验的 appcast + 增量更新（macOS 12+）
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // 富文本渲染：评论 / 动态 / 简介里的链接、@、表情按 AttributedString 排版
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.3.0"),
        // 数据结构：Deque 是真正的双端队列，直播弹幕缓冲的出队从 O(n) 降到 O(1)
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0"),
        // 日志门面：统一入口接到系统 os_log（后端见 Core/Support/Logging.swift）
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    ],
    targets: [
        // 共享层：网络、模型、会话、UI 组件与全部功能页面。macOS 与 iOS 共用同一份
        // 源码，平台差异就地用 #if os(macOS) / #if os(iOS) 分支，不复制第二棵树。
        .target(
            name: "BilibiliClientCore",
            dependencies: [
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "Textual", package: "textual"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/BilibiliClientCore"
        ),
        // macOS App（原有目标，产品名仍是 BilibiliClient，构建脚本无需改产物路径）：
        // 只放 App 入口与 Sparkle 自动更新，其余都在共享层。
        .executableTarget(
            name: "BilibiliClient",
            dependencies: [
                .target(name: "BilibiliClientCore"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BilibiliClient"
        ),
        // iOS App（iPhone / iPad）：只放 App 入口。**不能**依赖 Sparkle —— 它的
        // XCFramework 只有 macOS slice，在 iOS 上会让整个构建在规划阶段就失败。
        .executableTarget(
            name: "BilibiliClientiOS",
            dependencies: [
                .target(name: "BilibiliClientCore"),
            ],
            path: "Sources/BilibiliClientiOS"
        ),
    ],
    swiftLanguageModes: [.v5]
)
