import AppKit
import SwiftUI

/// 播放窗口（普通窗口）：只有点“分离窗口”时才按需创建，
/// 窗口里装的就是页面里同一个播放组件，不再有常驻钉位的特殊窗口。
final class PlayerHostWindow: NSWindow {
    /// 无边框窗口默认不能成为 key 窗口，收不到键盘事件
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 播放窗口的创建/销毁/分离状态管理。
///
/// 页面默认把播放组件放在页内；`present(frame:...)` 时窗口覆盖在画面所在
/// 位置并把组件搬进窗口，`close()` 后组件自动回到页面内——因此窗口只在
/// 真正需要的时候存在。
///
/// 全屏一律交给系统：窗口保留标准标题栏，点绿色按钮走 AppKit 原生全屏
/// （悬停顶部呼出标题栏、绿键退出、Esc 退出都由系统提供），AVKit 控件条里
/// 的全屏按钮则由 `AVPlayerView` 负责。这里不再自绘任何全屏动画。
@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    /// 窗口当前是否存在（存在 = 播放画面已从页面移入窗口）
    @Published private(set) var isOpen = false
    /// 是否为用户手动分离出来的独立窗口
    @Published private(set) var isDetached = false

    /// 用户主动关闭窗口（红点 / Cmd+W / 关闭按钮）时回调，页面据此把画面收回页内
    var onCloseRequested: (() -> Void)?

    private var window: PlayerHostWindow?
    private var observers: [NSObjectProtocol] = []

    /// 创建分离窗口并把播放组件搬进窗口。frame 为屏幕坐标（通常是页面里播放区域的位置）。
    func present(frame: CGRect, title: String, content: AnyView) {
        close()
        let window = PlayerHostWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = true
        window.isMovable = true
        window.title = title
        // 绿色按钮走系统全屏（标准标题栏 + 系统动画）
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self

        window.contentView = NSHostingView(rootView: content)
        self.window = window

        // 窗口被外部关闭（系统收尾等）时同步内部状态，避免页面与窗口状态不一致
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.teardown()
            }
        })
        isOpen = true
        isDetached = true
        window.makeKeyAndOrderFront(nil)
    }

    /// 关闭窗口：播放组件随之回到页面内。
    func close() {
        guard let window else { return }
        teardown()
        window.delegate = nil
        window.contentView = nil
        window.close()
    }

    // MARK: - 内部

    private func teardown() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        window = nil
        isOpen = false
        isDetached = false
    }
}

extension PlayerWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 全屏下先退出全屏；普通状态下把画面收回页面内
        if sender.styleMask.contains(.fullScreen) {
            sender.toggleFullScreen(nil)
            return false
        }
        onCloseRequested?()
        return false
    }
}

