import AppKit
import AVFoundation
import SwiftUI

/// 把弹幕层挂进 AVPlayerView 系统原生全屏窗口：
/// 全屏使用系统动画（纯享模式的动画），弹幕与开关随全屏一起显示。
@MainActor
final class NativeFullscreenDanmaku {
    private var hosts: [NSView] = []

    var isAttached: Bool { !hosts.isEmpty }

    /// 在指定窗口（系统全屏窗口）上附加弹幕层与弹幕开关。
    func attach(engine: DanmakuEngine, player: AVPlayer, to window: NSWindow?) {
        detach()
        guard let content = window?.contentView else { return }

        // 弹幕渲染层：整窗口铺满，点击穿透。
        // 注意：不要对 NSHostingView 强制 wantsLayer / 手动设置 layer，
        // 否则会脱离系统默认渲染管线，Retina 下文字变糊、出现残影。
        let overlay = HitTransparentHostingView(rootView: FullscreenDanmakuLayer(engine: engine, player: player))
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        hosts.append(overlay)

        // 弹幕开关：右上角，可点击
        let toggle = NSHostingView(rootView: FullscreenDanmakuToggle())
        let toggleWidth: CGFloat = 96
        let toggleHeight: CGFloat = 34
        toggle.frame = NSRect(x: content.bounds.maxX - toggleWidth - 14,
                              y: content.bounds.maxY - toggleHeight - 14,
                              width: toggleWidth,
                              height: toggleHeight)
        toggle.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(toggle)
        hosts.append(toggle)
    }

    func detach() {
        for host in hosts {
            host.removeFromSuperview()
        }
        hosts = []
    }
}

/// 点击穿透的 NSHostingView（弹幕不挡播放器控制条）。
private final class HitTransparentHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// 全屏弹幕层：跟随播放时间驱动引擎并渲染（独立 @AppStorage 读取开关状态）。
private struct FullscreenDanmakuLayer: View {
    @ObservedObject var engine: DanmakuEngine
    let player: AVPlayer
    @AppStorage("danmakuEnabled") private var enabled = true

    var body: some View {
        DanmakuOverlayView(engine: engine,
                           player: player,
                           enabled: enabled,
                           suspended: false)
    }
}

/// 全屏弹幕开关（独立 hosting，可点击）。
private struct FullscreenDanmakuToggle: View {
    @AppStorage("danmakuEnabled") private var enabled = true

    var body: some View {
        DanmakuToggleButton(isOn: $enabled)
    }
}
