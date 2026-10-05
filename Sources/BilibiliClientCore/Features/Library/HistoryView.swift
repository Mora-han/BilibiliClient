import SwiftUI

struct HistoryView: View {
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新 / 编辑按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var items: [HistoryItem] = []
    @State private var cursor: HistoryCursor?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var showLogin = false
    @State private var isEditing = false

    private var usableItems: [HistoryItem] {
        items.filter { !($0.history?.bvid ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !session.loggedIn {
                loginPrompt
            } else {
                content
            }
        }
        #if os(iOS)
        // 编辑按钮放回页面内右上角（产品要求：不进顶栏、不和头像并排）。
        // 挂在 body 最外层：登录与否都显示——原工具栏按钮就是这个行为
        // （未登录时列表为空、按钮禁用）。点击效果与原先完全一致：
        // withAnimation 切 isEditing。macOS 仍走工具栏（见下面 .toolbar）。
        .overlay(alignment: .topTrailing) {
            pageEditButton
                .padding(.top, 8)
                .padding(.trailing, 14)
        }
        #endif
        #if os(macOS)
        // iOS 上嵌在「我的」分段容器里，标题由容器统一给（见 RecommendView 说明）
        .navigationTitle("历史记录")
        #endif
        .toolbar {
            if isTabVisible {
                #if os(macOS)
                // 「编辑」与刷新都只留 macOS。三个 keep-alive 页（收藏/历史/稍后再看）
                // 在 iOS 上共用同一个顶栏，工具栏条目会**合并**——此前只有收藏页把
                // 「编辑」包进了 #if，历史与稍后再看漏在外面，于是 iOS 顶栏右上角
                // 一次冒出两个「编辑」。iOS 上移除记录走长按菜单（见下面 rowContent）。
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "完成" : "编辑") {
                        withAnimation { isEditing.toggle() }
                    }
                    .disabled(usableItems.isEmpty)
                }
                // 独立刷新按钮只留 macOS；iOS 用下拉刷新（见 RecommendView 同处说明）
                ToolbarItem {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
                #endif
            }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        // 扫码登录走 sheet、不让本页 disappear，裸 `.task` 不会重跑：
        // 用登录状态作 id，登录成功后自动补一次拉取（与稍后再看/动态页一致）。
        .task(id: session.loggedIn) {
            // 登出时清掉「已尝试过」标记：换号再登录要重新拉一次，
            // 否则 `loadIfNeeded` 的 `!hasLoaded` 守卫会把请求挡死、列表停在上一个账号的数据上。
            guard session.loggedIn else { hasLoaded = false; return }
            await loadIfNeeded()
        }
    }

    /// 页面内右上角的「编辑 / 完成」按钮（仅 iOS）。行为与原工具栏按钮一致。
    #if os(iOS)
    private var pageEditButton: some View {
        Button(isEditing ? "完成" : "编辑") {
            withAnimation { isEditing.toggle() }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .foregroundStyle(isEditing ? Color.accentColor : Color.primary)
        .disabled(usableItems.isEmpty)
        .opacity(usableItems.isEmpty ? 0.4 : 1)
        .accessibilityLabel(isEditing ? "完成编辑" : "编辑")
    }
    #endif

    private var loginPrompt: some View {
        LoginRequiredView(title: "登录后查看历史",
                          systemImage: "clock.arrow.circlepath",
                          message: "需要登录哔哩哔哩账号才能同步观看历史",
                          showLogin: $showLogin)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading && items.isEmpty {
                    VideoFeedSkeleton(mode: displayMode)
                } else if let errorMessage, items.isEmpty {
                    LoadErrorView(message: errorMessage) {
                        await load()
                    }
                } else if usableItems.isEmpty {
                    EmptyStateView(title: "暂无观看历史", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VideoFeedLayout(mode: displayMode) {
                        ForEach(usableItems) { item in
                            EditableFeedItem(isEditing: isEditing) {
                                remove(item)
                            } content: {
                                NavigationLink(value: item.history?.bvid ?? "") {
                                    VideoCardView(
                                        bvid: item.history?.bvid ?? "",
                                        title: item.title ?? "未知标题",
                                        pic: item.cover ?? "",
                                        duration: item.duration ?? 0,
                                        ownerName: item.authorName ?? "未知UP主",
                                        viewCount: 0,
                                        badgeText: nil
                                    )
                                }
                                .buttonStyle(.plain)
                                .videoHeroSource(item.history?.bvid ?? "")
                                .contextMenu {
                                    Button("删除历史记录", role: .destructive) {
                                        remove(item)
                                    }
                                }
                            }
                        }
                    } rowContent: {
                        ForEach(usableItems) { item in
                            EditableFeedItem(isEditing: isEditing) {
                                remove(item)
                            } content: {
                                NavigationLink(value: item.history?.bvid ?? "") {
                                    row(item)
                                }
                                .buttonStyle(.plain)
                                .videoHeroSource(item.history?.bvid ?? "")
                                .contextMenu {
                                    Button("删除历史记录", role: .destructive) {
                                        remove(item)
                                    }
                                }
                            }
                        }
                    }

                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                        await loadMore()
                    }
                }
            }
            // 不再 .contentWidth()：它把内容封顶 980pt，首页没有这层封顶，
            // 宽屏上「我的」列数就比首页少、右边还空一块（产品要求与首页统一）。
            .padding(20)
        }
        .feedRefreshable { await load() }
        .autoLoadMore { await loadMore() }
    }

    private func row(_ item: HistoryItem) -> some View {
        let duration = Double(item.duration ?? 0)
        let progress = duration > 0 ? Double(item.progress ?? 0) / duration : 0
        let done = (item.progress ?? 0) >= Int(duration) && duration > 0

        return MediaListRow(
            coverURL: item.cover ?? "",
            title: item.title ?? "未知标题",
            line2: item.authorName ?? "未知UP主",
            line3: "\(item.badge ?? (done ? "已看完" : "看到 \(Formatters.duration(item.progress ?? 0))")) · \(Formatters.timeAgo(item.viewAt ?? 0))",
            durationText: Formatters.duration(item.duration ?? 0),
            progress: progress
        )
    }

    private func loadIfNeeded() async {
        guard !hasLoaded, session.loggedIn else { return }
        await load()
    }

    private func load() async {
        // 单飞 + 「已尝试过」即置位（与首页/直播页同一套语义）
        guard !isLoading else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LibraryService().history()
            items = data.list
            BiliImages.prefetch(data.list.map(\.cover), variant: .card)
            cursor = data.cursor
            hasMore = !data.list.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 删除一条历史：接口成功后本地同步删除（编辑模式与长按菜单共用）。
    private func remove(_ item: HistoryItem) {
        Task {
            guard let aid = item.history?.oid else { return }
            try? await LibraryService().removeHistory(aid: aid)
            items.removeAll { $0.id == item.id }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !items.isEmpty, let cursor else { return }
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let data = try await LibraryService().history(
                max: cursor.max ?? 0,
                business: cursor.business ?? "",
                viewAt: cursor.viewAt ?? 0
            )
            let fresh = items.appendUnique(data.list)
            self.cursor = data.cursor
            hasMore = !fresh.isEmpty
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}
