import SwiftUI

/// 统一的动效参数（苹果设计语言：弹性弹簧曲线 + 轻量缩放）。
enum Motion {
    /// 悬停反馈：轻快、干净
    static let hover = Animation.spring(response: 0.28, dampingFraction: 0.8)
    /// 按压/强调反馈
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.72)
    /// 进出场大转场（App Store 式）
    static let hero = Animation.spring(response: 0.45, dampingFraction: 0.82)
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

// MARK: - 返回按钮

/// 带悬停动效的自定义返回按钮。
struct AnimatedBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.07))
                }
                .contentShape(Circle())
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
        }
        .buttonStyle(.plain)
        .help("返回")
    }
}

private struct AnimatedBackBarModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var onBack: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    AnimatedBackButton {
                        if let onBack {
                            onBack()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
    }
}

extension View {
    /// 隐藏系统返回按钮，换成带悬停放大动效的自定义返回按钮。
    /// 可传入 onBack 拦截返回动作（例如先播完 hero 缩回动画再 pop）。
    func animatedBackButton(onBack: (() -> Void)? = nil) -> some View {
        modifier(AnimatedBackBarModifier(onBack: onBack))
    }
}
