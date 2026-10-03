import AppKit
import SwiftUI
import BilibiliClientCore

@main
struct BilibiliClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore.shared
    @StateObject private var router = AppRouter.shared

    init() {
        // 日志后端必须在任何 AppLog 调用之前装好
        AppLog.bootstrap()
        AppLog.app.info("启动", metadata: ["version": "\(BuildInfo.version)", "build": "\(BuildInfo.build)"])
        // 适中的内存/磁盘图片缓存：兼顾列表滚动流畅度与低配机器的内存占用
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)
        // 图片管线：后台解码 + 两级缓存 + 预取（见 BiliImages）
        BiliImages.install()
        // 自动更新：Sparkle 只有 macOS slice，实现挂在 macOS target 上，
        // 这里注入给共享层的 AppUpdaterStore，设置页据此显示更新区块（iOS 不注入、整块隐藏）。
        AppUpdaterStore.shared = UpdaterController.shared
    }

    var body: some Scene {
        // 使用单窗口 Window 场景：菜单栏模式下隐藏/唤回同一个窗口，
        // 避免 WindowGroup 在重新激活时额外创建新窗口导致双窗口。
        Window("Bilibili Client", id: "main") {
            RootView()
                .environmentObject(session)
                .environmentObject(router)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands { PlaybackCommands() }
        .commands { UpdaterCommands() }

        // 原生设置场景（官方做法）：独立设置窗口由系统创建与托管——
        // 窗口形态、菜单栏「设置…」、⌘, 快捷键、窗口状态管理全部与
        // Finder / Safari 一致，无需自己开 NSWindow。
        Settings {
            SystemSettingsRoot()
        }
        .commands {
            // 显式声明应用菜单的「设置…」项（官方 SettingsLink 打开上面的场景），
            // 保证菜单项与 ⌘, 一定存在、位置符合 macOS 惯例（关于之后、退出之前）。
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("设置…")
                }
                .keyboardShortcut(",")
            }
        }

        // 菜单栏图标（关掉主窗口后的唯一入口）：系统 MenuBarExtra 接替手写的
        // NSStatusItem + NSPopover —— 开合、点击外部收起、阴影与材质都交给系统。
        MenuBarExtra {
            MenuBarPanelView(session: SessionStore.shared, router: AppRouter.shared)
                .environmentObject(SessionStore.shared)
        } label: {
            Image(systemName: "play.rectangle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// 应用菜单里的"检查更新…"（放在"关于"之后，与 macOS 惯例一致）
struct UpdaterCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                UpdaterController.shared.checkForUpdates()
            }
        }
    }
}

/// 顶部菜单栏的“播放”菜单：进入视频播放页后可用。
///
/// 三个开关（弹幕 / 分离窗口 / 视频全屏）与页面上的按钮共用同一份状态，
/// 从菜单点与在页面上点完全等价。
struct PlaybackCommands: Commands {
    @ObservedObject private var state = PlaybackMenuState.shared

    var body: some Commands {
        CommandMenu("播放") {
            Button(state.danmakuEnabled ? "关闭弹幕" : "开启弹幕") {
                state.performToggleDanmaku()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!state.isActive)

            Button(state.isDetached ? "吸附回播放页" : "分离为独立窗口") {
                state.performToggleDetach()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!state.isActive)

            Divider()

            Button(state.isFullscreen ? "退出视频全屏" : "进入视频全屏") {
                state.performToggleFullscreen()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!state.hasPlayer)
        }
    }
}
