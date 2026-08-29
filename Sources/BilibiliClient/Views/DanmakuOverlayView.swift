import AppKit
import AVFoundation
import CoreText
import QuartzCore
import SwiftUI

/// 弹幕渲染层：完全脱离 SwiftUI 渲染管线。
/// 每条弹幕 = 一个 CALayer（文字预渲染成带外侧描边的位图，由 GPU 缓存），
/// 独立 NSView 上的 CADisplayLink 每帧只做轻量位置计算与 layer 属性赋值，
/// 不触发任何 SwiftUI 视图更新或 Canvas 重绘，对视频渲染几乎零干扰。
struct DanmakuOverlayView: NSViewRepresentable {
    let engine: DanmakuEngine
    let player: AVPlayer
    let enabled: Bool

    func makeNSView(context: Context) -> DanmakuOverlayNSView {
        let view = DanmakuOverlayNSView(engine: engine, player: player)
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: DanmakuOverlayNSView, context: Context) {
        view.player = player
        view.enabled = enabled
    }
}

/// 弹幕承载视图：透明、不拦截鼠标、生命周期与窗口绑定（窗口消失即停表）。
final class DanmakuOverlayNSView: NSView {
    let engine: DanmakuEngine
    weak var player: AVPlayer? {
        didSet {
            if player !== oldValue { updateLink() }
        }
    }
    var enabled = false {
        didSet {
            if enabled != oldValue {
                if !enabled { removeAllLayers() }
                updateLink()
            }
        }
    }

    private var link: CADisplayLink?
    private var layers: [Int: CALayer] = [:]
    private var lastSize: CGSize = .zero
    private var lastScale: CGFloat = 0

    init(engine: DanmakuEngine, player: AVPlayer?) {
        self.engine = engine
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 点击穿透到下层播放器
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 换屏/缩放比例变化：强制重建层，保证文字清晰
        lastScale = 0
    }

    deinit {
        link?.invalidate()
    }

    // MARK: - 驱动

    private func updateLink() {
        let shouldRun = enabled && window != nil && player != nil
        if shouldRun {
            guard link == nil else { return }
            let newLink = displayLink(target: self, selector: #selector(frameTick))
            // 跟随显示器原生刷新率（60/120/160Hz）：弹幕只是图层位移，
            // 高刷下每帧开销依然极低，不影响视频渲染
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 160)
            newLink.add(to: .main, forMode: .common)
            link = newLink
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func frameTick() {
        guard enabled, let player, let window else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = window.backingScaleFactor
        if scale != lastScale {
            lastScale = scale
            lastSize = .zero
        }
        if abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 {
            lastSize = size
            removeAllLayers()
        }

        let raw = player.currentTime().seconds
        // seek 瞬间可能返回非有限值：跳过本帧，由引擎的 seek 检测接管
        guard raw.isFinite else { return }
        engine.tick(playerTime: raw, size: size)
        syncLayers(size: size, scale: scale, time: raw)
    }

    // MARK: - 层同步

    private func syncLayers(size: CGSize, scale: CGFloat, time: Double) {
        guard !engine.active.isEmpty else {
            removeAllLayers()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var ids = Set<Int>()
        ids.reserveCapacity(engine.active.count)
        for item in engine.active {
            ids.insert(item.id)
            if let layer = layers[item.id] {
                layer.position = layerPosition(for: item, in: size, time: time)
            } else {
                addLayer(for: item, size: size, scale: scale, time: time)
            }
        }
        for (id, layer) in layers where !ids.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
    }

    private func addLayer(for item: DanmakuEngine.Active, size: CGSize, scale: CGFloat, time: Double) {
        let fontSize = item.fontSize(for: size.width)
        // 文字预渲染成带外侧描边的位图：黑色字 8 方向偏移 + 中心前景色字，
        // 描边只出现在字形最外侧，笔画交叉处不会被描边切断填充
        let image = Self.makeOutlineImage(text: item.text,
                                          color: item.color,
                                          fontSize: fontSize,
                                          scale: scale)
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        if let image {
            layer.bounds = CGRect(x: 0, y: 0,
                                  width: CGFloat(image.width) / scale,
                                  height: CGFloat(image.height) / scale)
        } else {
            layer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        layer.position = layerPosition(for: item, in: size, time: time)
        layer.actions = [
            "position": NSNull(),
            "contents": NSNull(),
        ]
        self.layer?.addSublayer(layer)
        layers[item.id] = layer
    }

    /// 预渲染文字位图：8 方向偏移的黑色描边 + 中心填充，返回已按 scale 放大的图。
    private static func makeOutlineImage(text: String, color: CGColor,
                                         fontSize: CGFloat, scale: CGFloat) -> CGImage? {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let fillColor = NSColor(cgColor: color) ?? .white
        let fill = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: fillColor
        ]))
        let outline = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black
        ]))
        let bounds = CTLineGetBoundsWithOptions(fill, [])
        let offset = max(1.2, fontSize * 0.07)
        let w = Int(ceil((bounds.width + offset * 2) * scale))
        let h = Int(ceil((bounds.height + offset * 2) * scale))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        let origin = CGPoint(x: offset - bounds.origin.x, y: offset - bounds.origin.y)
        for dx in [-1.0, 0.0, 1.0] {
            for dy in [-1.0, 0.0, 1.0] {
                if dx == 0 && dy == 0 { continue }
                ctx.textPosition = CGPoint(x: origin.x + offset * dx,
                                           y: origin.y + offset * dy)
                CTLineDraw(outline, ctx)
            }
        }
        ctx.textPosition = origin
        CTLineDraw(fill, ctx)
        return ctx.makeImage()
    }

    private func removeAllLayers() {
        guard !layers.isEmpty else { return }
        for layer in layers.values {
            layer.removeFromSuperlayer()
        }
        layers.removeAll()
    }

    /// 引擎坐标是左上角原点，AppKit 层坐标是左下角原点，翻转 Y
    private func layerPosition(for item: DanmakuEngine.Active,
                               in size: CGSize,
                               time: Double) -> CGPoint {
        let p = item.position(in: size, at: time)
        return CGPoint(x: p.x, y: size.height - p.y)
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
                        Capsule()
                            .stroke(.white.opacity(0.25), lineWidth: 1)
                            .glassEffect(.regular, in: .capsule)
                    }
            }
        }
        .buttonStyle(.plain)
        .help(isOn ? "关闭弹幕" : "开启弹幕")
    }
}
