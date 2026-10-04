import SwiftUI
#if os(iOS)
import UIKit
#endif

/// iOS 根页面的统一顶栏动作：**搜索图标 + 头像，合成一枚胶囊挂在顶栏右侧**。
///
/// 改动动机（对齐 App Store / Apple Music 的顶栏）：
/// - 搜索不再是常驻搜索框，也不是系统另挂的独立按钮，而是顶栏右侧这枚胶囊里的
///   放大镜：点按推进**搜索页**（`SearchRoute` 空词 → 页内自带输入框，见 `SearchView`）。
///   刻意**不用** `.searchable`——它会给导航栏再加一颗自己的放大镜，和头像那组并排
///   出现两颗（实测），搜索框的展开/收起也不再由系统接管。
/// - 账户入口从侧边栏底部（`tabViewSidebarFooter`，仅侧边栏形态可见）移到同一枚胶囊
///   里的头像，点击弹出 App Store 式账户卡片，并附「软件设置」快捷入口——设置页已并入
///   系统「设置」（见 `iOSResources/Settings.bundle`）。
///
/// 只挂在导航栈的**根页面**上（见 `TabNavStack`）：推入详情页后顶栏动作自然收起，
/// 与 App Store 行为一致。macOS 走侧边栏搜索框与侧边栏底部账户卡，这里整体为空实现。
struct RootTopBar: ViewModifier {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var session: SessionStore
    @State private var showAccount = false
    @State private var showLogin = false

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 搜索与头像同一个 ToolbarItem：两颗按钮渲染成**一枚**玻璃胶囊，
                    // 与中间的标签胶囊同一行，读起来是顶栏的一部分而不是两颗散落的浮标。
                    HStack(spacing: 16) {
                        Button {
                            openSearch()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("搜索")

                        Button {
                            showAccount = true
                        } label: {
                            avatar
                        }
                        .accessibilityLabel("账户")
                    }
                }
            }
            .popover(isPresented: $showAccount, arrowEdge: .top) {
                TopAccountCard(showLogin: $showLogin)
                    // iPhone 上 popover 默认会被拉成整屏 sheet，账户卡片那样很突兀
                    .presentationCompactAdaptation(.popover)
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

    /// 进入搜索页（压栈、保留当前页，返回可回到原处）。
    private func openSearch() {
        router.path.append(SearchRoute(query: ""))
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
/// 右上角头像点出的账户卡片（App Store 头像卡片的形态）：
/// 个人信息 + 登录/退出登录，外加一行跳转**系统「设置」**的快捷入口。
struct TopAccountCard: View {
    @Binding var showLogin: Bool

    var body: some View {
        VStack(spacing: 0) {
            AccountPanelView(showLogin: $showLogin)

            Divider()

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                    Text("软件设置")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
    }
}
#endif
