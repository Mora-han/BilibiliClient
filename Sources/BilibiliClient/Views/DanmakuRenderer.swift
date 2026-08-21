import AppKit
import AVFoundation
import CoreText
import QuartzCore
import SwiftUI

/// 弹幕渲染器：作为 AVPlayerView.contentOverlayView 的子视图，
/// 与视频同层级、随全屏动画一起走。
///
/// 每个弹幕在生成时用 Core Text 光栅化成一张图片：
/// 先画“仅描边”的轮廓，再画填充色盖住内圈，得到只在字形外缘的描边
/// （B 站官方样式，无笔画交叉伪影）。此后每帧只移动图层位置，
/// CADisplayLink 按显示器最高刷新率驱动，全屏/内嵌均丝滑。
final class DanmakuRenderView: NSView {
    var engine: DanmakuEngine?
    var player: AVPlayer?

    private var link: CADisplayLink?
    private var layers: [Int: CALayer] = [:]
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

    // MARK: - 驱动

    private func updateLink() {
        if window != nil && !isHiddenOrHasHiddenAncestor {
            guard link == nil else { return }
            let newLink = displayLink(target: self, selector: #selector(frameTick))
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
        guard let engine, let player else { return }
        let raw = player.currentTime().seconds
        guard raw.isFinite else { return }

        // 时间平滑：瞬时尖峰不生效；连续两帧确认的大跳变（拖动进度条）才接受。
        // 暂停时阈值更小，暂停瞬间的时间抖动不会让弹幕前移。
        var time = raw
        if lastTime >= 0 {
            let delta = raw - lastTime
            let threshold: Double = player.timeControlStatus == .paused ? 0.05 : 0.5
            if abs(delta) > threshold {
                if let pending = pendingJump, abs(raw - pending) < 0.02 {
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
        let backing = window?.backingScaleFactor ?? 2

        for item in items {
            let textLayer: CALayer
            if let existing = layers[item.id] {
                textLayer = existing
            } else {
                textLayer = Self.makeLayer(for: item, backing: backing)
                host.addSublayer(textLayer)
                layers[item.id] = textLayer
            }
            // 引擎坐标是左上原点，CALayer 坐标系为左下原点
            let point = item.position(in: size, at: time)
            textLayer.position = CGPoint(x: point.x, y: size.height - point.y)
        }
    }

    /// 生成弹幕图层：一次性光栅化（外描边 + 填充色），此后仅移动位置。
    private static func makeLayer(for item: DanmakuEngine.Active, backing: CGFloat) -> CALayer {
        let image = rasterize(item, scale: backing)
        let textLayer = CALayer()
        textLayer.contents = image
        textLayer.contentsScale = backing
        textLayer.bounds = CGRect(x: 0, y: 0,
                                  width: CGFloat(image.width) / backing,
                                  height: CGFloat(image.height) / backing)
        textLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return textLayer
    }

    /// 光栅化弹幕文字：先画外描边，再画填充色覆盖内圈 → 只在字形外缘有描边。
    private static func rasterize(_ item: DanmakuEngine.Active, scale: CGFloat) -> CGImage {
        let font = NSFont.systemFont(ofSize: 20 * item.scale, weight: .bold)
        let text = item.text
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(item.color),
        ]
        let strokeAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .strokeColor: NSColor.black,
            .strokeWidth: 3.0,  // 正数：仅画描边轮廓
        ]

        let measure = (text as NSString).size(withAttributes: fillAttributes)
        let padding: CGFloat = 6
        let pixelWidth = max(Int(ceil((measure.width + padding * 2) * scale)), 1)
        let pixelHeight = max(Int(ceil((measure.height + padding * 2) * scale)), 1)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Self.emptyImage(width: pixelWidth, height: pixelHeight)
        }
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity

        let baseline = CGPoint(x: padding, y: padding + font.ascender)
        // 1) 外描边轮廓
        context.textPosition = baseline
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                                                                      attributes: strokeAttributes)),
                   context)
        // 2) 填充色（盖住描边内侧，只留外侧）
        context.textPosition = baseline
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,
                                                                      attributes: fillAttributes)),
                   context)

        return context.makeImage() ?? Self.emptyImage(width: pixelWidth, height: pixelHeight)
    }

    private static func emptyImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: max(width, 1),
                                      height: max(height, 1),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("cannot create CGContext")
        }
        return context.makeImage()!
    }

    private func removeAllLayers() {
        for textLayer in layers.values {
            textLayer.removeFromSuperlayer()
        }
        layers.removeAll()
    }
}

/// 播放器上的弹幕开关（读取 AppStorage，内嵌与全屏共用同一实例）。
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

/// 开关宿主：独立 @AppStorage，供 NSHostingView 使用。
struct DanmakuToggleHost: View {
    @AppStorage("danmakuEnabled") private var enabled = true

    var body: some View {
        DanmakuToggleButton(isOn: $enabled)
    }
}
