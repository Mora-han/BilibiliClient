import AVKit
import SwiftUI

/// AVPlayerView 包装：视频 + 弹幕层 + 弹幕开关。
/// 弹幕渲染视图放进 AVPlayerView.contentOverlayView（视频与控制条之间），
/// 作为播放器内容的一部分，全屏进出动画时自动跟随，无需额外挂载。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    @ObservedObject var engine: DanmakuEngine

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // 系统原生全屏（带系统动画），弹幕层随 contentOverlayView 一起走
        view.showsFullScreenToggleButton = true

        if let overlay = view.contentOverlayView {
            // 弹幕渲染层
            let render = DanmakuRenderView()
            render.engine = engine
            render.player = player
            render.frame = overlay.bounds
            render.autoresizingMask = [.width, .height]
            overlay.addSubview(render)
            context.coordinator.renderView = render

            // 弹幕开关（右上角，内嵌与全屏共用）
            let toggle = NSHostingView(rootView: DanmakuToggleHost())
            let toggleWidth: CGFloat = 96
            let toggleHeight: CGFloat = 34
            toggle.frame = NSRect(x: overlay.bounds.maxX - toggleWidth - 14,
                                  y: overlay.bounds.maxY - toggleHeight - 14,
                                  width: toggleWidth,
                                  height: toggleHeight)
            toggle.autoresizingMask = [.minXMargin, .minYMargin]
            overlay.addSubview(toggle)
        }
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        context.coordinator.renderView?.engine = engine
        context.coordinator.renderView?.player = player
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var renderView: DanmakuRenderView?
    }
}
