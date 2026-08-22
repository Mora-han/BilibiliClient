import AVKit
import SwiftUI

/// 自绘 AVPlayerView 包装。
/// 不用 SwiftUI 的 VideoPlayer：旧 SDK 生成的 VideoPlayerView 元数据
/// 与 macOS 27 运行时不兼容（superclass demangle 失败直接 abort）。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// 进入/退出系统原生全屏的回调（用于把弹幕层挂进全屏窗口）
    var onWillEnterFullscreen: ((AVPlayerView) -> Void)? = nil
    var onEnterFullscreen: ((AVPlayerView) -> Void)? = nil
    var onExitFullscreen: ((AVPlayerView) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = KeyboardPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        // 系统原生全屏（带系统动画），弹幕由代理回调挂进全屏窗口
        view.showsFullScreenToggleButton = true
        view.delegate = context.coordinator
        context.coordinator.onWillEnterFullscreen = onWillEnterFullscreen
        context.coordinator.onEnterFullscreen = onEnterFullscreen
        context.coordinator.onExitFullscreen = onExitFullscreen
        return view
    }

    final class KeyboardPlayerView: AVPlayerView {
        private var pendingDirection: Int?
        private var longPressTimer: Timer?
        private var baseRate: Float = 1

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            true
        }

        override func keyDown(with event: NSEvent) {
            guard event.keyCode == 123 || event.keyCode == 124 else {
                super.keyDown(with: event)
                return
            }
            guard pendingDirection == nil else { return }
            pendingDirection = event.keyCode == 124 ? 1 : -1
            baseRate = player?.rate ?? 1
            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
                guard let self, let direction = self.pendingDirection else { return }
                self.player?.rate = direction > 0 ? 2.0 : 0.5
            }
        }

        override func keyUp(with event: NSEvent) {
            guard event.keyCode == 123 || event.keyCode == 124,
                  let direction = pendingDirection else {
                super.keyUp(with: event)
                return
            }
            longPressTimer?.invalidate()
            longPressTimer = nil
            let wasLongPress = player?.rate == 2.0 || player?.rate == 0.5
            if wasLongPress {
                player?.rate = baseRate
            } else if let player {
                let delta = CMTime(seconds: direction > 0 ? 5 : -5, preferredTimescale: 600)
                let target = CMTimeAdd(player.currentTime(), delta)
                player.seek(to: target)
            }
            pendingDirection = nil
        }

        deinit {
            longPressTimer?.invalidate()
        }
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        context.coordinator.onWillEnterFullscreen = onWillEnterFullscreen
        context.coordinator.onEnterFullscreen = onEnterFullscreen
        context.coordinator.onExitFullscreen = onExitFullscreen
    }

    final class Coordinator: NSObject, AVPlayerViewDelegate {
        var onWillEnterFullscreen: ((AVPlayerView) -> Void)?
        var onEnterFullscreen: ((AVPlayerView) -> Void)?
        var onExitFullscreen: ((AVPlayerView) -> Void)?

        func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
            onWillEnterFullscreen?(playerView)
        }

        func playerViewDidEnterFullScreen(_ playerView: AVPlayerView) {
            onEnterFullscreen?(playerView)
        }

        func playerViewDidExitFullScreen(_ playerView: AVPlayerView) {
            onExitFullscreen?(playerView)
        }
    }
}
