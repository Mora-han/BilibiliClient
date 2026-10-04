import SwiftUI
#if os(iOS)
import UIKit
#endif

/// iOS 根页面的统一顶栏动作：**右上角只有头像**。
///
/// - 搜索不在这里：它由标签栏里的放大镜标签承担（App Store / Apple Music 同款），
///   点击切到自带输入框的搜索页。刻意不用 `.searchable`：它会给顶栏再挂一颗
///   系统独立放大镜（实测）。
/// - 头像点击弹出账户卡：**原生 `.sheet` + `.presentationSizing(.fitted)`**——
///   与 App Store 账户卡同一个控件（iPad 的内容定尺 form sheet），从底部滑入、
///   可下拉拖走，动画与手感全由系统提供（见 `AccountCardSheet`）。
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
                    // 顶栏条目默认自带一层**共享玻璃**：那层玻璃按顶栏槽位（实测 71×71pt）算，
                    // 跟内容大小无关——34pt 头像裹在 71pt 玻璃里，头像只占 48%，
                    // 这就是「头像偏小、没占满玻璃、跟 App Store 不一样」的根因。
                    //
                    // 两步修掉（都用 iOS 26 原生 API）：
                    // 1. `sharedBackgroundVisibility(.hidden)`：关掉系统那层共享玻璃。
                    //    实测：20pt 探针关掉后，无论多松的阈值都量不到任何玻璃——
                    //    说明这层确实被摘干净了（没关时是一颗 71pt 的圆）。
                    // 2. 玻璃自己画：`glassEffect(.regular.interactive(), in: .circle)`。
                    //    **必须挂在 Button 的 label 上**：挂 Button 上会按顶栏槽位定形，
                    //    又变回 67pt 的大玻璃。`.interactive()` 给系统原生的按下弹性反馈。
                    //
                    // 实测（3x 像素）：40pt 头像 + 2pt 内边距 → 玻璃 44pt，
                    // 头像占约 90%；旧版 34pt 头像裹 71pt 玻璃，只占 48%。
                    Button { showAccount = true } label: {
                        avatar(40)
                            .padding(2)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("账户")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .sheet(isPresented: $showAccount) {
                AccountCardSheet()
                    // 内容定尺（fitted）：App Store 账户卡就是这个形态——宽度=内容宽、
                    // 高度=内容高，系统据此给卡片定尺寸。
                    .presentationSizing(.fitted)
                    .presentationCornerRadius(30)
                    .presentationBackground(Color(uiColor: .systemGroupedBackground))
                    // **iOS 27 的居中浮动卡片**：App Store 那张账户卡用的就是这个
                    // （`UISheetPresentationController.preferredPlacement = .center`，
                    //  SwiftUI 侧叫 `.presentationPlacement(.center)`）。它会以一张卡
                    // 的形式居中悬浮、上下拖拽都带系统弹性反馈。iOS 26 上该 API 不存在，
                    // 降级为系统默认的居中 form sheet（观感接近，只是少了新的浮动拖拽）。
                    .biliPresentationCenteredIfAvailable()
                    .environmentObject(session)
            }
        #else
        content
        #endif
    }

    #if os(iOS)
    /// 头像本体（`diameter` = 内容框边长，玻璃按这个框画）。
    ///
    /// 头像**铺满整个内容框**（不再留 2pt 内缩）：玻璃只比内容大一点点，
    /// 头像/玻璃 ≈ 0.9，与 App Store 右上角那颗一致——之前 34pt 内容裹 71pt 玻璃，
    /// 头像只占 48%，看着就是「小小一颗缩在大玻璃里」。
    private func avatar(_ diameter: CGFloat) -> some View {
        Group {
            if session.loggedIn, let user = session.user {
                RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: diameter - 6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .contentShape(Circle())
    }
    #endif
}

extension View {
    /// 挂载根页顶栏动作（macOS 空实现）。
    func biliRootTopBar() -> some View {
        modifier(RootTopBar())
    }

    #if os(iOS)
    /// iOS 27：把 sheet 变成**居中浮动的卡片**（`preferredPlacement = .center`）——
    /// App Store 账户卡、Apple Music 的一些卡都是这个形态：居中出现、上下拖拽带
    /// 系统弹性反馈。iOS 26 上没有这个 API，原样返回（走系统默认的居中 form sheet）。
    @ViewBuilder
    func biliPresentationCenteredIfAvailable() -> some View {
        if #available(iOS 27.0, *) {
            presentationPlacement(.center)
        } else {
            self
        }
    }
    #endif
}

#if os(iOS)
/// 点头像弹出的账户卡，**按 App Store「Apple 账户」卡逐项对齐量出来的参数**构建：
///
/// 参考图（iPad 11 吋横屏，屏 1210×834pt）量得的几何：
/// - 卡片 498×567pt，白底分组灰、圆角约 30pt、居中、**无抓手条**；
/// - 行卡左右各内缩 14pt（行卡宽 470.5pt）、圆角约 12pt；
/// - 第一组两行各 62pt（带 44pt 头像），第二组每行 51pt；
/// - 组内文字距行卡左边 16pt、分隔线同样从 16pt 处起；组间距 31pt；
/// - 标题行在卡片顶部（图标 + 标题 + 右上角 X），标题区高约 85pt。
///
/// 尺寸由内容给出（宽度固定 498），配合 `.presentationSizing(.fitted)` 让系统
/// 按内容定尺——这正是 App Store 那张卡的做法。
struct AccountCardSheet: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var cacheCleared = false

    // 参考图量得的几何参数
    private static let cardWidth: CGFloat = 498
    private static let rowInset: CGFloat = 14
    private static let rowRadius: CGFloat = 12
    private static let textInset: CGFloat = 16
    private static let plainRowHeight: CGFloat = 51
    private static let avatarRowHeight: CGFloat = 62
    private static let groupGap: CGFloat = 31

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 16)
                .padding(.bottom, 34)

            group {
                accountRow
                separator
                settingsRow
            }

            spacer(Self.groupGap)

            group {
                versionRow
                separator
                githubRow
                separator
                cacheRow
            }

            if session.loggedIn {
                spacer(Self.groupGap)
                group { signOutRow }
            }

            Color.clear.frame(height: 19)
        }
        .frame(width: Self.cardWidth, alignment: .leading)
    }

    // MARK: - 标题栏

    /// 标题行：图标 + 「账户」+ 右上角圆形 X（参考图的 Apple 账户标题栏）。
    private var header: some View {
        HStack(spacing: 10) {
            if session.loggedIn, let user = session.user {
                RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
            Text("账户")
                .font(.headline)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(uiColor: .quaternarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, Self.rowInset)
    }

    // MARK: - 行

    /// 账户行：登录态是头像 + 昵称 + 副标题；未登录态是去登录的入口。
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
                    Text("Lv.\(user.level) · 关注 \(Formatters.count(user.following)) · 粉丝 \(Formatters.count(user.follower))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.textInset)
            .frame(height: Self.avatarRowHeight)
        } else {
            Button {
                showLogin = true
            } label: {
                row(icon: "qrcode", title: "扫码登录", height: Self.avatarRowHeight, chevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// 「软件设置」：跳系统「设置」里本 App 的面板（设置页已并入系统设置）。
    private var settingsRow: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            row(title: "软件设置", chevron: true)
        }
        .buttonStyle(.plain)
    }

    private var versionRow: some View {
        row(title: "版本", value: "\(BuildInfo.version)（\(BuildInfo.build)）")
    }

    private var githubRow: some View {
        Button {
            if let url = URL(string: "https://github.com/Mora-han/BilibiliClient") {
                UIApplication.shared.open(url)
            }
        } label: {
            row(title: "GitHub 项目主页", chevron: true)
        }
        .buttonStyle(.plain)
    }

    private var cacheRow: some View {
        Button {
            URLCache.shared.removeAllCachedResponses()
            BiliImages.clearCaches()
            cacheCleared = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                cacheCleared = false
            }
        } label: {
            row(title: "清除图片缓存", value: cacheCleared ? "已清除" : nil)
        }
        .buttonStyle(.plain)
    }

    private var signOutRow: some View {
        Button {
            session.logout()
        } label: {
            Text("退出登录")
                .font(.body)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: Self.plainRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 零件

    /// 一行：可选前导图标 + 标题 + 右侧值/箭头。行高默认 51pt（参考图量得）。
    private func row(icon: String? = nil, title: String, value: String? = nil,
                     height: CGFloat = plainRowHeight, chevron: Bool = false) -> some View {
        HStack(spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Self.textInset)
        .frame(height: height)
        .contentShape(Rectangle())
    }

    /// 行卡：白底 + 12pt 圆角（参考图里一组行共用一张卡）。
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: Self.rowRadius))
            .padding(.horizontal, Self.rowInset)
    }

    /// 组内分隔线：从文字左缘（行内 16pt）起，不到行卡左边缘——与参考图一致。
    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.leading, Self.textInset)
    }

    private func spacer(_ height: CGFloat) -> some View {
        Color.clear.frame(height: height)
    }
}
#endif
