import AVKit
import SwiftUI

/// 自绘 AVPlayerView 包装。
/// 不用 SwiftUI 的 VideoPlayer：旧 SDK 生成的 VideoPlayerView 元数据
/// 与 macOS 27 运行时不兼容（superclass demangle 失败直接 abort）。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
