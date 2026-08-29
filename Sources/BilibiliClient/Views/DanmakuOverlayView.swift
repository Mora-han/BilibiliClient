import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// 叠在播放器上的弹幕层：由 CADisplayLink 按显示器最高刷新率逐帧驱动引擎，
/// 按播放时间渲染活跃弹幕（160Hz/120Hz/ProMotion 均可跑满）。
struct DanmakuOverlayView: View {
    @ObservedObject var engine: DanmakuEngine
    let player: AVPlayer
    let enabled: Bool
    /// 全屏窗口打开时，内嵌层的驱动挂起，只由全屏层驱动引擎
    var suspended: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if enabled && !suspended {
                    // 单个 Canvas 一帧绘制所有弹幕：避免几十个 SwiftUI Text 视图
                    // 逐帧布局/重绘，全屏大字号下依然能跑满高刷新率。
                    Canvas { context, size in
                        guard !engine.active.isEmpty else { return }
                        let time = engine.renderTime
                        // 阴影滤镜加在 drawLayer 之前，只对整层合成做一次离屏模糊；
                        // 若逐条绘制时开滤镜，每条文字都会触发一次离屏栅格化。
                        context.addFilter(.shadow(color: .black.opacity(0.85),
                                                  radius: 2, x: 0, y: 1))
                        context.drawLayer { layer in
                            for item in engine.active {
                                // macOS 26 SDK 中 Text.foregroundColor/foregroundStyle 会擦除类型，
                                // 改用 AttributedString 携带字体与颜色，Text 类型保持可用。
                                var attr = AttributedString(item.text)
                                attr.font = .system(size: item.fontSize(for: size.width),
                                                    weight: .medium)
                                attr.foregroundColor = item.color
                                layer.draw(Text(attr), at: item.position(in: size, at: time))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                // 逐帧回调与所在显示器刷新同步；暂停时 playerTime 不变，弹幕自然冻结
                DisplayLinkDriver(isActive: enabled && !suspended) {
                    engine.tick(playerTime: player.currentTime().seconds, size: geo.size)
                }
            }
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

/// 用 NSView.displayLink 获取与显示器刷新同步的逐帧回调。
private struct DisplayLinkDriver: NSViewRepresentable {
    var isActive: Bool
    let onTick: () -> Void

    func makeNSView(context: Context) -> DisplayLinkDriverView {
        let view = DisplayLinkDriverView()
        view.isActive = isActive
        view.onTick = onTick
        return view
    }

    func updateNSView(_ view: DisplayLinkDriverView, context: Context) {
        view.isActive = isActive
        view.onTick = onTick
    }
}

private final class DisplayLinkDriverView: NSView {
    var isActive = false {
        didSet {
            if isActive != oldValue {
                updateLink()
            }
        }
    }
    var onTick: (() -> Void)?
    private var link: CADisplayLink?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let shouldRun = isActive && window != nil && !isHiddenOrHasHiddenAncestor
        if shouldRun {
            guard link == nil else { return }
            let newLink = displayLink(target: self, selector: #selector(frameTick))
            // 弹幕是低细节文本，60fps 已足够顺滑；上限 60 避免全屏大画布
            // 在 160Hz 显示器上每帧全量重绘导致渲染压力过大。
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60)
            newLink.add(to: .main, forMode: .common)
            link = newLink
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func frameTick() {
        onTick?()
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
