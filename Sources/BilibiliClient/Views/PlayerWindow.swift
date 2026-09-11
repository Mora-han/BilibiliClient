import AppKit
import QuartzCore
import SwiftUI

/// 播放窗口（普通窗口）：只有点“分离窗口”或进入全屏时才按需创建，
/// 窗口里装的就是页面里同一个播放组件，不再有常驻钉位的特殊窗口。
final class PlayerHostWindow: NSWindow {
    /// 无边框窗口默认不能成为 key 窗口，收不到键盘事件
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 播放窗口的创建/销毁/全屏/分离状态管理。
///
/// 页面默认把播放组件放在页内；`present(frame:...)` 时窗口覆盖在画面所在
/// 位置并把组件搬进窗口，`close()` 后组件自动回到页面内——因此窗口只在
/// 真正需要的时候存在。
@MainActor
final class PlayerWindowController: NSObject, ObservableObject {
    /// 窗口当前是否存在（存在 = 播放画面已从页面移入窗口）
    @Published private(set) var isOpen = false
    /// 是否为用户手动分离出来的独立窗口（false = 为全屏临时创建）
    @Published private(set) var isDetached = false
    /// 是否处于系统全屏
    @Published private(set) var isFullscreen = false

    /// 用户主动关闭窗口（红点 / Cmd+W / 关闭按钮）时回调，页面据此把画面收回页内
    var onCloseRequested: (() -> Void)?

    private var window: PlayerHostWindow?
    private var host: NSHostingView<AnyView>?
    private var observers: [NSObjectProtocol] = []
    /// 播放窗口进入全屏前主窗口的 collectionBehavior（全屏期间临时改掉，退出后还原）
    private var savedMainCollectionBehavior: NSWindow.CollectionBehavior?
    /// 进入全屏前窗口所在的 frame：退出全屏动画缩回到这里
    private var restoreFrame: CGRect = .zero
    /// 分离窗口全屏期间临时改成无边框（内容才能随动画连续缩放），
    /// 退出全屏时用这里的标题还原标题栏
    private var titleBeforeFullscreen: String?

    /// 创建窗口并把播放组件搬进窗口。frame 为屏幕坐标（通常是页面里播放区域的位置）。
    func present(frame: CGRect, detached: Bool, title: String, content: AnyView) {
        close()
        let style: NSWindow.StyleMask = detached
            ? [.titled, .closable, .miniaturizable, .resizable]
            : [.borderless, .fullSizeContentView, .resizable]
        let window = PlayerHostWindow(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = detached
        window.isMovable = detached
        window.title = detached ? title : ""
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self

        let host = NSHostingView(rootView: content)
        window.contentView = host
        self.host = host
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
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isFullscreen = true
                self?.suspendMainFullscreenRole()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.finishFullscreenExit(window)
                self.isFullscreen = false
            }
        })

        isOpen = true
        isDetached = detached
        isFullscreen = false
        window.makeKeyAndOrderFront(nil)
    }

    /// 刷新窗口内的播放组件（全屏/分离状态变化后重建内容）。
    func updateContent(_ content: AnyView) {
        host?.rootView = content
    }

    /// 系统原生全屏切换（窗口存在时才有意义）。
    func toggleFullScreen() {
        guard let window else { return }
        guard !window.styleMask.contains(.fullScreen) else {
            window.toggleFullScreen(nil)
            return
        }
        prepareForFullscreen(window)
        suspendMainFullscreenRole()
        window.toggleFullScreen(nil)
    }

    /// 进入全屏前的准备：记住缩回位置；带标题栏的分离窗口切成无边框。
    ///
    /// 带标题栏的窗口直接全屏时 AppKit 只缩放窗口框体，视频内容会停在左下角
    /// 原尺寸、动画结束才跳到位；切成无边框后内容铺满整窗，配合下面的
    /// `startCustomAnimation…` 与系统动画同节奏连续缩放。
    private func prepareForFullscreen(_ window: PlayerHostWindow) {
        restoreFrame = window.frame
        guard window.styleMask.contains(.titled) else { return }
        titleBeforeFullscreen = window.title
        window.styleMask = [.borderless, .fullSizeContentView, .resizable]
    }

    /// 退出全屏收尾：还原主窗口全屏角色与分离窗口的标题栏。
    private func finishFullscreenExit(_ window: PlayerHostWindow) {
        resumeMainFullscreenRole()
        guard let title = titleBeforeFullscreen else { return }
        titleBeforeFullscreen = nil
        // 先按无边框窗口的 frame 换算内容区，加回标题栏后画面位置保持不变
        let contentFrame = window.frame
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.isMovable = true
        window.hasShadow = true
        window.setFrame(window.frameRect(forContentRect: contentFrame), display: false)
    }

    /// 让窗口 frame 与系统全屏动画同节奏连续缩放，画面/弹幕/控制条实时跟随。
    private func animate(_ window: NSWindow, to frame: CGRect, duration: TimeInterval) {
        guard duration > 0.001 else {
            window.setFrame(frame, display: false)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: false)
        }
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
        resumeMainFullscreenRole()
        titleBeforeFullscreen = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        window = nil
        host = nil
        isOpen = false
        isDetached = false
        isFullscreen = false
    }

    /// 播放窗口进入全屏前把主窗口临时改为“非全屏参与者”，避免系统把主窗口
    /// 一起带进全屏 Space；退出全屏后还原。
    private func suspendMainFullscreenRole() {
        guard let main = AppDelegate.mainWindow() else { return }
        if savedMainCollectionBehavior == nil {
            savedMainCollectionBehavior = main.collectionBehavior
        }
        var behavior = main.collectionBehavior
        behavior.remove(.fullScreenPrimary)
        behavior.remove(.fullScreenAuxiliary)
        behavior.insert(.fullScreenNone)
        main.collectionBehavior = behavior
    }

    private func resumeMainFullscreenRole() {
        guard let saved = savedMainCollectionBehavior else { return }
        savedMainCollectionBehavior = nil
        AppDelegate.mainWindow()?.collectionBehavior = saved
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

    // 自接管进出全屏的窗口动画：系统仍负责切换 Space，这里只让窗口 frame 与
    // 系统动画同节奏连续缩放，画面/弹幕/控制条全程跟随，效果等同系统
    // “最大化”式原生 zoom。若不接管，AppKit 只缩放窗口框体而不重建内容，
    // 内容会以全屏尺寸停在左下角，直到动画结束才跳到位。
    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        window === self.window ? [window] : nil
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        window === self.window ? [window] : nil
    }

    func window(_ window: NSWindow,
                startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        let screen = window.screen ?? NSScreen.main
        animate(window, to: screen?.frame ?? window.frame, duration: duration)
    }

    func window(_ window: NSWindow,
                startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        var target = restoreFrame
        if target.width < 4 || target.height < 4 {
            target = window.frame
        }
        animate(window, to: target, duration: duration)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        resumeMainFullscreenRole()
        if let window = window as? PlayerHostWindow {
            finishFullscreenExit(window)
        }
        isFullscreen = false
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        // 退出失败说明窗口仍在全屏，保持全屏状态与主窗口角色不变
    }
}
