import SwiftUI

/// 统一的动效参数（苹果设计语言：弹性弹簧曲线 + 轻量缩放）。
enum Motion {
    /// 悬停反馈：轻快、干净
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.8)
}

// MARK: - 悬停缩放

struct HoverScaleModifier: ViewModifier {
    var scale: CGFloat = 1.02
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .animation(Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 鼠标靠近时平滑放大（首页卡片同款动效）。
    func hoverScale(scale: CGFloat = 1.02) -> some View {
        modifier(HoverScaleModifier(scale: scale))
    }
}
