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

/// 每个导航栈一份的可见性信号：详情页用它判断「我所在的标签还可见吗」。
///
/// 为什么不用自定义 Environment 值：实测 `.environment(\.isTabVisible, ...)` 的值变化
/// 不会触发 push 出来的详情页的 `onChange`（恢复播放的钩子因此从不执行），
/// 而 EnvironmentObject 驱动的 onChange 在本项目里一直可靠（`router.path` 就是这么工作的）。
/// 每栈一份实例，`TabNavStack` 负责同步 `isSelected` 并注入栈内容。
final class TabVisibility: ObservableObject {
    @Published var isVisible = true
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
    /// 搜索推荐词（App Store 搜索框那种边打边出）。
    @State private var searchSuggestions: [String] = []
    /// 推荐词的防抖任务。
    @State private var suggestTask: Task<Void, Never>?
    /// 搜索框的回车监视器：`.searchable` 的 onSubmit 在本机收不到，见安装处的说明。
    @State private var searchKeyMonitor: NSEventMonitor?
    /// 打开系统设置场景的官方动作（与菜单项「设置…」同一目标）。
    /// ⌘, 的菜单 keyEquivalent 在本机不分发（键事件能到 App、但菜单动作不触发，
    /// 实测过），由键盘监视器直接调用它兜底，行为与点菜单完全一致。
    @Environment(\.openSettings) private var openSettings
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
            ForEach(keepAlivePages, id: \.id) { item in
                let isSelected = selection == item
                TabNavStack(item: item, query: submittedQuery, isSelected: isSelected)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    // 选中页用 zIndex 盖到最上面（=「正常覆盖在当前页面之上」）。
                    // 以前靠把选中页**插到数组最前**来实现覆盖+标题，但 ForEach 重排
                    // 会让 NavigationStack 在多个栈同时带推送路径时丢渲染：选中态、
                    // 标题都变了，画面和鼠标命中的还是旧页面（实测分区卡点击被推进
                    // 了隐藏的历史栈）。zIndex 只改叠放层级、不移动视图身份，稳定。
                    .zIndex(isSelected ? 1 : 0)
                    .accessibilityHidden(!isSelected)
            }
        }
        .onChange(of: selection) { _, new in
            AppLog.app.debug("[SIDE] selection -> \(new?.rawValue ?? "nil") pages=\(keepAlivePages.map(\.rawValue))")
            guard let new, !visited.contains(new) else { return }
            visited.append(new)
        }
    }

    /// 常驻页清单：**固定顺序**（访问顺序，仅追加不重排），绝不动已存在的身份。
    /// 覆盖关系交给 `zIndex`（选中者置顶），窗口标题跟着实际渲染的顶层栈走。
    private var keepAlivePages: [SidebarItem] {
        let current = selection ?? .home
        var pages = visited
        if !pages.contains(current) { pages.append(current) }
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
                AppLog.app.debug("[SIDE] onSelect -> \(item.rawValue) cur=\(selection?.rawValue ?? "-")")
                selection = item
            }
            accountBar
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索视频 / UP 主")
        .onSubmit(of: .search) { submitSearch() }
        // 系统原生回车提交：有的系统版本在这个位置只发 `.text` 这一路，
        // 接上它就能少依赖下面那个键盘监视器（两条都走到也只提交一次同样的词）。
        .onSubmit(of: .text) { submitSearch() }
        // 输入只出推荐词、不出结果：打完词按回车（或点一条推荐词）才真正搜索。
        // 回车在本机收不到 `onSubmit(of: .search)`，由 `installSearchKeyMonitor`
        // 挂的键盘监视器兜住。
        .onChange(of: searchText) { oldValue, value in
            suggestTask?.cancel()
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                submittedQuery = ""
                searchSuggestions = []
                // 清空关键词就退出搜索页，避免停在一个空结果页上
                if selection == .search { selection = .home }
                return
            }
            // 点推荐词是一次性把整词填进来（系统补全），不是逐字输入：
            // 长度跳变 ≥ 2 且新词正好是当前推荐词之一，就当成「选了这条推荐词」直接搜。
            let previous = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= previous.count + 2,
               trimmed.hasPrefix(previous),
               searchSuggestions.contains(trimmed) {
                submitSearch()
                return
            }
            // 推荐词跟输入同步刷新：停顿 250ms 拉一次，慢一拍不打扰输入
            suggestTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let words = await SearchSuggestService().suggest(term: trimmed)
                guard !Task.isCancelled else { return }
                searchSuggestions = words
            }
        }
        // 输入框激活时在下方浮出推荐词列表，点一条即以该词搜索（系统统一渲染，
        // 和 App Store 的搜索框同款交互）
        .searchSuggestions {
            ForEach(searchSuggestions, id: \.self) { word in
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text(word)
                }
                .searchCompletion(word)
            }
        }
        .onAppear {
            installSearchKeyMonitor()
            // 设备指纹越早备好越好：搜索、评论这些接口的风控都看它
            Task { await APIClient.shared.ensureFingerprint() }
        }
    }

    /// 搜索框的回车提交。
    ///
    /// `.searchable(placement: .sidebar)` 配自定义 AppKit 侧栏时，系统收不到
    /// `onSubmit(of: .search)`（coolapk 在同机同系统踩过同一个坑，见它的 0.17.0
    /// CHANGELOG），所以挂一个本地键盘监视器**旁听**回车：只在焦点确实落在搜索框
    /// （field editor 的宿主是 `NSSearchField`）时才提交。
    ///
    /// 两个细节决定了它是否「像原生一样」：
    /// - **输入法拼字期间（marked text）的回车不是提交**，而是「确认候选词/上屏」。
    ///   这时候必须把事件原样交还输入法，否则中文输入法下敲英文单词直接回车，
    ///   会跳过上屏、拿半截词去搜索；
    /// - 只旁听、不吞事件（返回原事件），系统自己的处理照走，不干扰 AppKit。
    private func installSearchKeyMonitor() {
        guard searchKeyMonitor == nil else { return }
        searchKeyMonitor = NSEventMonitor(context: .local, matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.characters == "," {
                openSettings()
                return nil
            }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            guard isReturn, let editor = Self.searchFieldEditor() else { return event }
            // 输入法还在拼字：交给输入法去上屏
            guard !editor.hasMarkedText() else { return event }
            submitSearch()
            return event
        }
    }

    /// 搜索框背后的 field editor（`NSSearchField` 获得焦点时 first responder 就是它）。
    private static func searchFieldEditor() -> NSTextView? {
        guard let responder = NSApp.keyWindow?.firstResponder else { return nil }
        if let textView = responder as? NSTextView {
            if textView.delegate is NSSearchField { return textView }
            // 少数系统版本上 delegate 不是搜索框，沿视图链再认一次
            var view: NSView? = textView.superview
            while let current = view {
                if current is NSSearchField { return textView }
                view = current.superview
            }
            return nil
        }
        if let field = responder as? NSSearchField {
            return field.currentEditor() as? NSTextView
        }
        return nil
    }

    private var sidebarSections: [SourceListSidebar<SidebarItem>.Section] {
        [
            .init(id: "browse", title: "浏览", rows: [.home, .zones, .popular, .live, .dynamics].map(entry)),
            .init(id: "mine", title: "我的", rows: [.favorites, .history, .watchLater].map(entry)),
            // 设置已移出侧边栏：macOS 用原生独立设置窗口（菜单「设置…」⌘, 唤起）；
            // iOS 仍在底部 Tab / 我的页面里。
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
                // iPhone 上 popover 默认会被拉成整屏 sheet（与播放页各弹层同一处理）
                .presentationCompactAdaptation(.popover)
        }
    }

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedQuery = trimmed
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        selection = .search
        // 收起推荐词浮层：把焦点从搜索框交还出去（App Store 搜完也是收起建议列表）
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
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
    ///
    /// `vis`（本栈的可见性信号）必须**显式传参**再逐目的地 `environmentObject` 注入：
    /// 实测把注入写在链外或链尾，push 出来的详情页都拿不到（缺 EnvironmentObject 直接崩溃；
    /// 自定义环境值则静默失效、onChange 永不触发）。
    func biliNavDestinations(vis: TabVisibility) -> some View {
        self
            .navigationDestination(for: String.self) { bvid in
                VideoDetailView(bvid: bvid).environmentObject(vis)
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
                LiveDetailView(route: route).environmentObject(vis)
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
    @StateObject private var tabVisibility = TabVisibility()

    var body: some View {
        return NavigationStack(path: $path) {
            RootView.rootPage(for: item, query: query)
                .biliNavDestinations(vis: tabVisibility)
        }
        // 详情页靠这个判断"我所在的标签还可见吗"，避免隐藏标签被全局 path 计数唤醒
        .environment(\.isTabVisible, isSelected)
        .onAppear {
            tabVisibility.isVisible = isSelected
        }
        // 新建即选中（首次访问某页）时 onChange(of: isSelected) 不会触发，router.path
        // 会停在上一个栈的路径上：这里补一次镜像，保证它始终等于**可见栈**的路径——
        // 切回时的 path 计数恢复（`newCount == navBaseCount`）全靠这个不变量。
        // （用 .task 而不是 .onAppear：实测后者的镜像没跑到。）
        .task {
            if isSelected, path != router.path {
                router.path = path
            }
        }
        // 两个对 `isSelected` 的响应合并成一处（原先挂了两个 onChange，读起来像遗漏）：
        // ① 分区切走清栈；② 切回时重建详情页并镜像路径。
        .onChange(of: isSelected) { _, nowSelected in
            AppLog.app.debug("[TAB] \(item.rawValue) selected=\(nowSelected) path=\(path.count)")
            tabVisibility.isVisible = nowSelected
            // 分区页：从其他页面切走时清掉栈，下次回来落在分区首页
            //（产品要求：不保留之前看过的具体分区页）。
            if !nowSelected, item == .zones, !path.isEmpty {
                path = NavigationPath()
            }
            // 切回本标签时把全局路径镜像成本栈自己的路径：`router.path` 在切走期间
            // 可能已被别的标签改写，不镜像的话下一次程序化导航（搜索、评论里点视频、
            // 菜单栏卡片…）会把上一个标签的旧栈垫在这一页底下。
            if nowSelected, path.count > 0 {
                // 实测：切走时 push 出来的详情页会被移出层级（onDisappear 触发），
                // 但栈的 path 状态仍是 1；切回后 NavigationStack 却不再按 path 重建
                // 详情页——渲染停在根页，恢复逻辑（.task / path 计数）全部哑掉。
                // 这里「清空 → 下一帧回填」强制它按 path 重建详情页：根页视图状态
                // 不受影响，重建的详情页会跑 .task → load() 恢复播放。
                let saved = path
                path = NavigationPath()
                DispatchQueue.main.async {
                    path = saved
                }
            }
            guard nowSelected, path != router.path else { return }
            router.path = path
        }
        // 外部程序化导航（搜索、评论里点视频、菜单栏卡片…）落进**当前**标签的栈。
        .onChange(of: router.path) { _, incoming in
            AppLog.app.debug("[RPATH] \(item) sel=\(isSelected) router -> \(incoming.count) local=\(path.count)")
            guard isSelected, incoming != path else { return }
            path = incoming
        }
        // 本栈变化时回写，让 `router.path` 始终等于当前可见标签的路径。
        .onChange(of: path) { _, outgoing in
            AppLog.app.debug("[PATH] \(item) -> \(outgoing.count) sel=\(isSelected) router=\(router.path.count)")
            guard isSelected, outgoing != router.path else { return }
            router.path = outgoing
        }
    }
}

