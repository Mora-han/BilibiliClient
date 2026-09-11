import AVFoundation
import AVKit
import SwiftUI

/// 播放画面：直接使用系统 `AVPlayerView`。
///
/// 播放/暂停、进度、音量、倍速、画中画以及全屏（连同全屏动画）全部交给 AVKit：
/// 它的全屏按钮与双击都是系统原生全屏——画面从当前位置放大铺满屏幕，退出时
/// 平滑缩回原位。弹幕挂在 `contentOverlayView` 上（画面之上、原生控件之下），
/// 既不挡控件，自身也不拦截鼠标。
struct PlayerSurfaceView: NSViewRepresentable {
    let player: AVPlayer
    /// 弹幕引擎；直播没有叠加弹幕时传 nil
    let engine: DanmakuEngine?
    let danmakuEnabled: Bool
    let onSpace: () -> Void
    let onSkip: (Double) -> Void

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView()
        view.setPlayer(player)
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        // AVKit 自带全屏按钮默认关闭，打开后进入/退出全屏连同缩放动画都交给系统
        view.showsFullScreenToggleButton = true
        // “正在播放”统一由 SystemMediaCenter 上报，避免与 AVKit 互相覆盖
        view.updatesNowPlayingInfoCenter = false
        view.onSpace = onSpace
        view.onSkip = onSkip
        if let engine {
            view.installDanmaku(engine: engine, enabled: danmakuEnabled)
        }
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        view.setPlayer(player)
        view.onSpace = onSpace
        view.onSkip = onSkip
        view.setDanmakuEnabled(danmakuEnabled)
        view.attachDanmakuIfNeeded()
    }

    static func dismantleNSView(_ view: DanmakuPlayerView, coordinator: ()) {
        PlaybackMenuState.shared.detachPlayerView(view)
    }
}

/// `AVPlayerView` 子类：在原生控件之下挂弹幕层，并保留页面原有的键盘操作。
///
/// 两个要点：
/// 1. AVKit 的时间轴滑块会在播放项尚未就绪（时长为 NaN）时触发内部 precondition
///    崩溃，所以播放项 ready 之前一律收起控件条，就绪后再显示——全屏按钮也随之
///    在能播之后才出现。
/// 2. AVKit 的内部子视图会截走 hit-test 与第一响应者，直接重写 `keyDown` 在真实
///    点击画面后收不到按键，因此快捷键改用窗口级本地事件监听实现。
final class DanmakuPlayerView: AVPlayerView {
    var onSpace: (() -> Void)?
    var onSkip: ((Double) -> Void)?

    private var danmakuView: DanmakuOverlayNSView?
    private var danmakuEngine: DanmakuEngine?
    private var danmakuEnabled = false
    private var attachScheduled = false

    private var keyMonitor: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    /// AVKit 原生全屏期间，播放器在 AVKit 自己的全屏窗口里
    private var isNativeFullscreen = false
    private var holdTask: Task<Void, Never>?
    private var rightKeyHeld = false
    private var holdTriggered = false
    private var rateBeforeHold: Float = 1
    private var wasPlayingBeforeHold = false

    deinit {
        holdTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        itemStatusObservation?.invalidate()
    }

    // MARK: - 播放器与控件条

    /// 设置/更新播放器，并按播放项状态决定要不要显示 AVKit 控件条。
    func setPlayer(_ player: AVPlayer?) {
        if self.player !== player {
            self.player = player
            danmakuView?.player = player
        }
        observeItemStatus()
    }

    private func observeItemStatus() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        applyControlsStyle()
        guard let item = player?.currentItem else { return }
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] _, _ in
            Task { @MainActor in self?.applyControlsStyle() }
        }
    }

    /// 播放项就绪才显示原生控件条，避免 AVKit 滑块拿到 NaN 时长崩溃。
    private func applyControlsStyle() {
        let ready = player?.currentItem?.status == .readyToPlay
        let style: AVPlayerViewControlsStyle = ready ? .floating : .none
        if controlsStyle != style {
            controlsStyle = style
        }
    }

    // MARK: - 弹幕

    /// 把弹幕层挂到 AVKit 的内容覆盖层（画面之上、控件之下）。
    func installDanmaku(engine: DanmakuEngine, enabled: Bool) {
        danmakuEngine = engine
        danmakuEnabled = enabled
        attachDanmakuIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.attachDanmakuIfNeeded() }
    }

    func setDanmakuEnabled(_ enabled: Bool) {
        danmakuEnabled = enabled
        danmakuView?.enabled = enabled
    }

    func attachDanmakuIfNeeded() {
        guard danmakuView == nil,
              let engine = danmakuEngine,
              let overlay = contentOverlayView else { return }
        let view = DanmakuOverlayNSView(engine: engine, player: player)
        view.enabled = danmakuEnabled
        view.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            view.topAnchor.constraint(equalTo: overlay.topAnchor),
            view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])
        danmakuView = view
    }

    override func layout() {
        super.layout()
        // 布局过程中不能改视图树（会触发 layoutSubtreeIfNeeded 递归告警），延后一拍再挂
        guard danmakuView == nil, danmakuEngine != nil, !attachScheduled else { return }
        attachScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.attachScheduled = false
            self.attachDanmakuIfNeeded()
        }
    }

    // MARK: - 键盘

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if delegate == nil { delegate = self }
        // 挂上窗口即登记为"当前播放器"，顶部菜单的全屏开关据此找到它
        if window != nil {
            PlaybackMenuState.shared.attachPlayerView(self)
        } else {
            PlaybackMenuState.shared.detachPlayerView(self)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        cancelHold()
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    /// 返回 true 表示事件已被播放器消费。
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, let eventWindow = event.window, eventWindow.isKeyWindow else { return false }
        // AVKit 原生全屏时事件属于 AVKit 的全屏窗口
        guard eventWindow === window || isNativeFullscreen else { return false }
        // 正在输入框里打字（搜索框等）：不抢按键
        if let responder = eventWindow.firstResponder as? NSView,
           responder is NSTextField || responder is NSTextView {
            return false
        }
        // 带命令/控制/option 的组合键留给系统与菜单
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            return false
        }
        switch event.type {
        case .keyDown:
            switch event.keyCode {
            case 49:  // 空格
                guard !event.isARepeat else { return true }
                onSpace?()
                return true
            case 123:  // ←
                guard !event.isARepeat else { return true }
                onSkip?(-15)
                return true
            case 124:  // →
                // 按住期间的自动重复不重置长按计时
                guard !event.isARepeat else { return true }
                rightKeyHeld = true
                holdTriggered = false
                holdTask?.cancel()
                holdTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, self.rightKeyHeld, !self.holdTriggered else { return }
                    self.holdTriggered = true
                    self.beginFastForward()
                }
                return true
            default:
                return false
            }
        case .keyUp:
            guard event.keyCode == 124 else { return false }
            holdTask?.cancel()
            holdTask = nil
            if holdTriggered {
                endFastForward()
            } else {
                onSkip?(15)
            }
            rightKeyHeld = false
            holdTriggered = false
            return true
        default:
            return false
        }
    }

    /// 长按右方向键：进入 2 倍速（暂停时也以 2 倍速开始播放）
    private func beginFastForward() {
        guard let player else { return }
        rateBeforeHold = player.rate
        wasPlayingBeforeHold = player.timeControlStatus == .playing
        if wasPlayingBeforeHold {
            player.rate = 2
        } else {
            player.playImmediately(atRate: 2)
        }
    }

    private func endFastForward() {
        guard let player else { return }
        if wasPlayingBeforeHold {
            player.rate = rateBeforeHold > 0 ? rateBeforeHold : 1
        } else {
            player.pause()
        }
    }

    /// 交给 AVKit 自己的全屏入口——控件条上那个全屏按钮走的就是它。
    /// `enterFullScreen:` / `exitFullScreen:` 没有出现在公开头文件里，先探测再调用，
    /// 不可用时返回 false，由调用方退回窗口全屏。
    func toggleNativeFullscreen() -> Bool {
        let name = isNativeFullscreen ? "exitFullScreen:" : "enterFullScreen:"
        let selector = NSSelectorFromString(name)
        guard responds(to: selector) else { return false }
        _ = perform(selector, with: nil)
        return true
    }

    private func cancelHold() {
        guard rightKeyHeld else { return }
        holdTask?.cancel()
        holdTask = nil
        if holdTriggered {
            endFastForward()
        }
        rightKeyHeld = false
        holdTriggered = false
    }
}

extension DanmakuPlayerView: AVPlayerViewDelegate {
    /// 全屏动画开始：弹幕层冻结推进、整层缩放跟随，并开始预热目标尺寸的文字位图。
    /// 这条路径由 AVKit 精确开合，比轮询尺寸判断可靠得多。
    func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
        isNativeFullscreen = true
        PlaybackMenuState.shared.setFullscreen(true)
        danmakuView?.beginSizeTransition(target: window?.screen?.frame.size
            ?? NSScreen.main?.frame.size)
    }

    func playerViewDidEnterFullScreen(_ playerView: AVPlayerView) {
        danmakuView?.endSizeTransition()
    }

    func playerViewWillExitFullScreen(_ playerView: AVPlayerView) {
        danmakuView?.beginSizeTransition(target: nil)
    }

    func playerViewDidExitFullScreen(_ playerView: AVPlayerView) {
        isNativeFullscreen = false
        PlaybackMenuState.shared.setFullscreen(false)
        danmakuView?.endSizeTransition()
    }
}
