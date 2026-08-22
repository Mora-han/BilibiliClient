import AppKit
import SwiftUI

struct UpRoute: Hashable {
    let mid: Int
}

struct PartitionRoute: Hashable {
    let tid: Int
    let name: String
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @State private var selection: SidebarItem? = .home
    @State private var showLogin = false
    @State private var showAccountPanel = false
    @State private var searchText = ""
    @State private var submittedQuery = ""

    enum SidebarItem: String, CaseIterable, Identifiable {
        case home = "推荐"
        case zones = "分区"
        case popular = "热门"
        case dynamics = "动态"
        case favorites = "收藏"
        case history = "历史"
        case watchLater = "稍后再看"
        case settings = "设置"
        // 搜索仅由顶部搜索框进入，不出现在侧边栏
        case search = "搜索"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .zones: return "square.grid.2x2"
            case .popular: return "flame.fill"
            case .dynamics: return "sparkles"
            case .favorites: return "bookmark"
            case .history: return "clock.arrow.circlepath"
            case .watchLater: return "clock.badge.checkmark"
            case .settings: return "gearshape"
            case .search: return "magnifyingglass"
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case AppearanceMode.light.rawValue: return .light
        case AppearanceMode.dark.rawValue: return .dark
        default: return nil
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 270)
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    switch selection {
                    case .home:
                        RecommendView()
                    case .zones:
                        ZonesView()
                    case .popular:
                        PopularView()
                    case .search:
                        SearchView(query: submittedQuery)
                    case .dynamics:
                        DynamicFeedView()
                    case .favorites:
                        FavoritesView()
                    case .history:
                        HistoryView()
                    case .watchLater:
                        WatchLaterView()
                    case .settings:
                        SettingsView()
                    case nil:
                        RecommendView()
                    }
                }
                .navigationDestination(for: String.self) { bvid in
                    VideoDetailView(bvid: bvid)
                }
                .navigationDestination(for: UpRoute.self) { route in
                    UpProfileView(mid: route.mid)
                }
                .navigationDestination(for: PartitionRoute.self) { route in
                    PartitionVideosView(zone: BiliZone(id: route.tid, name: route.name, icon: "play.rectangle"))
                }
            }
        }
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .onAppear {
            // 绑定主窗口代理，用于“关闭窗口”行为（完全退出 / 菜单栏模式 / 询问）
            if let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                window.delegate = AppDelegate.shared
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("浏览") {
                ForEach([SidebarItem.home, .zones, .popular, .dynamics]) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
            Section("我的") {
                ForEach([SidebarItem.favorites, .history, .watchLater]) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
            Section {
                Label(SidebarItem.settings.rawValue, systemImage: SidebarItem.settings.icon)
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassSearchField(text: $searchText) {
                submitSearch()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) { accountBar }
    }

    /// 侧边栏底部账户信息卡片：仅展示纯个人信息，点击可查看详情/退出登录。
    private var accountBar: some View {
        VStack(spacing: 0) {
            Divider()
            if session.loggedIn {
                Button {
                    showAccountPanel = true
                } label: {
                    HStack(spacing: 10) {
                        avatar(url: session.user?.face ?? "", size: 34)
                        Text(session.user?.name ?? "同步中…")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("扫码登录", systemImage: "qrcode")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
        }
        .popover(isPresented: $showAccountPanel, arrowEdge: .bottom) {
            AccountPanelView(showLogin: $showLogin)
                .environmentObject(session)
        }
    }

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedQuery = trimmed
        if !trimmed.isEmpty {
            selection = .search
        }
    }

    private func avatar(url: String, size: CGFloat) -> some View {
        RemoteImage(url: Formatters.https(url))
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}
