import SwiftUI

/// 统一的动效参数（苹果设计语言：弹性弹簧曲线 + 轻量缩放）。
enum Motion {
    /// 悬停反馈：轻快、干净
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.8)
}

// MARK: - 悬停反馈

struct HoverScaleModifier: ViewModifier {
    var scale: CGFloat = 1.02
    var cornerRadius: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if let cornerRadius {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.primary.opacity(hovering ? 0.15 : 0), lineWidth: 1)
                }
            }
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .animation(reduceMotion ? nil : Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 鼠标靠近时平滑放大（首页卡片同款动效）。
    func hoverScale(scale: CGFloat = 1.02, cornerRadius: CGFloat? = nil) -> some View {
        modifier(HoverScaleModifier(scale: scale, cornerRadius: cornerRadius))
    }
}
