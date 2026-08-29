import AppKit
import AVFoundation
import SwiftUI

/// 自研播放器渲染视图：用 AVPlayerLayer 输出视频画面，
/// 完全绕开 AVKit 的 AVPlayerView（系统控制条与系统全屏黑盒行为）。
struct CustomPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// 承载 AVPlayerLayer 的视图：负责视频渲染与键盘控制。
final class PlayerLayerView: NSView {
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
