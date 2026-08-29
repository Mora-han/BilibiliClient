import AppKit
import SwiftUI

/// 自定义全屏播放窗口：进入系统全屏 space，窗口内自带渲染层/控制条/弹幕层。
/// 不再使用 AVKit 原生全屏，从根上避免视图搬移与双驱动导致的全屏卡顿。
@MainActor
final class PlayerFullscreenWindow {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    var isOpen: Bool { window != nil }

    func open(playerController: PlayerController,
              engine: DanmakuEngine,
              onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose

        let window = CustomFullscreenWindow(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]

        window.contentView = NSHostingView(rootView: FullscreenPlayerView(
            playerController: playerController,
            engine: engine,
            onExit: { [weak self] in
                self?.close()
            }
        ))
        self.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.finish(window)
            }
        }

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }

    /// 关闭全屏窗口（退出系统全屏 space 后由通知收尾）。
    func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            finish(window)
        }
    }

    /// 页面销毁时直接关闭窗口，不等退出全屏动画。
    func forceClose() {
        guard let window else { return }
        window.close()
        self.window = nil
        onClose = nil
    }

    private func finish(_ window: NSWindow) {
        guard self.window === window else { return }
        window.close()
        self.window = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

/// 全屏窗口子类：类名包含 Fullscreen，让 AppDelegate 的窗口特判自动生效
/// （不接管 delegate、关闭放行、排除出 mainWindow 查找）。
private final class CustomFullscreenWindow: NSWindow {
    /// 无边框窗口默认不能成为 key 窗口，导致全屏下收不到键盘事件
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 全屏窗口内容：渲染层 + 弹幕层 + 控制条，共用主窗口的 PlayerController 与弹幕引擎。
private struct FullscreenPlayerView: View {
    @ObservedObject var playerController: PlayerController
    let engine: DanmakuEngine
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @State private var controlsVisible = true
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let player = playerController.player {
                CustomPlayerView(player: player,
                                 autofocus: true,
                                 onSpace: { playerController.togglePlay() },
                                 onSkip: { playerController.skip(by: $0) },
                                 onSingleClick: { controlsVisible.toggle() },
                                 onDoubleClick: onExit)
                DanmakuOverlayView(engine: engine, player: player, enabled: danmakuEnabled)
            }
            PlayerControlsView(player: playerController,
                               controlsVisible: $controlsVisible,
                               isFullscreen: true,
                               onToggleFullscreen: onExit)
        }
        .clipped()
    }
}
