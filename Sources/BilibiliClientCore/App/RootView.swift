#if os(macOS)
import AppKit
#endif
import SwiftUI

private struct TabVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 当前页面所在的标签页是否正被选中（可见）。
    ///
    /// iOS 的每个标签页有各自独立的导航栈（见 `RootView.tabStack(_:)`），但 `AppRouter.path`
    /// 是**全局**的、只跟着当前选中的标签镜像。详情页若拿它来判断"我是不是栈顶"，
    /// 隐藏标签里的那个页面也会跟着响应 —— 表现为切回来发现视频/直播被重新拉起来了。
    /// 所以详情页的导航计数判断必须先过这道闸。
    ///
    /// macOS 的侧边栏同样是「一页一栈」（见 `RootView.detailStack`），页面切走时
    /// 只藏不删，隐藏页里的播放器靠这个值在 `onChange` 里收尾/恢复。
    var isTabVisible: Bool {
        get { self[TabVisibilityKey.self] }
        set { self[TabVisibilityKey.self] = newValue }
    }
}

public struct UpRoute: Hashable {
    let mid: Int
}

public struct PartitionRoute: Hashable {
    let tid: Int
    let name: String
}

public struct SearchRoute: Hashable {
    let query: String
}

public struct DynamicRoute: Hashable {
    let id: String
}

public struct RootView: View {
    public init() {}

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var router: AppRouter
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @State private var selection: SidebarItem? = .home
    @State private var showLogin = false
    @State private var showAccountPanel = false
    @State private var searchText = ""
    @State private var submittedQuery = ""
    #if os(macOS)
    /// 已访问过的根页面（keep-alive 名单）：访问过就常驻，切走只藏不删。
    @State private var visited: [SidebarItem] = [.home]
    #endif
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    enum SidebarItem: String, CaseIterable, Identifiable {
        case home = "推荐"
        case zones = "分区"
        case popular = "热门"
        case live = "直播"
        case dynamics = "动态"
        case favorites = "收藏"
        case history = "历史"
        case watchLater = "稍后再看"
        case settings = "设置"
        // 仅 iPhone 紧凑宽度：把分区/收藏/历史/稍后再看/设置收进去的聚合页
        case mine = "我的"
        // 搜索仅由顶部搜索框进入，不出现在侧边栏
        case search = "搜索"

        var id: String { rawValue }

        /// 紧凑宽度下「我的」页里列出的入口（顺序即展示顺序）。
        static let mineEntries: [SidebarItem] = [.zones, .favorites, .history, .watchLater, .settings]

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .zones: return "square.grid.2x2"
            case .popular: return "flame.fill"
            case .live: return "dot.radiowaves.left.and.right"
            case .dynamics: return "sparkles"
            case .favorites: return "bookmark"
            case .history: return "clock.arrow.circlepath"
            case .watchLater: return "clock.badge.checkmark"
            case .settings: return "gearshape"
            case .mine: return "person.crop.circle"
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

    public var body: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 270)
        } detail: {
            detailStack
        }
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .onAppear(perform: bindMainWindow)
        #else
        // iPhone 底部标签栏 / iPad 顶部标签栏，iPad 上可一键切到侧边栏（Apple Music 式）。
        // 分组用 SwiftUI 的 `TabSection`（嵌套 `Tab` 不被 SwiftUI 支持：Tab 只 conform
        // TabContent，不 conform View）。侧边栏里的「浏览 / 我的」分组与 macOS 侧边栏一致。
        //
        // 紧凑宽度（iPhone / 窄 iPad）下必须收窄到 5 个 tab：系统只保证 5 个位置，
        // 多出来的会被塞进「更多」列表，而 `TabSection` 的分组标题在紧凑宽度下本来
        // 就不显示，9 个 tab 只会变成一团。「我的」做成一个真正的页面（`MineView`），
        // 把分区 / 收藏 / 历史 / 稍后再看 / 设置收进去。
        Group {
            if horizontalSizeClass == .compact {
                TabView(selection: $selection) {
                    Tab("推荐", systemImage: SidebarItem.home.icon, value: SidebarItem.home) { tabStack(.home) }
                    Tab("热门", systemImage: SidebarItem.popular.icon, value: SidebarItem.popular) { tabStack(.popular) }
                    Tab("直播", systemImage: SidebarItem.live.icon, value: SidebarItem.live) { tabStack(.live) }
                    Tab("动态", systemImage: SidebarItem.dynamics.icon, value: SidebarItem.dynamics) { tabStack(.dynamics) }
                    Tab("我的", systemImage: SidebarItem.mine.icon, value: SidebarItem.mine) { tabStack(.mine) }
                }
            } else {
                TabView(selection: $selection) {
                    TabSection("浏览") {
                        Tab("推荐", systemImage: SidebarItem.home.icon, value: SidebarItem.home) { tabStack(.home) }
                        Tab("分区", systemImage: SidebarItem.zones.icon, value: SidebarItem.zones) { tabStack(.zones) }
                        Tab("热门", systemImage: SidebarItem.popular.icon, value: SidebarItem.popular) { tabStack(.popular) }
                        Tab("直播", systemImage: SidebarItem.live.icon, value: SidebarItem.live) { tabStack(.live) }
                        Tab("动态", systemImage: SidebarItem.dynamics.icon, value: SidebarItem.dynamics) { tabStack(.dynamics) }
                    }
                    TabSection("我的") {
                        Tab("收藏", systemImage: SidebarItem.favorites.icon, value: SidebarItem.favorites) { tabStack(.favorites) }
                        Tab("历史", systemImage: SidebarItem.history.icon, value: SidebarItem.history) { tabStack(.history) }
                        Tab("稍后再看", systemImage: SidebarItem.watchLater.icon, value: SidebarItem.watchLater) { tabStack(.watchLater) }
                    }
                    Tab("设置", systemImage: SidebarItem.settings.icon, value: SidebarItem.settings) { tabStack(.settings) }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarFooter {
            accountBar
        }
        .searchable(text: $searchText, prompt: "搜索视频 / UP 主")
        .onSubmit(of: .search) { submitSearch() }
        .preferredColorScheme(colorScheme)
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        #endif
    }

    #if os(macOS)
    /// 详情区：macOS 侧边栏切换只改可见性、不销毁已访问的页面（keep-alive）。
    ///
    /// 旧实现是「单 NavigationStack + 按 selection 换根页」：selection 一变，
    /// `rootPage(for:)` 返回的类型不同，整个子树被销毁，`@State`（已加载内容、
    /// `hasLoaded`、滚动位置）全部清零 —— 切回来就是骨架屏 + 重新请求。
    /// 现在每个访问过的根页各占一份独立导航栈（复用 iOS 已验证的 `TabNavStack`），
    /// 未选中的只藏不删：没手动刷新前内容一直保留，连推入的详情页栈也留着。
    private var detailStack: some View {
        ZStack {
            ForEach(visiblePages, id: \.id) { item in
                let isSelected = selection == item
                TabNavStack(item: item, query: submittedQuery, isSelected: isSelected)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
            }
        }
        .onChange(of: selection) { _, new in
            guard let new, !visited.contains(new) else { return }
            visited.append(new)
        }
    }

    /// 常驻页清单：当前选中页永远排在**最前**（即便还没进过 `visited`）。
    /// 实测窗口标题的偏好合并是「首个子视图胜出」——选中页必须在第一位，
    /// 标题（含推入详情页后的标题）才跟着选中页走；隐藏栈排后面且已压制工具栏。
    private var visiblePages: [SidebarItem] {
        let current = selection ?? .home
        var pages = visited
        pages.removeAll { $0 == current }
        pages.insert(current, at: 0)
        return pages
    }
    #endif

    #if os(iOS)
    /// 每个标签页一份**独立**导航栈。
    ///
    /// 千万别让多个标签页共用同一个 `$router.path`：那样推一个视频，
    /// 等于在每个已实例化的标签栈里各推一份，每份各建一个 `VideoDetailView` + 播放器，
    /// 于是「点进视频会同时播放好几个、暂停后后台还有一堆在响」。
    private func tabStack(_ item: SidebarItem) -> some View {
        TabNavStack(item: item, query: submittedQuery, isSelected: selection == item)
    }
    #endif

    #if os(macOS)
    /// 绑定主窗口代理，用于“关闭窗口”行为（完全退出 / 菜单栏模式 / 询问）。
    private func bindMainWindow() {
        let candidate = NSApp.windows.first { $0.identifier?.rawValue == "main" }
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        if let window = candidate {
            AppDelegate.shared?.adoptMainWindow(window)
            // macOS 会把窗口内第一个输入框（顶部搜索框）自动设为焦点，
            // 启动时清掉，避免键盘快捷键被搜索框吞掉
            DispatchQueue.main.async {
                window.makeFirstResponder(nil)
            }
        }
    }
    #endif

    #if os(macOS)
    /// 侧边栏：AppKit source list（见 `SourceListSidebar`）+ 系统搜索框。
    ///
    /// 选中态由系统按 source list 材质绘制——访达 / App Store 那种中性半透明
    /// 覆盖层（不是强调色高亮），图标固定用强调色着色，与 coolapk 一致；
    /// 搜索框用 `.searchable(placement: .sidebar)`，观感与 App Store 一致。
    private var sidebar: some View {
        VStack(spacing: 0) {
            SourceListSidebar(sections: sidebarSections, selection: selection) { item in
                selection = item
            }
            accountBar
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索视频 / UP 主")
        .onSubmit(of: .search) { submitSearch() }
    }

    private var sidebarSections: [SourceListSidebar<SidebarItem>.Section] {
        [
            .init(id: "browse", title: "浏览", rows: [.home, .zones, .popular, .live, .dynamics].map(entry)),
            .init(id: "mine", title: "我的", rows: [.favorites, .history, .watchLater].map(entry)),
            // 设置不挂分组标题：与原 List 里不带 header 的 Section 保持一致
            .init(id: "settings", title: "", rows: [entry(.settings)]),
        ]
    }

    private func entry(_ item: SidebarItem) -> SourceListSidebar<SidebarItem>.Row {
        .init(id: item.rawValue, value: item, title: item.rawValue, systemImage: item.icon)
    }
    #endif

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
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        selection = .search
        #else
        // iOS 的搜索不在标签栏里，直接推进导航栈（与点站内搜索结果同一条路径）。
        // 这里必须**替换**整条路径而不是 append：`router.path` 是全局的、会残留上一个
        // 标签栈里的内容，直接 append 会让当前标签继承「视频详情 → 搜索页」这样的
        // 整条旧栈，返回按钮于是指向一个毫不相干的视频页。
        router.path = NavigationPath([SearchRoute(query: trimmed)])
        #endif
    }

    private func avatar(url: String, size: CGFloat) -> some View {
        RemoteImage(url: Formatters.https(url), variant: .avatar)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

// MARK: - 导航栈共用件

extension RootView {
    /// 详情区的根页面。macOS 的单一导航栈与 iOS 的每个标签栈共用这一份。
    @ViewBuilder
    static func rootPage(for item: SidebarItem?, query: String) -> some View {
        switch item {
        case .home:
            RecommendView()
        case .zones:
            ZonesView()
        case .popular:
            PopularView()
        case .live:
            LiveFeedView()
        case .search:
            SearchView(query: query)
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
        case .mine:
            MineView()
        case nil:
            RecommendView()
        }
    }
}

/// 「我的」入口的路由值：紧凑宽度下 `MineView` 用它推进分区/收藏/历史/稍后再看/设置。
struct SidebarRoute: Hashable {
    let item: RootView.SidebarItem
}

extension View {
    /// 全部导航目的地。两端、以及 iOS 的每个标签栈都挂同一套路由。
    func biliNavDestinations() -> some View {
        self
            .navigationDestination(for: String.self) { bvid in
                VideoDetailView(bvid: bvid)
            }
            .navigationDestination(for: UpRoute.self) { route in
                UpProfileView(mid: route.mid)
            }
            .navigationDestination(for: PartitionRoute.self) { route in
                PartitionVideosView(zone: BiliZone(id: route.tid, name: route.name, icon: "play.rectangle"))
            }
            .navigationDestination(for: SearchRoute.self) { route in
                SearchView(query: route.query)
            }
            .navigationDestination(for: DynamicRoute.self) { route in
                DynamicDetailView(id: route.id)
            }
            .navigationDestination(for: LiveRoute.self) { route in
                LiveDetailView(route: route)
            }
            .navigationDestination(for: SidebarRoute.self) { route in
                RootView.rootPage(for: route.item, query: "")
            }
    }
}

#if os(iOS)
/// 紧凑宽度下的「我的」聚合页：账户信息 + 分区/收藏/历史/稍后再看/设置入口。
///
/// iPhone 的标签栏只放得下 5 个 tab，而 `tabViewSidebarFooter` 里的账户卡片在
/// 标签栏形态下整块不可见（苹果只在显示侧边栏时展示它）。于是把账户入口和其余
/// 次级入口一起收进这一页，登录/退出登录也终于有地方可点。
private struct MineView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                accountCard

                VStack(spacing: 0) {
                    ForEach(RootView.SidebarItem.mineEntries) { item in
                        NavigationLink(value: SidebarRoute(item: item)) {
                            HStack(spacing: 12) {
                                Label(item.rawValue, systemImage: item.icon)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if item != RootView.SidebarItem.mineEntries.last {
                            Divider().padding(.leading, 4)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .contentCard(cornerRadius: 14)
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("我的")
    }

    @ViewBuilder
    private var accountCard: some View {
        if session.loggedIn, let user = session.user {
            HStack(spacing: 14) {
                RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Lv.\(user.level) · 关注 \(Formatters.count(user.following)) · 粉丝 \(Formatters.count(user.follower))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentCard(cornerRadius: 14)
        } else {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("未登录").font(.headline)
                    Text("登录后可同步收藏夹、观看历史与稍后再看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentCard(cornerRadius: 14)
        }
    }
}
#else
/// macOS 走侧边栏，不存在紧凑宽度下的「我的」聚合页。
/// 保留一个空实现，让 `RootView.rootPage` 的 switch 两端都能编译。
private struct MineView: View {
    var body: some View { EmptyView() }
}
#endif

/// 单个标签页自己的导航栈。动机见 `RootView.tabStack(_:)` 的说明。
private struct TabNavStack: View {
    let item: RootView.SidebarItem
    let query: String
    let isSelected: Bool
    @EnvironmentObject private var router: AppRouter
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            RootView.rootPage(for: item, query: query)
                .biliNavDestinations()
        }
        // 详情页靠这个判断"我所在的标签还可见吗"，避免隐藏标签被全局 path 计数唤醒
        .environment(\.isTabVisible, isSelected)
        // 切回本标签时把全局路径镜像成本栈自己的路径：`router.path` 在切走期间
        // 可能已被别的标签改写，不镜像的话下一次程序化导航（菜单栏、搜索…）
        // 会把上一个标签的旧栈垫在这一页底下。
        .onChange(of: isSelected) { _, nowSelected in
            guard nowSelected, path != router.path else { return }
            router.path = path
        }
        // 外部程序化导航（搜索、评论里点视频、菜单栏卡片…）落进**当前**标签的栈。
        .onChange(of: router.path) { _, incoming in
            guard isSelected, incoming != path else { return }
            path = incoming
        }
        // 本栈变化时回写，让 `router.path` 始终等于当前可见标签的路径。
        .onChange(of: path) { _, outgoing in
            guard isSelected, outgoing != router.path else { return }
            router.path = outgoing
        }
    }
}

