import AppKit
import SwiftUI

@main
struct BilibiliClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore.shared
    @StateObject private var router = AppRouter.shared

    init() {
        // 适中的内存/磁盘图片缓存：兼顾列表滚动流畅度与低配机器的内存占用
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 供 RootView 将主窗口代理绑定到本对象。
    static weak var shared: AppDelegate?

    private var menuBar: MenuBarController?

    /// 主窗口（Scene id “main”）。只有它套用“关闭窗口”行为；
    /// 分离播放窗口、菜单栏面板、AVKit 自建的全屏窗口都不接管。
    private weak var mainWindowRef: NSWindow?

    /// 由 RootView 在出现时调用，把主窗口交给 AppDelegate 接管。
    func adoptMainWindow(_ window: NSWindow) {
        mainWindowRef = window
        window.delegate = self
    }

    func showDockIcon() {
        NSApp.setActivationPolicy(.regular)
    }

    private func hideDockIcon() {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 先完成窗口隐藏，再切换应用类型。SwiftUI 会在关闭事件处理中短暂恢复
    /// `.regular`，因此必须在下一个主线程周期设置 `.accessory`。
    private func enterMenuBarMode(hiding window: NSWindow? = nil) {
        window?.orderOut(nil)
        NSApp.deactivate()
        DispatchQueue.main.async { [weak self] in
            guard Self.mainWindow()?.isVisible != true else { return }
            self?.hideDockIcon()
        }
    }

    /// 定位主窗口：优先用 RootView 绑定过的那一个，其次按 Scene id “main” 查找，
    /// 并排除菜单栏 popover 等 NSPanel、分离播放窗口与全屏中的窗口。
    static func mainWindow() -> NSWindow? {
        if let adopted = shared?.mainWindowRef,
           !adopted.styleMask.contains(.fullScreen),
           !Self.isPlaybackWindow(adopted) {
            return adopted
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == "main"
                && !$0.styleMask.contains(.fullScreen)
                && !Self.isPlaybackWindow($0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.setActivationPolicy(.regular)
        // 系统媒体键（F7 后退 / F8 播放暂停 / F9 前进）与“正在播放”上报
        SystemMediaCenter.shared.install()
        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar
        NSApplication.shared.activate(ignoringOtherApps: true)

        // SwiftUI 可能在创建窗口后接管 delegate，这里监听窗口成为主/关键窗口，
        // 确保关闭拦截（windowShouldClose）始终由本对象处理。
        NotificationCenter.default.addObserver(
            self, selector: #selector(reattachWindowDelegate(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reattachWindowDelegate(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )

        // 启动后延迟重挂一次：SwiftUI 创建窗口并可能接管 delegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let window = Self.mainWindow() else { return }
            self.adoptMainWindow(window)
        }
    }

    @objc private func reattachWindowDelegate(_ note: Notification) {
        // 只对主窗口重挂 delegate：菜单栏 popover 面板、分离播放窗口，以及
        // AVKit 自建的全屏窗口一律不接管——接管后者会让系统全屏窗口的关闭
        // 走成“关闭窗口”行为（隐藏窗口/弹询问），表现为退出全屏卡死。
        guard let window = note.object as? NSWindow,
              window === mainWindowRef else { return }
        window.delegate = self
    }

    /// 判断窗口是否为播放窗口（分离/全屏时的按需窗口）。
    /// 这类窗口有自己的关闭语义（关窗=画面收回页面内），不能套用主窗口的关闭拦截。
    private static func isPlaybackWindow(_ window: NSWindow) -> Bool {
        window is PlayerHostWindow
    }

    /// 关闭主窗口时按用户设置处理：完全退出 / 菜单栏模式 / 每次询问。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 只有主窗口套用“关闭窗口”行为：播放窗口的关闭由它自己处理
        // （关窗=画面收回页面内），AVKit 全屏窗口等其它窗口正常关闭。
        guard sender === mainWindowRef, !Self.isPlaybackWindow(sender) else { return true }
        switch CloseBehavior.current {
        case .quit:
            showDockIcon()
            return true
        case .menuBar:
            enterMenuBarMode(hiding: sender)
            return false
        case .ask:
            showClosePrompt(for: sender)
            return false
        }
    }

    /// 点击 Dock 图标时，若窗口被隐藏（菜单栏模式）则重新显示。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showDockIcon()
            Self.mainWindow()?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// 兜底：若窗口仍被关闭（delegate 未拦截到），按设置决定是否退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        switch CloseBehavior.current {
        case .quit:
            showDockIcon()
            return true
        case .menuBar:
            return false
        case .ask:
            showClosePromptModal()
            return false
        }
    }


    private func showClosePrompt(for window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "关闭窗口后要做什么？"
        alert.informativeText = "可以完全退出应用，或保留在菜单栏继续运行。"
        alert.addButton(withTitle: "完全退出")
        alert.addButton(withTitle: "菜单栏模式")
        let checkbox = NSButton(checkboxWithTitle: "不再询问，以后按此选择", target: nil, action: nil)
        alert.accessoryView = checkbox
        alert.beginSheetModal(for: window) { response in
            let quit = response == .alertFirstButtonReturn
            if checkbox.state == .on {
                UserDefaults.standard.set(
                    quit ? CloseBehavior.quit.rawValue : CloseBehavior.menuBar.rawValue,
                    forKey: "closeBehavior"
                )
            }
            if quit {
                self.showDockIcon()
                NSApp.terminate(nil)
            } else {
                self.enterMenuBarMode(hiding: window)
            }
        }
    }

    private func showClosePromptModal() {
        let alert = NSAlert()
        alert.messageText = "关闭窗口后要做什么？"
        alert.informativeText = "可以完全退出应用，或保留在菜单栏继续运行。"
        alert.addButton(withTitle: "完全退出")
        alert.addButton(withTitle: "菜单栏模式")
        let checkbox = NSButton(checkboxWithTitle: "不再询问，以后按此选择", target: nil, action: nil)
        alert.accessoryView = checkbox
        let response = alert.runModal()
        let quit = response == .alertFirstButtonReturn
        if checkbox.state == .on {
            UserDefaults.standard.set(
                quit ? CloseBehavior.quit.rawValue : CloseBehavior.menuBar.rawValue,
                forKey: "closeBehavior"
            )
        }
        if quit {
            showDockIcon()
            NSApp.terminate(nil)
        } else {
            enterMenuBarMode()
        }
    }
}
