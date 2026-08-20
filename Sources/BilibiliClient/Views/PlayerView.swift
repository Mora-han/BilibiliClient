import AVKit
import SwiftUI

/// 自绘 AVPlayerView 包装。
/// 不用 SwiftUI 的 VideoPlayer：旧 SDK 生成的 VideoPlayerView 元数据
/// 与 macOS 27 运行时不兼容（superclass demangle 失败直接 abort）。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// 播放器视图在屏幕上的位置（用于全屏进出动画的起止帧）
    var onScreenFrame: ((CGRect) -> Void)? = nil
    /// 是否显示系统原生全屏按钮（纯享模式用）
    var showsNativeFullscreen: Bool = false

    func makeNSView(context: Context) -> AVPlayerView {
        let view = FrameReportingPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // 平滑全屏由自定义窗口承载（带弹幕），此时禁用系统自带全屏按钮
        view.showsFullScreenToggleButton = showsNativeFullscreen
        view.onFrameChange = onScreenFrame
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        if let view = nsView as? FrameReportingPlayerView {
            view.onFrameChange = onScreenFrame
            if view.showsFullScreenToggleButton != showsNativeFullscreen {
                view.showsFullScreenToggleButton = showsNativeFullscreen
            }
        }
    }
}

/// 上报自己在屏幕坐标中的 frame（左下角原点），供全屏动画使用。
private final class FrameReportingPlayerView: AVPlayerView {
    var onFrameChange: ((CGRect) -> Void)?
    private var lastReported: CGRect = .zero

    override func layout() {
        super.layout()
        report()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    private func report() {
        guard let window else { return }
        let screenFrame = window.convertToScreen(convert(bounds, to: nil))
        if screenFrame != lastReported {
            lastReported = screenFrame
            onFrameChange?(screenFrame)
        }
    }
}
