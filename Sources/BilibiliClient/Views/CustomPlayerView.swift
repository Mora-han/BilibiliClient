import AppKit
import AVFoundation
import SwiftUI

/// 自研播放器渲染视图：用 AVPlayerLayer 输出视频画面，
/// 完全绕开 AVKit 的 AVPlayerView（系统控制条与系统全屏黑盒行为）。
struct CustomPlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// 空格键：播放/暂停
    var onSpace: (() -> Void)? = nil
    /// 左右方向键：快进/快退（正负秒数）
    var onSkip: ((Double) -> Void)? = nil
    /// 单击视频：播放/暂停
    var onSingleClick: (() -> Void)? = nil
    /// 双击视频：全屏切换
    var onDoubleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.onSpace = onSpace
        view.onSkip = onSkip
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.onSpace = onSpace
        nsView.onSkip = onSkip
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }
}

/// 承载 AVPlayerLayer 的视图：负责视频渲染、键盘快捷键与点击交互。
final class PlayerLayerView: NSView {
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
    var onSpace: (() -> Void)?
    var onSkip: ((Double) -> Void)?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var singleClickTask: Task<Void, Never>?
    /// 右方向键长按 2 倍速快进
    private var holdTask: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?
    private var becomeKeyObserver: NSObjectProtocol?
    private var rightKeyHeld = false
    private var holdTriggered = false
    private var rateBeforeHold: Float = 1
    private var wasPlayingBeforeHold = false

    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.isOpaque = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        singleClickTask?.cancel()
        holdTask?.cancel()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if let becomeKeyObserver {
            NotificationCenter.default.removeObserver(becomeKeyObserver)
        }
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.cancelHold()
            }
            // 窗口成为 key 时把键盘焦点给播放器：全屏下无需先点击即可用快捷键
            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.makeFirstResponderIfNeeded()
            }
            if window.isKeyWindow {
                makeFirstResponderIfNeeded()
            }
        } else {
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
            resignObserver = nil
            if let becomeKeyObserver {
                NotificationCenter.default.removeObserver(becomeKeyObserver)
            }
            becomeKeyObserver = nil
            cancelHold()
        }
    }

    /// 键盘焦点给播放器视图，保证全屏下快捷键立即可用；不抢正在编辑的输入框。
    private func makeFirstResponderIfNeeded() {
        guard let window, window.firstResponder !== self else { return }
        if let current = window.firstResponder as? NSView {
            if current is NSTextField || current is NSTextView { return }
        }
        window.makeFirstResponder(self)
    }

    // MARK: - 键盘与点击

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            singleClickTask?.cancel()
            singleClickTask = nil
            onDoubleClick?()
        } else if event.clickCount == 1 {
            // 延迟一拍确认不是双击后再触发单击动作
            singleClickTask?.cancel()
            singleClickTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.onSingleClick?()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:  // 空格
            onSpace?()
        case 123:  // ←
            onSkip?(-15)
        case 124:  // →
            // 按住期间的自动重复 keyDown 不重置长按计时
            guard !event.isARepeat else { return }
            rightKeyHeld = true
            holdTriggered = false
            holdTask?.cancel()
            // 按住超过 400ms 判定为长按：进入 2 倍速快进；短按仍快进 15 秒
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.rightKeyHeld, !self.holdTriggered else { return }
                self.holdTriggered = true
                self.beginFastForward()
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 124 {
            holdTask?.cancel()
            holdTask = nil
            if holdTriggered {
                endFastForward()
            } else {
                onSkip?(15)
            }
            rightKeyHeld = false
            holdTriggered = false
        } else {
            super.keyUp(with: event)
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

    /// 松开右方向键：恢复按住前的播放状态
    private func endFastForward() {
        guard let player else { return }
        if wasPlayingBeforeHold {
            player.rate = rateBeforeHold > 0 ? rateBeforeHold : 1
        } else {
            player.pause()
        }
    }

    /// 窗口失去焦点/移除：取消长按快进，避免倍速卡住
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
