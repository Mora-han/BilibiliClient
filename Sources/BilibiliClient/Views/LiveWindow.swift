import AppKit
import QuartzCore
import SwiftUI

/// 直播独立窗口：以“子窗口”形式嵌入直播间页面的播放区域（随缩放/移动对齐，
/// 由 FrameReporter 持续校准位置），承载 AVPlayerLayer 直播画面与控制条。
/// 承载方式与视频播放窗口一致：页面只留透明占位，画面全部由这个窗口渲染；
/// 全屏直接对窗口调用系统 toggleFullScreen，原生动画从嵌入位置放大到全屏。
@MainActor
final class LiveWindow {
    /// 全局唯一直播窗口：同一时刻只允许一个直播间在播。
    static var shared: LiveWindow?

    private var window: NSWindow?
    private var contentHost: NSHostingView<LiveWindowContent>?
    private weak var parentWindow: NSWindow?
    private var lastEmbedFrame: CGRect = .zero
    private var lastVisible = false
    private var observers: [NSObjectProtocol] = []
    private let closeGuard = LiveWindowCloseGuard()
    /// 全屏切换动画进行中：抑制 updateEmbedFrame 的 setFrame 干扰动画
    private var isTransitioning = false
    /// 主窗口进入全屏前的 collectionBehavior（全屏期间临时改掉，退出后还原）
    private var savedMainCollectionBehavior: NSWindow.CollectionBehavior?

    var isOpen: Bool { window != nil }
    /// 窗口当前是否处于系统全屏 space
    private(set) var isFullscreen = false

    /// 打开：以子窗口形式嵌入页面播放区域（frame 为屏幕坐标）。幂等。
    func open(model: LivePlayerModel,
              parent: NSWindow,
              frame: CGRect) {
        Self.shared = self
        if isOpen {
            // 视图可能被重建（model 为新实例）：刷新内容并重新钉位
            contentHost?.rootView = LiveWindowContent(
                model: model,
                isFullscreen: isFullscreen,
                onToggleFullscreen: { [weak self] in self?.toggleFullscreen() }
            )
            if parentWindow !== parent, let window {
                if window.parent != nil && window.parent !== parent {
                    window.parent?.removeChildWindow(window)
                }
                parent.addChildWindow(window, ordered: .above)
            }
            parentWindow = parent
            closeGuard.parentResolver = { [weak parent] in parent }
            updateEmbedFrame(frame)
            return
        }
        forceClose()
        self.parentWindow = parent
        lastEmbedFrame = frame
        lastVisible = false
        isFullscreen = false

        let window = LiveFullscreenWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = false
        window.isMovable = false
        closeGuard.parentResolver = { [weak parent] in parent }
        closeGuard.fullscreenScreenProvider = { [weak self] in
            guard let window = self?.window else { return nil }
            return window.screen ?? NSScreen.main
        }
        closeGuard.fullscreenRestoreFrameProvider = { [weak self] in
            guard let self else { return .zero }
            let frame = self.lastEmbedFrame
            return frame.width >= 4 && frame.height >= 4 ? frame : (self.window?.frame ?? .zero)
        }
        closeGuard.onFailFullscreenTransition = { [weak self] in
            self?.isTransitioning = false
            self?.resumeMainFullscreenRole()
        }
        window.delegate = closeGuard
        window.collectionBehavior.insert(.fullScreenPrimary)

        let host = NSHostingView(rootView: LiveWindowContent(
            model: model,
            isFullscreen: false,
            onToggleFullscreen: { [weak self] in self?.toggleFullscreen() }
        ))
        window.contentView = host
        contentHost = host
        self.window = window

        // 窗口被外部关闭（如系统收尾）时统一销毁，避免残留
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.finish(window)
            }
        })
        // 系统全屏进出通知：切换内容“全屏”状态，退出后恢复嵌入关系。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.isFullscreen = true
                self.isTransitioning = false
                self.suspendMainFullscreenRole()
                self.refreshContent()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.isFullscreen = false
                self.isTransitioning = false
                self.resumeMainFullscreenRole()
                // 还原嵌入态的无边框样式，重新作为子窗口钉回页面播放区域
                window.styleMask = [.borderless, .fullSizeContentView]
                self.reattachToParent()
                self.refreshContent()
                self.updateVisibility()
                window.makeKeyAndOrderFront(nil)
            }
        })

        parent.addChildWindow(window, ordered: .above)
        updateVisibility()
    }

    /// 页面播放区域位置变化（滚动/缩放/移动）时更新嵌入位置。
    func updateEmbedFrame(_ screenFrame: CGRect) {
        guard screenFrame.width >= 4, screenFrame.height >= 4 else {
            lastEmbedFrame = .zero
            if !isFullscreen {
                updateVisibility()
            }
            return
        }
        lastEmbedFrame = screenFrame
        // 全屏期间窗口 frame 由系统接管，不动窗口
        guard let window, !isFullscreen, !isTransitioning else { return }
        let current = window.frame
        if !framesEqual(current, screenFrame) {
            if sizesEqual(current.size, screenFrame.size) {
                window.setFrameOrigin(screenFrame.origin)
            } else {
                window.setFrame(screenFrame, display: false)
            }
        }
        updateVisibility()
    }

    /// 切换全屏：进入/退出都由系统原生动画完成。
    func toggleFullscreen() {
        if isFullscreen {
            exitFullscreen()
        } else {
            enterFullscreen()
        }
    }

    /// 进入全屏：先脱离父窗口（子窗口不能进入系统全屏），再触发原生动画。
    func enterFullscreen() {
        guard let window, !isFullscreen else { return }
        if let parent = parentWindow, window.parent === parent {
            parent.removeChildWindow(window)
        }
        window.makeKeyAndOrderFront(nil)
        window.styleMask = [.borderless, .resizable, .fullSizeContentView]
        isTransitioning = true
        // 主窗口临时退出全屏参与者角色，避免系统把它一起带进全屏 Space
        suspendMainFullscreenRole()
        window.toggleFullScreen(nil)
    }

    /// 退出全屏：由 didExitFullScreenNotification 收尾（恢复嵌入关系）。
    func exitFullscreen() {
        guard let window, isFullscreen else { return }
        isTransitioning = true
        window.toggleFullScreen(nil)
    }

    /// 把键盘焦点给直播窗口（进入页面时调用，快捷键立即可用）。
    func focusPlayer() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// 页面销毁时直接关闭窗口，不等任何动画。
    func forceClose() {
        guard let window else { return }
        finish(window)
    }

    // MARK: - 内部

    /// 嵌入区域是否仍在主窗口可视范围内；状态不变时不重复 orderFront/orderOut。
    private func updateVisibility() {
        guard let window else { return }
        guard let parent = parentWindow else { return }
        let visible = !isFullscreen
            && parent.isVisible
            && lastEmbedFrame.width > 0
            && lastEmbedFrame.intersects(parent.frame)
        guard visible != lastVisible else { return }
        lastVisible = visible
        if visible {
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
    }

    /// 销毁窗口并清理引用：移除观察者、脱离父窗口、关闭窗口、清空全局单例。
    private func finish(_ window: NSWindow) {
        guard self.window === window else { return }
        resumeMainFullscreenRole()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let parent = parentWindow, window.parent === parent {
            parent.removeChildWindow(window)
        }
        window.contentView = nil
        window.close()
        self.window = nil
        contentHost = nil
        parentWindow = nil
        isFullscreen = false
        lastEmbedFrame = .zero
        lastVisible = false
        if Self.shared === self {
            Self.shared = nil
        }
    }

    // MARK: - 主窗口全屏角色管理

    private func suspendMainFullscreenRole() {
        guard let main = parentWindow else { return }
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
        guard let saved = savedMainCollectionBehavior,
              let main = parentWindow else {
            savedMainCollectionBehavior = nil
            return
        }
        main.collectionBehavior = saved
        savedMainCollectionBehavior = nil
    }

    /// 退出全屏后重新嵌入主窗口，并恢复到全屏前的嵌入位置。
    private func reattachToParent() {
        guard let window, let parent = parentWindow else { return }
        if window.parent !== parent {
            parent.addChildWindow(window, ordered: .above)
        }
        if lastEmbedFrame.width >= 4, lastEmbedFrame.height >= 4 {
            window.setFrame(lastEmbedFrame, display: false)
        }
    }

    private func refreshContent() {
        guard let contentHost else { return }
        let root = contentHost.rootView
        contentHost.rootView = LiveWindowContent(
            model: root.model,
            isFullscreen: isFullscreen,
            onToggleFullscreen: { [weak self] in self?.toggleFullscreen() }
        )
    }

    private func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.5
            && abs(a.origin.y - b.origin.y) < 0.5
            && abs(a.width - b.width) < 0.5
            && abs(a.height - b.height) < 0.5
    }

    private func sizesEqual(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}

/// 直播窗口内容：黑底 + AVPlayerLayer 画面 + 简化控制条 + 左上角在线人数徽标。
private struct LiveWindowContent: View {
    @ObservedObject var model: LivePlayerModel
    @State private var controlsVisible = true
    /// 是否处于系统全屏：决定控制条样式与全屏按钮方向
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                CustomPlayerView(player: player,
                                 autofocus: true,
                                 onSpace: { model.togglePlay() },
                                 onSingleClick: { controlsVisible.toggle() },
                                 onDoubleClick: onToggleFullscreen)
            } else if model.state == .loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在连接直播间…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.state == .offline {
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("主播还未开播").font(.headline)
                }
            } else if model.state == .failed {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("直播加载失败").font(.headline)
                    Text(model.errorMessage ?? "未知错误")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await model.retryCurrent() }
                    }
                }
                .padding()
            }
            LiveControlsView(model: model,
                             controlsVisible: $controlsVisible,
                             isFullscreen: isFullscreen,
                             onToggleFullscreen: onToggleFullscreen)
        }
        .overlay(alignment: .topLeading) {
            // 在线人数：随控制条唤起显示在直播窗口左上角
            if controlsVisible, let text = model.onlineText {
                LiveOnlineBadge(text: text)
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

/// 直播窗口左上角“在线人数”徽标（液态玻璃样式，与视频窗口一致）。
private struct LiveOnlineBadge: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("\(text) 人在看")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(Color.primary.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(colorScheme == .dark ? .black.opacity(0.35) : .white.opacity(0.25))
                .overlay {
                    Capsule()
                        .stroke(.primary.opacity(0.15), lineWidth: 1)
                        .glassEffect(.regular, in: .capsule)
                }
        }
    }
}

/// 直播简化控制条：播放/暂停 + 直播状态 + 全屏，静止后自动淡出。
private struct LiveControlsView: View {
    @ObservedObject var model: LivePlayerModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var controlsVisible: Bool
    /// 当前是否在全屏窗口内
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var hideTask: Task<Void, Never>?
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            Color.clear.allowsHitTesting(false)
            if controlsVisible {
                controlBar
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active, .ended:
                bumpActivity()
            }
        }
        .onAppear { scheduleHide() }
        .onChange(of: controlsVisible) { _, visible in
            if visible { scheduleHide() }
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private var controlBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button {
                    bumpActivity()
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "暂停" : "播放")

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("直播中")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.primary.opacity(0.12)))
                .allowsHitTesting(false)

                Spacer()

                Button {
                    bumpActivity()
                    onToggleFullscreen()
                } label: {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(isFullscreen ? "退出全屏" : "全屏")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { bumpActivity() }
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isDark ? .black.opacity(0.35) : .white.opacity(0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.primary.opacity(0.12), lineWidth: 1)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }
            }
            .frame(maxWidth: 420)
            .padding(.bottom, 18)
        }
    }

    private func bumpActivity() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                controlsVisible = true
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, controlsVisible else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                controlsVisible = false
            }
        }
    }
}

/// 直播窗口子类：类名包含 Fullscreen，让 AppDelegate 的窗口特判自动生效
/// （不接管 delegate、排除出 mainWindow 查找）。
private final class LiveFullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 直播窗口关闭守卫：全屏态下 Cmd+W 先退出全屏；嵌入态下转给主窗口。
private final class LiveWindowCloseGuard: NSObject, NSWindowDelegate {
    var parentResolver: (() -> NSWindow?)?
    /// 进入全屏时的目标屏幕（决定放大到哪块屏幕）。
    var fullscreenScreenProvider: (() -> NSScreen?)?
    /// 退出全屏时窗口应缩小到的 frame（当前嵌入位）。
    var fullscreenRestoreFrameProvider: (() -> CGRect)?
    /// 系统全屏切换失败（罕见）时复位内部状态。
    var onFailFullscreenTransition: (() -> Void)?

    // 自接管进出全屏的窗口动画：系统负责切换 Space，
    // 这里让窗口 frame 与系统动画同节奏地连续缩放，内容实时跟随。
    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func window(_ window: NSWindow,
                startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        let frame = (fullscreenScreenProvider?() ?? window.screen ?? NSScreen.main)?.frame
            ?? window.frame
        animate(window, to: frame, duration: duration)
    }

    func window(_ window: NSWindow,
                startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        var frame = fullscreenRestoreFrameProvider?() ?? window.frame
        if frame.width < 4 || frame.height < 4 {
            frame = window.frame
        }
        animate(window, to: frame, duration: duration)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        onFailFullscreenTransition?()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        onFailFullscreenTransition?()
    }

    private func animate(_ window: NSWindow, to frame: CGRect, duration: TimeInterval) {
        if duration <= 0.001 {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.styleMask.contains(.fullScreen) {
            sender.toggleFullScreen(nil)
            return false
        }
        parentResolver?()?.performClose(nil)
        return false
    }
}
