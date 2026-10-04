import SwiftUI
#if os(iOS)
import UIKit
#endif

/// iOS 根页面的统一顶栏动作：**右上角只有头像**。
///
/// - 搜索不在这里：它由标签栏里的放大镜标签承担（App Store / Apple Music 同款——
///   图标长在「首页/分区/动态/我的」这排标签里，见 `RootView` 的 TabView），
///   点击切到自带输入框的搜索页。刻意不用 `.searchable`：它会给顶栏再挂一颗
///   系统独立放大镜（实测）。
/// - 头像点击弹出账户卡：**原生 `.sheet` + detents**——系统自带的「从底部丝滑滑入、
///   可下拉拖走（带橡皮筋与指示条）」那一套（`AccountCardSheet`），不自绘浮层：
///   自绘版位置、动画、拖拽反馈都和 App Store 对不上。
///
/// 只挂在导航栈的**根页面**上（见 `TabNavStack`）：推入详情页后顶栏动作自然收起。
/// macOS 走侧边栏搜索框与侧边栏底部账户卡，这里整体为空实现。
struct RootTopBar: ViewModifier {
    @EnvironmentObject private var session: SessionStore
    @State private var showAccount = LaunchArgs.accountPreview

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAccount = true
                    } label: {
                        avatar
                    }
                    .accessibilityLabel("账户")
                }
            }
            .sheet(isPresented: $showAccount) {
                AccountCardSheet()
                    // 强制 **page sheet**：iPad 默认给的是 form sheet——尺寸被系统封在
                    // ~620pt 半屏（detent 写 fraction/large/height 都试过，全被天花板压住）。
                    // page sheet 才是底部贴边、占大半屏、从底部滑入、可下拉拖走的形态，
                    // 也就是 App Store 账户卡用的那一种。
                    // 高度由内容的 minHeight 撑到约 85% 屏高、宽度由内容的 cardWidth
                    // 定为屏宽 52%（见 AccountCardSheet），配 fitted 让系统按内容定尺。
                    // 居中带侧边距的高卡片，和参考图一致。
                    .presentationSizing(.fitted.fitted(horizontal: false, vertical: true))
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(28)
                    .presentationBackground(Color(uiColor: .systemGroupedBackground))
                    .presentationContentInteraction(.scrolls)
                    .environmentObject(session)
            }
        #else
        content
        #endif
    }

    #if os(iOS)
    private var avatar: some View {
        Group {
            if session.loggedIn, let user = session.user {
                RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 25))
                    .foregroundStyle(.secondary)
            }
        }
    }
    #endif
}

extension View {
    /// 挂载根页顶栏动作（macOS 空实现）。
    func biliRootTopBar() -> some View {
        modifier(RootTopBar())
    }
}


#if os(iOS)
/// 点头像弹出的账户卡（**原生 sheet**，形态对齐 App Store「Apple 账户」卡）：
/// 标题栏（图标 + 标题 + 右上角 X）+ 分组行卡；从屏幕底部滑入、可下拉拖走，
/// 动画与拖拽反馈全部由系统 sheet 提供（`.presentationDetents` 那一套）。
struct AccountCardSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // 账户 + 软件设置（一组分组行，App Store 卡片同款的 inset 行卡）
                VStack(spacing: 0) {
                    accountRow
                    Divider()
                        .padding(.leading, session.loggedIn ? 76 : 16)
                    settingsRow
                }
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))

                // 退出登录单独一组，与信息行区分开（未登录时没有这组）
                if session.loggedIn {
                    VStack(spacing: 0) {
                        Button {
                            session.logout()
                        } label: {
                            rowLabel(icon: "rectangle.portrait.and.arrow.right",
                                     title: "退出登录",
                                     tint: .red)
                        }
                        .buttonStyle(.plain)
                    }
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(16)
            // 定宽：屏宽的 52%（参考图里 Apple 账户卡约占屏宽一半、左右各留约 10% 边距），
            // 两端至少留 64pt；高度由 minHeight 撑到约 85% 屏高。宽高都由内容给出，
            // 配合 `.presentationSizing(.fitted...)` 才不会被 form-sheet 的半屏天花板压住。
            .frame(width: Self.cardWidth, alignment: .leading)
            .frame(minHeight: Self.screenHeight * 0.85)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
    }

    /// 卡宽：屏宽 52%（与参考图比例一致），两端至少留 64pt。
    private static var cardWidth: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        let w = window?.bounds.width ?? 800
        return min(w * 0.52, w - 64)
    }

    /// 屏高：取当前 key window 的高度（sheet 与页面同窗，不会拿错）。
    private static var screenHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.bounds.height ?? 1000
    }

    /// 标题栏：图标 + 「账户」+ 右上角 X（参考图的 Apple 账户标题栏）。
    private var header: some View {
        HStack(spacing: 10) {
            if session.loggedIn, let user = session.user {
                RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            Text("账户")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .quaternarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.top, 4)
    }

    /// 账户行：登录态展示个人信息；未登录态是去登录的入口。
    @ViewBuilder
    private var accountRow: some View {
        if session.loggedIn, let user = session.user {
            HStack(spacing: 14) {
                RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text("Lv.\(user.level) · 关注 \(Formatters.count(user.following)) · 粉丝 \(Formatters.count(user.follower)) · 硬币 \(Formatters.decimal(user.coin))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            Button {
                showLogin = true
            } label: {
                rowLabel(icon: "qrcode", title: "扫码登录", showChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// 「软件设置」行：跳系统「设置」里本 App 的面板（设置页已并入系统设置）。
    private var settingsRow: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            rowLabel(icon: "gearshape", title: "软件设置", showChevron: true)
        }
        .buttonStyle(.plain)
    }

    /// 分组行的统一排版：图标 + 标题 + 右侧箭头。
    private func rowLabel(icon: String, title: String, tint: Color? = nil,
                          showChevron: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 24)
                .foregroundStyle(tint ?? Color.secondary)
            Text(title)
                .font(.body)
                .foregroundStyle(tint ?? Color.primary)
            Spacer(minLength: 0)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}
#endif
