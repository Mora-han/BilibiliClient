import SwiftUI

@MainActor
struct WatchLaterView: View {
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新 / 编辑按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var items: [ToViewItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var showLogin = false
    @State private var isEditing = false

    private var usableItems: [ToViewItem] {
        items.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !session.loggedIn {
                loginPrompt
            } else {
                content
            }
        }
        .navigationTitle("稍后再看")
        .toolbar {
            if isTabVisible {
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "完成" : "编辑") {
                        withAnimation { isEditing.toggle() }
                    }
                    .disabled(usableItems.isEmpty)
                }
                ToolbarItem {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
            }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        // 扫码登录走 sheet、不让本页 disappear，裸 `.task` 不会重跑：
        // 用登录状态作 id，登录成功后自动补一次拉取（收藏/历史/动态页同款）。
        .task(id: session.loggedIn) {
            // 登出时清掉「已尝试过」标记：换号再登录要重新拉一次，
            // 否则 `loadIfNeeded` 的 `!hasLoaded` 守卫会把请求挡死、列表停在上一个账号的数据上。
            guard session.loggedIn else { hasLoaded = false; return }
            await loadIfNeeded()
        }
    }

    private var loginPrompt: some View {
        LoginRequiredView(title: "登录后查看稍后再看",
                          systemImage: "clock.badge.checkmark",
                          message: "需要登录哔哩哔哩账号才能同步稍后再看列表",
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
                    EmptyStateView(title: "稍后再看是空的", systemImage: "clock.badge.checkmark")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VideoFeedLayout(mode: displayMode) {
                        ForEach(usableItems) { item in
                            EditableFeedItem(isEditing: isEditing) {
                                remove(item)
                            } content: {
                                NavigationLink(value: item.bvid ?? "") {
                                    VideoCardView(
                                        bvid: item.bvid ?? "",
                                        title: item.title ?? "未知标题",
                                        pic: item.pic ?? "",
                                        duration: item.duration ?? 0,
                                        ownerName: item.owner?.name ?? "未知UP主",
                                        viewCount: item.stat?.view ?? 0,
                                        badgeText: nil
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("移出稍后再看", role: .destructive) {
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
                                NavigationLink(value: item.bvid ?? "") {
                                    row(item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("移出稍后再看", role: .destructive) {
                                        remove(item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .contentWidth()
            .padding(20)
        }
        .feedRefreshable { await load() }
    }

    private func row(_ item: ToViewItem) -> some View {
        let duration = Double(item.duration ?? 0)
        let progress = duration > 0 ? Double(item.progress ?? 0) / duration : 0

        return MediaListRow(
            coverURL: item.pic ?? "",
            title: item.title ?? "未知标题",
            line2: item.owner?.name ?? "未知UP主",
            line3: "添加于 \(Formatters.timeAgo(item.addAt ?? 0)) · 播放 \(Formatters.count(item.stat?.view ?? 0))",
            durationText: Formatters.duration(item.duration ?? 0),
            progress: progress
        )
    }

    /// 移出稍后再看：接口成功后本地同步删除（编辑模式与长按菜单共用）。
    private func remove(_ item: ToViewItem) {
        Task {
            try? await LibraryService().removeFromWatchLater(aid: item.aid)
            items.removeAll { $0.id == item.id }
        }
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
            let data = try await LibraryService().watchLater()
            items = data.list
            BiliImages.prefetch(data.list.map(\.pic), variant: .card)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
