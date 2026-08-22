import SwiftUI

/// 全局内容卡片背景，样式由设置项“卡片样式”控制：
/// - 液态玻璃：系统 glassEffect 材质
/// - 实色卡片：controlBackgroundColor 实色背景 + 描边（无阴影），App Store 风格
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 18
    @AppStorage("cardStyle") private var cardStyle = CardStyle.solid.rawValue

    func body(content: Content) -> some View {
        Group {
            if cardStyle == CardStyle.glass.rawValue {
                glassBody(content)
            } else {
                solidBody(content)
            }
        }
    }

    @ViewBuilder
    private func glassBody(_ content: Content) -> some View {
        content.background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.white.opacity(0.05))
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private func solidBody(_ content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    func contentCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}
