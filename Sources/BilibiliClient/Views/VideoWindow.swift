import AppKit
import QuartzCore
import SwiftUI

/// 视频独立窗口：以“子窗口”形式嵌入主窗口的视频区域（随缩放/移动对齐，
/// 由 FrameReporter 持续校准位置）。内容与原来页面内嵌播放器完全一致（渲染层 + 弹幕层 +
/// 控制条 + 右上角弹幕开关），窗口只负责承载，不改变任何 UI 或交互。
/// 全屏直接对窗口自身调用系统 toggleFullScreen：原生动画从当前嵌入位置
/// 放大到全屏，退出后恢复为嵌入窗口。
@MainActor
final class VideoWindow {
    /// 全局唯一嵌入窗口：@State 在 NSViewRepresentable 更新阶段写入不可靠，
    /// 用静态引用兜底，确保任意时刻只有一个嵌入窗口。页面销毁（finish）时清空。
    static var shared: VideoWindow?

    private var window: NSWindow?
    private var contentHost: NSHostingView<VideoWindowContent>?
    private weak var parentWindow: NSWindow?
    private var lastEmbedFrame: CGRect = .zero
    private var lastVisible = false
    private var observers: [NSObjectProtocol] = []
    private let closeGuard = VideoWindowCloseGuard()
    /// 全屏切换动画进行中：抑制 updateEmbedFrame 的 setFrame 干扰动画。
    private var isTransitioning = false
    /// 分离窗口进入全屏前的 frame，退出全屏时按它同步缩小回原位。
    private var detachedRestoreFrame: CGRect = .zero
    /// 主窗口进入全屏前的 collectionBehavior（全屏期间临时改掉，退出后还原）。
    private var savedMainCollectionBehavior: NSWindow.CollectionBehavior?

    var isOpen: Bool { window != nil }
    /// 窗口当前是否处于系统全屏 space（供页面判断全屏状态与切换方向）。
    private(set) var isFullscreen = false
    /// 是否已分离为可自由移动/缩放的独立窗口（false = 吸附嵌入播放页）。
    private(set) var isDetached = false

    /// 打开：以子窗口形式嵌入主窗口的视频区域（frame 为屏幕坐标）。
    /// 幂等：已打开时只校准位置，不会重复建窗（避免残留黑窗口）。
    func open(playerController: PlayerController,
              engine: DanmakuEngine,
              parent: NSWindow,
              frame: CGRect,
              onToggleFullscreen: @escaping () -> Void,
              onToggleDetach: @escaping () -> Void) {
        Self.shared = self
        if isOpen {
            // 视图可能被重建（player/engine/全屏回调都是新实例）：刷新内容并重新钉位
            contentHost?.rootView = VideoWindowContent(
                playerController: playerController,
                engine: engine,
                isFullscreen: isFullscreen,
                isDetached: isDetached,
                onToggleFullscreen: onToggleFullscreen,
                onToggleDetach: onToggleDetach
            )
            // 已分离时保持独立窗口，不重新吸附
            if !isDetached, parentWindow !== parent, let window {
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

        let window = VideoFullscreenWindow(
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
        closeGuard.isDetachedProvider = { [weak self] in self?.isDetached ?? false }
        closeGuard.onDetachRestore = { [weak self] in self?.toggleDetach() }
        closeGuard.fullscreenScreenProvider = { [weak self] in
            guard let window = self?.window else { return nil }
            return window.screen ?? NSScreen.main
        }
        closeGuard.fullscreenRestoreFrameProvider = { [weak self] in
            guard let self else { return .zero }
            let frame = self.isDetached ? self.detachedRestoreFrame : self.lastEmbedFrame
            return frame.width >= 4 && frame.height >= 4 ? frame : (self.window?.frame ?? .zero)
        }
        closeGuard.onFailFullscreenTransition = { [weak self] in
            self?.isTransitioning = false
            self?.resumeMainFullscreenRole()
        }
        window.delegate = closeGuard
        window.collectionBehavior.insert(.fullScreenPrimary)

        let host = NSHostingView(rootView: VideoWindowContent(
            playerController: playerController,
            engine: engine,
            isFullscreen: false,
            isDetached: false,
            onToggleFullscreen: onToggleFullscreen,
            onToggleDetach: onToggleDetach
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
        // 系统全屏进出通知：切换内容 UI 的“全屏”状态，退出后恢复嵌入关系。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.isFullscreen = true
                self.isTransitioning = false
                // 过渡期间 SwiftUI 可能改回主窗口的全屏角色，再次确保其为
                // 非全屏参与者（留在桌面 Space）。
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
                // 已回到桌面 Space，恢复主窗口原有的全屏角色。
                self.resumeMainFullscreenRole()
                if self.isDetached {
                    // 从全屏退出后保持独立窗口形态（不重新吸附）
                    window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
                    window.title = "视频播放"
                    window.isMovable = true
                    window.hasShadow = true
                    self.refreshContent()
                    window.orderFront(nil)
                } else {
                    // 还原嵌入态的无边框样式（全屏期间临时加入了 .resizable）
                    window.styleMask = [.borderless, .fullSizeContentView]
                    self.reattachToParent()
                    self.refreshContent()
                    self.updateVisibility()
                    // 恢复全屏前的焦点状态：播放窗口重新吸附后保持 key/front，
                    // 避免收尾瞬间主窗口抢回焦点而被带到错误的 Space。
                    window.makeKeyAndOrderFront(nil)
                }
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
            if !isDetached {
                updateVisibility()
            }
            return
        }
        // 吸附位置始终记录（分离状态下仅用于“恢复原状”时的定位）
        lastEmbedFrame = screenFrame
        // 全屏/分离期间窗口 frame 由系统或用户接管，不动窗口
        guard let window, !isFullscreen, !isDetached, !isTransitioning else { return }
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

    /// 切换全屏：进入/退出都由系统原生动画完成，起点/终点就是当前窗口位置。
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
        // 记录退出全屏时要缩回的位置（分离窗口就是进入前的 frame）
        detachedRestoreFrame = window.frame
        if let parent = parentWindow, window.parent === parent {
            parent.removeChildWindow(window)
        }
        // 先把播放窗口锁定为 key/front。
        window.makeKeyAndOrderFront(nil)
        // 统一走“无边框 + 可缩放”路径进入系统全屏：
        // 分离态是带标题栏的标准窗口，直接全屏时 AppKit 缩放的是窗口框体，
        // 视频内容不会跟着动画实时放大（画面停在左下角原尺寸，动画结束才
        // 跳到位）。切成无边框后内容铺满整窗，与吸附态一样随动画一起放大。
        window.styleMask = [.borderless, .resizable, .fullSizeContentView]
        // 进入动画由 delegate 的 startCustomAnimation… 接管：与系统切入新 Space
        // 的动画同节奏地把窗口 frame 放大到全屏，内容实时跟随缩放（原生 zoom
        // 动画，和“最大化”同一套机制）。
        isTransitioning = true
        // 关键：把主窗口临时改为“非全屏参与者”。主窗口默认带 .fullScreenPrimary，
        // 系统会把同 app 里所有该角色的窗口一起带进全屏 Space（表现为全屏后
        // 主窗口弹出来）。播放窗口进入全屏前先让主窗口退出该角色（保持可见、
        // 留在桌面 Space），退出全屏后再还原。
        suspendMainFullscreenRole()
        window.toggleFullScreen(nil)
    }

    /// 退出全屏：由 didExitFullScreenNotification 收尾（恢复嵌入关系）。
    func exitFullscreen() {
        guard let window, isFullscreen else { return }
        // 退出动画由 delegate 接管：系统切回桌面 Space 的同时，把窗口 frame
        // 连续缩小到“当前嵌入位置 / 分离前位置”，内容全程跟随缩放，不会
        // 出现动画结束后再搬位的跳变。
        isTransitioning = true
        window.toggleFullScreen(nil)
    }

    /// 切换“吸附嵌入 / 分离独立”：分离后可自由移动与缩放，再点一次恢复吸附。
    func toggleDetach() {
        if isDetached {
            attachToEmbed()
        } else {
            detachFromEmbed()
        }
    }

    /// 分离为独立窗口：脱离父窗口、加上标准标题栏，可自由移动/缩放。
    private func detachFromEmbed() {
        guard let window, !isDetached, !isFullscreen else { return }
        if let parent = parentWindow, window.parent === parent {
            parent.removeChildWindow(window)
        }
        lastEmbedFrame = window.frame
        window.styleMask = [.titled, .resizable, .closable, .miniaturizable]
        window.title = "视频播放"
        window.isMovable = true
        window.hasShadow = true
        isDetached = true
        lastVisible = true
        window.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        refreshContent()
    }

    /// 恢复原状：回到播放页视频区域，重新作为子窗口吸附定位。
    private func attachToEmbed() {
        guard let window, isDetached, !isFullscreen else { return }
        window.orderOut(nil)
        window.styleMask = [.borderless, .fullSizeContentView]
        window.title = ""
        window.isMovable = false
        window.hasShadow = false
        isDetached = false
        if let parent = parentWindow {
            parent.addChildWindow(window, ordered: .above)
            parentWindow = parent
        }
        if lastEmbedFrame.width >= 4, lastEmbedFrame.height >= 4 {
            window.setFrame(lastEmbedFrame, display: true)
        }
        updateVisibility()
        refreshContent()
    }

    /// 把键盘焦点给视频窗口（进入页面时调用，快捷键立即可用）。
    func focusPlayer() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }


    // MARK: - 内部

    /// 嵌入区域是否仍在主窗口可视范围内；状态不变时不重复 orderFront/orderOut。
    private func updateVisibility() {
        guard let window else { return }
        // 分离状态：独立窗口始终可见，不受播放区域位置影响
        if isDetached {
            window.orderFront(nil)
            lastVisible = true
            return
        }
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

    /// 页面销毁时直接关闭窗口，不等任何动画。
    func forceClose() {
        guard let window else { return }
        finish(window)
    }

    /// 销毁窗口并清理引用：移除观察者、脱离父窗口、关闭窗口、清空全局单例。
    /// 由 willClose 通知（窗口被外部关闭）与 forceClose（页面销毁）调用。
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
        // 先摘下内容视图再关闭窗口：弹幕渲染层的 CADisplayLink 依赖视图离开
        // 窗口（viewDidMoveToWindow(nil)）来停帧，不能等 deinit 兜底（display
        // link 会强引用 target，可能形成滞留）。这里显式断链，确保关闭后
        // 不再有任何帧驱动残留，CPU 立即回落到 0。
        window.contentView = nil
        window.close()
        self.window = nil
        contentHost = nil
        parentWindow = nil
        isFullscreen = false
        isDetached = false
        lastEmbedFrame = .zero
        lastVisible = false
        if Self.shared === self {
            Self.shared = nil
        }
    }

    // MARK: - 主窗口全屏角色管理

    /// 播放窗口进入全屏前调用：把主窗口临时改为“非全屏参与者”。
    /// 主窗口（SwiftUI 场景窗口）默认带 .fullScreenPrimary，属于 app 的全屏
    /// 会话成员；播放窗口以同样角色进入全屏时，系统会把主窗口一并带进全屏
    /// Space（表现为“全屏后主窗口弹出来”）。这里把主窗口改为 .fullScreenNone：
    /// 窗口保持可见、留在桌面 Space，不再参与任何全屏会话。
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

    /// 退出全屏后还原主窗口原有的 collectionBehavior（主窗口自己的全屏能力
    /// 不受影响）。窗口销毁/切换失败时也会调用，避免状态残留。
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

    /// 全屏状态变化后刷新内容（控制条全屏样式、圆角、弹幕开关等）。
    private func refreshContent() {
        guard let contentHost else { return }
        let root = contentHost.rootView
        contentHost.rootView = VideoWindowContent(
            playerController: root.playerController,
            engine: root.engine,
            isFullscreen: isFullscreen,
            isDetached: isDetached,
            onToggleFullscreen: root.onToggleFullscreen,
            onToggleDetach: root.onToggleDetach
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

/// 视频窗口内容：与原来页面内嵌播放器完全一致——
/// 渲染层 + 弹幕层 + 控制条 + 右上角弹幕开关，仅改变承载容器。
private struct VideoWindowContent: View {
    @ObservedObject var playerController: PlayerController
    let engine: DanmakuEngine
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @State private var controlsVisible = true
    /// 是否处于系统全屏：决定控制条样式与弹幕开关是否显示。
    let isFullscreen: Bool
    /// 是否已分离为独立窗口：决定控制条“分离/吸附”按钮的形态。
    let isDetached: Bool
    let onToggleFullscreen: () -> Void
    let onToggleDetach: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let player = playerController.player {
                CustomPlayerView(player: player,
                                 autofocus: true,
                                 onSpace: { playerController.togglePlay() },
                                 onSkip: { playerController.skip(by: $0) },
                                 onSingleClick: { controlsVisible.toggle() },
                                 onDoubleClick: onToggleFullscreen)
                DanmakuOverlayView(engine: engine, player: player, enabled: danmakuEnabled)
            }
            PlayerControlsView(player: playerController,
                               controlsVisible: $controlsVisible,
                               isFullscreen: isFullscreen,
                               isDetached: isDetached,
                               onToggleFullscreen: onToggleFullscreen,
                               onToggleDetach: onToggleDetach)
        }
        .overlay(alignment: .topTrailing) {
            if !isFullscreen, playerController.player != nil {
                DanmakuToggleButton(isOn: $danmakuEnabled)
                    .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            // 在线人数：随控制条唤起显示在播放窗口左上角
            if controlsVisible, let text = playerController.onlineText {
                OnlineBadge(text: text)
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

/// 播放窗口左上角“在线人数”徽标。
private struct OnlineBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("\(text) 人在看")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.5)))
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}

/// 视频窗口子类：类名包含 Fullscreen，让 AppDelegate 的窗口特判自动生效
/// （不接管 delegate、关闭放行、排除出 mainWindow 查找）。
private final class VideoFullscreenWindow: NSWindow {
    /// 无边框窗口默认不能成为 key 窗口，导致收不到键盘事件
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 视频窗口关闭守卫：全屏态下 Cmd+W 先退出全屏；分离态下恢复吸附；
/// 嵌入态下转给主窗口。
private final class VideoWindowCloseGuard: NSObject, NSWindowDelegate {
    var parentResolver: (() -> NSWindow?)?
    var isDetachedProvider: (() -> Bool)?
    var onDetachRestore: (() -> Void)?
    /// 进入全屏时的目标屏幕（决定放大到哪块屏幕）。
    var fullscreenScreenProvider: (() -> NSScreen?)?
    /// 退出全屏时窗口应缩小到的 frame（当前嵌入位 / 分离前位置）。
    var fullscreenRestoreFrameProvider: (() -> CGRect)?
    /// 系统全屏切换失败（罕见）时复位内部状态。
    var onFailFullscreenTransition: (() -> Void)?

    // 自接管进出全屏的窗口动画（返回非空才会调用下面的 startCustomAnimation…）：
    // 系统仍负责切换 Space，这里只让窗口 frame 与系统动画同节奏地连续缩放，
    // 内容（画面/弹幕/控制条）实时跟随，效果等同系统“最大化”式原生 zoom。
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
        if isDetachedProvider?() == true {
            onDetachRestore?()
            return false
        }
        parentResolver?()?.performClose(nil)
        return false
    }
}

/// 锚点：实时上报视频区域在屏幕坐标中的 frame（含滚动/窗口移动/缩放），
/// 用于把视频窗口钉在主窗口的视频区域上。SwiftUI 状态更新（如播放器就绪）
/// 走 report(force: true)，保证首次建窗一定触发；滚动/移动等布局变化
/// 走去重路径，frame 未变化时不上报，避免重复 setFrame 造成卡顿。
struct FrameReporter: NSViewRepresentable {
    let onFrame: (CGRect) -> Void
    /// 播放器就绪等状态翻转时置 true，强制上报一次（幂等：只在状态变化时触发，
    /// 不会像无条件 force 那样在每次重绘时重复建窗）。
    var force: Bool = false

    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.onFrame = onFrame
        if nsView.lastForce != force {
            nsView.lastForce = force
            nsView.report(force: true)
        } else {
            nsView.report()
        }
    }

    final class FrameView: NSView {
        var onFrame: (CGRect) -> Void = { _ in }
        var lastForce = false
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
            report(force: true)
        }

        func report(force: Bool = false) {
            guard let window else { return }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            guard frame.width >= 4, frame.height >= 4 else {
                lastReported = nil
                return
            }
            if !force, let lastReported, framesEqual(lastReported, frame) { return }
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
