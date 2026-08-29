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
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
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
            onSkip?(15)
        default:
            super.keyDown(with: event)
        }
    }
}
