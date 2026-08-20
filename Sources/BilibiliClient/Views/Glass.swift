import SwiftUI

struct GlassCardBackground: ViewModifier {
    var cornerRadius: CGFloat = 18

    func body(content: Content) -> some View {
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
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius))
    }
}
