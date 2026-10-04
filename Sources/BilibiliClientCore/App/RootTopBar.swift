import SwiftUI
#if os(iOS)
import UIKit
#endif

/// iOS 根页面的统一顶栏动作：**右上角只有头像**。
///
/// - 搜索不在这里：它由标签栏里的 `.search` 角色放大镜承担（App Store 同款——
///   图标长在「首页/分区/动态/我的」标签胶囊的右端，见 `RootView` 的 TabView），
///   点击展开顶栏搜索框（`.searchable(isPresented:)`）。刻意不用顶栏里的搜索按钮：
///   系统会因此**再**挂一颗独立放大镜，和头像挤在一起（实测），也不是要的形态。
/// - 头像点击弹出 App Store 式的居中账户卡片（`AccountCardOverlay`，见参考图：
///   标题栏 + 关闭按钮 + 分组行），卡片里附「软件设置」快捷入口——设置页已并入
///   系统「设置」（`iOSResources/Settings.bundle`）。
///
/// 只挂在导航栈的**根页面**上（见 `TabNavStack`）：推入详情页后顶栏动作自然收起。
/// macOS 走侧边栏搜索框与侧边栏底部账户卡，这里整体为空实现。
struct RootTopBar: ViewModifier {
    @EnvironmentObject private var session: SessionStore
    @State private var showAccount = LaunchArgs.accountPreview
    @State private var showLogin = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy(duration: 0.3, extraBounce: 0.04)) {
                            showAccount = true
                        }
                    } label: {
                        avatar
                    }
                    .accessibilityLabel("账户")
                }
            }
            .overlay {
                if showAccount {
                    AccountCardOverlay(isShown: $showAccount, showLogin: $showLogin)
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginView()
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
/// 点头像弹出的账户卡片（照 App Store「Apple 账户」卡的形态）：
/// 模态居中大卡 —— 标题栏（图标 + 标题 + 右上角圆形关闭按钮）+ 分组行卡，
/// 背景压暗、点背景或 X 关闭；卡片带缩放淡入的转场。
///
/// 不用 `popover`（箭头指向头像、位置随锚点漂）也不用 `sheet`（iPhone 从底部起、
/// iPad 居中但带系统 chrome），全自绘才能钉住参考图那个位置与观感。
struct AccountCardOverlay: View {
    @Binding var isShown: Bool
    @Binding var showLogin: Bool
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.26)) { isShown = false }
                }

            card
                .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
        }
    }

    private var card: some View {
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

            // 退出登录单独一组，与上面的信息行区分开（未登录时没有这组）
            if session.loggedIn {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.snappy(duration: 0.26)) { isShown = false }
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
        .frame(maxWidth: 500, alignment: .leading)
        .background(Color(uiColor: .systemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 32)
    }

    /// 标题栏：图标 + 「账户」+ 右上角圆形关闭按钮（参考图的 Apple 账户标题栏）。
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
                withAnimation(.snappy(duration: 0.26)) { isShown = false }
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
                withAnimation(.snappy(duration: 0.26)) { isShown = false }
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

    /// 分组行的统一排版：图标 + 标题 + 右侧内容/箭头。
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
