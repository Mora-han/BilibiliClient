import AppKit
import SwiftUI

/// 视频播放组件：系统 AVPlayerView（画面 + 原生播放控件 + 原生全屏）+ 弹幕层。
///
/// 这个视图不包含任何窗口逻辑——它既可以直接放在播放页里（默认形态），
/// 也可以在点击“分离窗口”时被放进按需创建的窗口中使用。播放与全屏（含全屏
/// 动画）全部由 AVKit 负责，这里不再自绘播放/全屏控件。
///
/// 观看人数、弹幕开关、分离窗口都不再浮在画面上：页内放在视频下方那一行
/// （与清晰度切换同排），分离窗口里则完全交给系统控件条，画面全净。
struct VideoPlayerSurface: View {
    @ObservedObject var playerController: PlayerController
    let engine: DanmakuEngine
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true

    var body: some View {
        ZStack {
            Color.black
            if let player = playerController.player {
                PlayerSurfaceView(player: player,
                                  engine: engine,
                                  danmakuEnabled: danmakuEnabled,
                                  isLive: false,
                                  onSpace: { playerController.togglePlay() },
                                  onSkip: { playerController.skip(by: $0) })
                    .id(player)
            }
        }
        .clipped()
    }
}

/// 播放区域左上角“在线人数”徽标。
struct PlayerOnlineBadge: View {
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

/// 播放区域最近一次的屏幕 frame（由 `PlayerAreaReporter` 持续写入）。
/// 用引用类型保存，避免布局期间写 @State 触发 SwiftUI 警告。
final class PlayerAreaFrameBox {
    var frame: CGRect = .zero
}

/// 锚点：实时上报播放区域在屏幕坐标中的 frame（含滚动/窗口移动/缩放）。
/// 播放区域平时就是页面里的普通视图，只有需要创建播放窗口（分离/全屏）时
/// 才用它把窗口精确覆盖到画面所在位置。
struct PlayerAreaReporter: NSViewRepresentable {
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameView {
        let view = FrameView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ nsView: FrameView, context: Context) {
        nsView.onFrame = onFrame
        nsView.report()
    }

    final class FrameView: NSView {
        var onFrame: (CGRect) -> Void = { _ in }
        private var lastReported: CGRect?
        private var windowObservers: [NSObjectProtocol] = []
        private var scrollObserver: NSObjectProtocol?

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
            report()
        }

        deinit {
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func report() {
            guard let window else { return }
            let frame = window.convertToScreen(convert(bounds, to: nil))
            guard frame.width >= 4, frame.height >= 4 else {
                lastReported = nil
                return
            }
            if let lastReported, Self.framesEqual(lastReported, frame) { return }
            lastReported = frame
            onFrame(frame)
        }

        private static func framesEqual(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.origin.x - b.origin.x) < 0.5
                && abs(a.origin.y - b.origin.y) < 0.5
                && abs(a.width - b.width) < 0.5
                && abs(a.height - b.height) < 0.5
        }
    }
}
