import SwiftUI

/// App Store 风格普通内容卡片：实色背景（随浅/深色自适应）+ 圆角 + 轻阴影，
/// 不再使用液态玻璃材质。
struct SolidCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: .black.opacity(0.07), radius: 9, x: 0, y: 2)
    }
}

extension View {
    func solidCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(SolidCardBackground(cornerRadius: cornerRadius))
    }
}
