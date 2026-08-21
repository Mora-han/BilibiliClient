import AppKit
import SwiftUI

/// App Store 式卡片放大转场（macOS 无系统 zoom transition，自实现）：
/// 点击卡片时用透明覆盖窗口显示缩略图，从卡片原位放大到详情页播放区；
/// 返回时再缩回卡片原位，播放器画面全程无缝衔接。
@MainActor
final class HeroController: ObservableObject {
    static let shared = HeroController()

    @Published private(set) var isActive = false
    @Published var imageURL: String?
    @Published var currentFrame: CGRect = .zero
    @Published var opacity: Double = 1

    private(set) var sourceFrame: CGRect = .zero

    private var window: NSWindow?
    private var animationTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    // MARK: - 进入（卡片 → 播放区）

    /// 点击卡片：在卡片原位显示缩略图覆盖层（导航由 NavigationLink 正常触发）。
    func start(imageURL: String, from frame: CGRect) {
        guard !frame.isEmpty, frame.width > 1, frame.height > 1 else { return }
        animationTask?.cancel()
        settleTask?.cancel()
        self.imageURL = imageURL
        sourceFrame = frame
        currentFrame = frame
        opacity = 1
        isActive = true
        showWindow()
    }

    /// 详情页播放区持续上报位置；稳定一段时间后视为目标帧并开始放大。
    func offerDestination(_ frame: CGRect) {
        guard isActive, !frame.isEmpty, frame.width > 1, frame.height > 1 else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self else { return }
            self.animate(to: frame)
        }
    }

    private func animate(to frame: CGRect) {
        withAnimation(Motion.hero) {
            currentFrame = frame
        }
        animationTask?.cancel()
        animationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.55))
            guard !Task.isCancelled, let self else { return }
            self.fadeOut()
        }
    }

    // MARK: - 返回（播放区 → 卡片原位）

    /// 点击返回：从播放区缩回卡片原位，动画结束后执行 completion（pop）。
    func reverse(from frame: CGRect, to source: CGRect, completion: @escaping () -> Void) {
        guard isActive else {
            completion()
            return
        }
        animationTask?.cancel()
        settleTask?.cancel()
        sourceFrame = source
        currentFrame = frame
        opacity = 1
        showWindow()

        withAnimation(Motion.hero) {
            currentFrame = source
        }
        animationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.55))
            guard !Task.isCancelled, let self else { return }
            completion()
            try? await Task.sleep(for: .seconds(0.22))
            self.hideWindow()
        }
    }

    // MARK: - 结束

    private func fadeOut() {
        withAnimation(.easeOut(duration: 0.14)) {
            opacity = 0
        }
        animationTask?.cancel()
        animationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.hideWindow()
        }
    }

    private func hideWindow() {
        window?.orderOut(nil)
        isActive = false
        imageURL = nil
        currentFrame = .zero
        opacity = 1
        animationTask?.cancel()
        settleTask?.cancel()
    }

    // MARK: - 覆盖窗口

    private func showWindow() {
        let screen = NSScreen.screens.first { $0.frame.intersects(sourceFrame) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if window == nil {
            let hosting = NSHostingView(rootView: HeroOverlayView(controller: self))
            let win = NSWindow(contentRect: screen?.frame ?? .zero,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false)
            win.isReleasedWhenClosed = false
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .floating
            win.contentView = hosting
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            window = win
        }
        // 窗口随源位置所在屏幕放置（多显示器时跟随）
        if let screen, window?.frame != screen.frame {
            window?.setFrame(screen.frame, display: false)
        }
        window?.orderFront(nil)
    }

    /// 页面消失等场景：取消进行中的转场并清理。
    func cancel() {
        animationTask?.cancel()
        settleTask?.cancel()
        hideWindow()
    }
}

/// 覆盖窗口内容：在指定屏幕位置绘制正在放大的缩略图。
private struct HeroOverlayView: View {
    @ObservedObject var controller: HeroController

    var body: some View {
        GeometryReader { geo in
            if controller.isActive, let url = controller.imageURL.flatMap(Formatters.https) {
                RemoteImage(url: url)
                    .frame(width: controller.currentFrame.width,
                           height: controller.currentFrame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                    .position(x: controller.currentFrame.midX,
                              y: geo.size.height - controller.currentFrame.midY)
                    .opacity(controller.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 上报视图在屏幕坐标系（左下角原点）中的 frame，供 hero 转场使用。
struct ScreenFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ReportingNSView {
        let view = ReportingNSView()
        view.onFrameChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingNSView, context: Context) {
        nsView.onFrameChange = onChange
    }
}

final class ReportingNSView: NSView {
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
