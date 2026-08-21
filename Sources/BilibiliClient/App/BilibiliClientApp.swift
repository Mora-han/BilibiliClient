import AppKit
import SwiftUI

@main
struct BilibiliClientApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = SessionStore.shared
    @StateObject private var router = AppRouter.shared

    init() {
        // 适中的内存/磁盘图片缓存：兼顾列表滚动流畅度与低配机器的内存占用
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.setActivationPolicy(.regular)
        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 关闭主窗口时按用户设置处理：完全退出 / 菜单栏模式 / 每次询问。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch CloseBehavior.current {
        case .quit:
            return true
        case .menuBar:
            sender.orderOut(nil)
            return false
        case .ask:
            showClosePrompt(for: sender)
            return false
        }
    }

    /// 点击 Dock 图标时，若窗口被隐藏（菜单栏模式）则重新显示。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
                NSApp.terminate(nil)
            } else {
                window.orderOut(nil)
            }
        }
    }
}
