import AppKit
import SwiftUI

/// 视频独立窗口：日常以“子窗口”形式嵌入主窗口的视频区域（随滚动/缩放/移动对齐，
/// 滚出屏幕自动隐藏）；全屏时直接对该窗口调用系统原生 toggleFullScreen，
/// 由系统动画从视频当前位置丝滑放大到全屏 Space。渲染层/弹幕/控制条都在
/// 同一个窗口里，未来可直接扩展为独立窗口模式。
///
/// 内容布局与原来页面内嵌播放器完全一致（CustomPlayerView + 弹幕层 + 控制条 +
/// 右上角弹幕开关），窗口只负责承载，不改变任何 UI 或交互。
@MainActor
final class VideoWindow {
    private var window: NSWindow?
    private var contentHost: NSHostingView<VideoWindowContent>?
    private weak var parentWindow: NSWindow?
    private var lastEmbedFrame: CGRect = .zero
    private var lastVisible = false
    private var observers: [NSObjectProtocol] = []
    private let closeGuard = VideoWindowCloseGuard()
    /// 正在退出全屏并销毁窗口，避免退出全屏回调又把它“重新嵌入”
    private var closing = false
    let state = VideoWindowState()

    var isOpen: Bool { window != nil }
    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    /// 打开：以子窗口形式嵌入主窗口的视频区域（frame 为屏幕坐标）。
    /// 幂等：已打开时只校准位置，不会重复建窗（避免残留黑窗口）。
    func open(playerController: PlayerController,
              engine: DanmakuEngine,
              parent: NSWindow,
              frame: CGRect) {
        if isOpen {
            updateEmbedFrame(frame)
            return
        }
        forceClose()
        closing = false
        self.parentWindow = parent
        lastEmbedFrame = frame
        lastVisible = false

        let window = VideoFullscreenWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.hasShadow = false
        window.isMovable = false
        closeGuard.parentResolver = { [weak parent] in parent }
        window.delegate = closeGuard

        let host = NSHostingView(rootView: VideoWindowContent(
            playerController: playerController,
            engine: engine,
            state: state,
            onToggleFullscreen: { [weak self] in self?.toggleFullscreen() }
        ))
        window.contentView = host
        contentHost = host
        self.window = window

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.closing = false
                self.state.isFullscreen = true
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                if self.closing {
                    self.closing = false
                    self.finish(window)
                } else {
                    self.state.isFullscreen = false
                    self.reattachEmbed()
                }
            }
        })
        // 窗口被外部关闭（如系统全屏退出后的 performClose）时统一收尾
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.finish(window)
            }
        })

        parent.addChildWindow(window, ordered: .above)
        updateVisibility()
    }

    /// 主窗口视频区域位置变化（滚动/缩放/移动）时更新嵌入位置。
    /// 仅在 frame 真正变化时才动窗口：纯移动用 setFrameOrigin（轻量，
    /// 不触发重绘），尺寸变化才 setFrame(display: false)，避免连续
    /// 重绘导致的卡顿与闪烁。
    func updateEmbedFrame(_ screenFrame: CGRect) {
        guard screenFrame.width >= 4, screenFrame.height >= 4 else {
            lastEmbedFrame = .zero
            updateVisibility()
            return
        }
        lastEmbedFrame = screenFrame
        guard let window, !isFullscreen else { return }
        let current = window.frame
        if !framesEqual(current, screenFrame) {
            if sizesEqual(current.size, screenFrame.size) {
                window.setFrameOrigin(screenFrame.origin)
            } else {
                window.setFrame(screenFrame, display: false)
            }
            updateVisibility()
        }
    }

    /// 切换系统原生全屏（进入/退出都由系统动画处理）。
    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    /// 把键盘焦点给视频窗口（进入页面时调用，快捷键立即可用）。
    func focusPlayer() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 内部

    /// 嵌入区域是否仍在主窗口可视范围内；状态不变时不重复 orderFront/orderOut。
    private func updateVisibility() {
        guard let window, let parent = parentWindow else { return }
        if isFullscreen {
            if !window.isVisible { window.orderFront(nil) }
            lastVisible = true
            return
        }
        let visible = lastEmbedFrame.width > 0 && lastEmbedFrame.intersects(parent.frame)
        guard visible != lastVisible else { return }
        lastVisible = visible
        if visible {
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }

    /// 退出全屏后回到嵌入状态。
    private func reattachEmbed() {
        guard let window, let parent = parentWindow else { return }
        if window.parent !== parent {
            parent.addChildWindow(window, ordered: .above)
        }
        if lastEmbedFrame.width > 0 {
            window.setFrame(lastEmbedFrame, display: false)
        }
        updateVisibility()
    }

    /// 关闭视频窗口：嵌入态直接销毁；全屏态先退出全屏动画再销毁。
    func close() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            closing = true
            window.toggleFullScreen(nil)
        } else {
            finish(window)
        }
    }

    /// 页面销毁时直接关闭，不等退出全屏动画。
    func forceClose() {
        guard let window else { return }
        finish(window)
    }

    /// 统一收尾：移除父子关系 → 隐藏 → 关闭 → 清空引用与观察者。
    private func finish(_ window: NSWindow) {
        guard self.window === window else { return }
        self.window = nil
        contentHost = nil
        parentWindow = nil
        closing = false
        lastVisible = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if window.parent != nil {
            window.parent?.removeChildWindow(window)
        }
        if window.isVisible {
            window.orderOut(nil)
        }
        window.close()
    }

    private func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.5
            && abs(a.origin.y - b.origin.y) < 0.5
            && sizesEqual(a.size, b.size)
    }

    private func sizesEqual(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

/// 全屏状态（控制条按钮图标/退出方向由它驱动）。
@MainActor
final class VideoWindowState: ObservableObject {
    @Published var isFullscreen = false
}

/// 视频窗口内容：与原来页面内嵌播放器完全一致——
/// 渲染层 + 弹幕层 + 控制条 + 右上角弹幕开关，仅改变承载容器。
private struct VideoWindowContent: View {
    @ObservedObject var playerController: PlayerController
    let engine: DanmakuEngine
    @ObservedObject var state: VideoWindowState
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @State private var controlsVisible = true
    let onToggleFullscreen: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let player = playerController.player {
                CustomPlayerView(player: player,
                                 autofocus: true,
                                 onSpace: { playerController.togglePlay() },
                                 onSkip: { playerController.skip(by: $0) },
                                 onSingleClick: {
                                     withAnimation(controlsVisible
                                                   ? PlayerControlsView.hideAnimation
                                                   : PlayerControlsView.showAnimation) {
                                         controlsVisible.toggle()
                                     }
                                 },
                                 onDoubleClick: { onToggleFullscreen() })
                DanmakuOverlayView(engine: engine, player: player, enabled: danmakuEnabled)
            }
            PlayerControlsView(player: playerController,
                               controlsVisible: $controlsVisible,
                               isFullscreen: state.isFullscreen,
                               onToggleFullscreen: onToggleFullscreen)
        }
        .overlay(alignment: .topTrailing) {
            if playerController.player != nil {
                DanmakuToggleButton(isOn: $danmakuEnabled)
                    .padding(10)
            }
        }
        .overlay {
            if !state.isFullscreen {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: state.isFullscreen ? 0 : 16))
        .clipped()
    }
}

/// 视频窗口子类：类名包含 Fullscreen，让 AppDelegate 的窗口特判自动生效
/// （不接管 delegate、关闭放行、排除出 mainWindow 查找）。
private final class VideoFullscreenWindow: NSWindow {
    /// 无边框窗口默认不能成为 key 窗口，导致收不到键盘事件
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 视频窗口关闭守卫：嵌入态下 Cmd+W 不直接关掉视频窗口，而是转给主窗口；
/// 全屏态下先退出全屏动画，而不是直接销毁。
private final class VideoWindowCloseGuard: NSObject, NSWindowDelegate {
    var parentResolver: (() -> NSWindow?)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.styleMask.contains(.fullScreen) {
            sender.toggleFullScreen(nil)
            return false
        }
        parentResolver?()?.performClose(nil)
        return false
    }
}

/// 锚点：实时上报视频区域在屏幕坐标中的 frame（含滚动/窗口移动/缩放），
/// 用于把视频窗口钉在主窗口的视频区域上。仅在 frame 真正变化时上报，
/// 避免布局/重绘触发的大量重复 setFrame。
struct FrameReporter: NSViewRepresentable {
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.onFrame = onFrame
        nsView.report()
    }

    final class FrameView: NSView {
        var onFrame: (CGRect) -> Void = { _ in }
        private var lastReported: CGRect?
        private var windowObservers: [NSObjectProtocol] = []
        private var scrollObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers = []
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
            scrollObserver = nil
            guard let window else { return }
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() })
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() })
            if let scroll = enclosingScrollView {
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scroll, queue: .main
                ) { [weak self] _ in self?.report() }
            }
            report()
        }

        func report() {
            guard let window else { return }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            guard frame.width >= 4, frame.height >= 4 else {
                lastReported = nil
                return
            }
            // 与上次一致时跳过，避免重复 setFrame 造成卡顿/闪烁
            if let lastReported, framesEqual(lastReported, frame) { return }
            lastReported = frame
            onFrame(frame)
        }

        private func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.origin.x - b.origin.x) < 0.5
                && abs(a.origin.y - b.origin.y) < 0.5
                && abs(a.width - b.width) < 0.5
                && abs(a.height - b.height) < 0.5
        }
    }
}
