import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// 弹幕层：CADisplayLink 按显示器最高刷新率逐帧驱动（160Hz/120Hz/ProMotion），
/// 渲染采用 Core Animation（每个弹幕一个 CATextLayer），
/// 只更新图层位置，避免 SwiftUI 逐帧重绘带来的开销，全屏/内嵌都丝滑。
struct DanmakuOverlayView: View {
    @ObservedObject var engine: DanmakuEngine
    let player: AVPlayer
    let enabled: Bool
    /// 全屏窗口打开时，内嵌层的驱动挂起，只由全屏层驱动引擎
    var suspended: Bool = false

    var body: some View {
        GeometryReader { geo in
            DanmakuRenderer(engine: engine,
                            player: player,
                            isActive: enabled && !suspended)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: enabled) { _, newValue in
            if !newValue {
                // 关闭开关：立即清掉屏幕上已有的弹幕
                engine.clear()
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }
}

/// 渲染器：NSView + CATextLayer，display link 驱动。
private struct DanmakuRenderer: NSViewRepresentable {
    @ObservedObject var engine: DanmakuEngine
    let player: AVPlayer
    let isActive: Bool

    func makeNSView(context: Context) -> DanmakuRenderView {
        let view = DanmakuRenderView()
        view.engine = engine
        view.player = player
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: DanmakuRenderView, context: Context) {
        view.engine = engine
        view.player = player
        view.isActive = isActive
    }
}

private final class DanmakuRenderView: NSView {
    var engine: DanmakuEngine?
    var player: AVPlayer?
    var isActive = false {
        didSet {
            if isActive != oldValue {
                updateLink()
            }
        }
    }

    private var link: CADisplayLink?
    private var layers: [Int: CATextLayer] = [:]
    private var lastTime: Double = -1
    private var pendingJump: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil  // 弹幕不拦截鼠标
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 窗口在不同缩放比屏幕间移动时保持文字清晰
        let scale = window?.backingScaleFactor ?? 2
        for textLayer in layers.values {
            textLayer.contentsScale = scale
        }
    }

    // MARK: - 驱动

    private func updateLink() {
        let shouldRun = isActive && window != nil && !isHiddenOrHasHiddenAncestor
        if shouldRun {
            guard link == nil else { return }
            let newLink = displayLink(target: self, selector: #selector(frameTick))
            // 跟随显示器最高刷新率（160Hz 显示即 160fps 回调）
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 240)
            newLink.add(to: .main, forMode: .common)
            link = newLink
        } else {
            link?.invalidate()
            link = nil
            removeAllLayers()
        }
    }

    @objc private func frameTick() {
        guard let engine, let player, isActive else { return }
        let raw = player.currentTime().seconds
        guard raw.isFinite else { return }

        // 时间平滑：瞬时尖峰（如暂停瞬间 currentTime 抖动）不生效；
        // 连续两帧确认的大跳变（拖动进度条 seek）才接受
        var time = raw
        if lastTime >= 0 {
            let delta = raw - lastTime
            if abs(delta) > 0.5 {
                if let pending = pendingJump, abs(raw - pending) < 0.05 {
                    lastTime = raw
                    pendingJump = nil
                } else {
                    pendingJump = raw
                    time = lastTime
                }
            } else {
                lastTime = raw
                pendingJump = nil
            }
        } else {
            lastTime = raw
        }

        let size = bounds.size
        engine.tick(playerTime: time, size: size)
        render(engine.active, size: size, time: time)
    }

    // MARK: - 渲染

    private func render(_ items: [DanmakuEngine.Active], size: CGSize, time: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let activeIDs = Set(items.map(\.id))
        for (id, textLayer) in layers where !activeIDs.contains(id) {
            textLayer.removeFromSuperlayer()
            layers[id] = nil
        }
        guard let host = layer else { return }

        for item in items {
            let textLayer: CATextLayer
            if let existing = layers[item.id] {
                textLayer = existing
            } else {
                textLayer = Self.makeLayer(for: item)
                host.addSublayer(textLayer)
                layers[item.id] = textLayer
            }
            // 引擎坐标是左上原点，CALayer 坐标系为左下原点
            let point = item.position(in: size, at: time)
            textLayer.position = CGPoint(x: point.x, y: size.height - point.y)
        }
    }

    private static func makeLayer(for item: DanmakuEngine.Active) -> CATextLayer {
        let font = NSFont.systemFont(ofSize: 20 * item.scale, weight: .bold)
        // 不描边，只保留弹幕原色（CATextLayer 描边在笔画交叉处会有伪影）
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(item.color),
        ]
        let attributed = NSAttributedString(string: item.text, attributes: attributes)
        let textSize = attributed.size()

        let textLayer = CATextLayer()
        textLayer.string = attributed
        textLayer.isWrapped = false
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.bounds = CGRect(origin: .zero, size: textSize)
        textLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return textLayer
    }

    private func removeAllLayers() {
        for textLayer in layers.values {
            textLayer.removeFromSuperlayer()
        }
        layers.removeAll()
    }
}

/// 播放器右上角的弹幕开关（液态玻璃胶囊样式）。
struct DanmakuToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "text.bubble.fill" : "text.bubble")
                Text("弹幕")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.55))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.black.opacity(0.35))
                    .overlay {
                        if #available(macOS 26.0, *) {
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                                .glassEffect(.regular, in: .capsule)
                        } else {
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .help(isOn ? "关闭弹幕" : "开启弹幕")
    }
}
