import SwiftUI

struct FavoritesView: View {
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新 / 编辑按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var folders: [FavFolder] = []
    @State private var selectedFolderId: Int?
    @State private var medias: [FavMedia] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var showLogin = false
    @State private var isEditing = false

    private var usableMedias: [FavMedia] {
        medias.filter { $0.isUsable && ($0.type ?? 0) == 2 && !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !session.loggedIn {
                loginPrompt
            } else {
                content
            }
        }
        .navigationTitle("收藏")
        .toolbar {
            if isTabVisible {
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "完成" : "编辑") {
                        withAnimation { isEditing.toggle() }
                    }
                    .disabled(usableMedias.isEmpty)
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
        // 用登录状态作 id，登录成功后自动补一次拉取（与稍后再看/动态页一致）。
        .task(id: session.loggedIn) {
            // 登出时清掉「已尝试过」标记：换号再登录要重新拉一次，
            // 否则 `loadIfNeeded` 的 `!hasLoaded` 守卫会把请求挡死、列表停在上一个账号的数据上。
            guard session.loggedIn else { hasLoaded = false; return }
            await loadIfNeeded()
        }
    }

    private var loginPrompt: some View {
        LoginRequiredView(title: "登录后查看收藏",
                          systemImage: "bookmark",
                          message: "需要登录哔哩哔哩账号才能同步收藏夹",
                          showLogin: $showLogin)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !folders.isEmpty {
                    folderChips
                }

                if isLoading && medias.isEmpty {
                    VideoFeedSkeleton(mode: displayMode)
                } else if let errorMessage, medias.isEmpty {
                    LoadErrorView(message: errorMessage) {
                        await load()
                    }
                } else if usableMedias.isEmpty {
                    EmptyStateView(title: "这个收藏夹里还没有视频", systemImage: "bookmark")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VideoFeedLayout(mode: displayMode) {
                        ForEach(usableMedias) { media in
                            EditableFeedItem(isEditing: isEditing) {
                                remove(media)
                            } content: {
                                NavigationLink(value: media.bvid ?? "") {
                                    VideoCardView(
                                        bvid: media.bvid ?? "",
                                        title: media.title ?? "",
                                        pic: media.cover ?? "",
                                        duration: media.duration ?? 0,
                                        ownerName: media.upper?.name ?? "未知UP主",
                                        viewCount: media.cntInfo?.play ?? 0,
                                        badgeText: nil
                                    )
                                }
                                .buttonStyle(.plain)
                                .videoHeroSource(media.bvid ?? "")
                                .contextMenu {
                                    Button("从收藏夹移除", role: .destructive) {
                                        remove(media)
                                    }
                                }
                            }
                        }
                    } rowContent: {
                        ForEach(usableMedias) { media in
                            EditableFeedItem(isEditing: isEditing) {
                                remove(media)
                            } content: {
                                NavigationLink(value: media.bvid ?? "") {
                                    MediaListRow(
                                        coverURL: media.cover ?? "",
                                        title: media.title ?? "",
                                        line2: media.upper?.name ?? "未知UP主",
                                        line3: "收藏于 \(Formatters.timeAgo(media.favTime ?? 0)) · 播放 \(Formatters.count(media.cntInfo?.play ?? 0))",
                                        durationText: Formatters.duration(media.duration ?? 0)
                                    )
                                }
                                .buttonStyle(.plain)
                                .videoHeroSource(media.bvid ?? "")
                                .contextMenu {
                                    Button("从收藏夹移除", role: .destructive) {
                                        remove(media)
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
            .contentWidth()
            .padding(20)
        }
        .feedRefreshable { await load() }
        .autoLoadMore { await loadMore() }
    }

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folders) { folder in
                    Button {
                        selectFolder(folder)
                    } label: {
                        HStack(spacing: 5) {
                            Text(folder.title ?? "未命名")
                            if let count = folder.mediaCount {
                                Text("\(count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedFolderId == folder.id
                                ? AnyShapeStyle(.tint.opacity(0.2))
                                : AnyShapeStyle(.quaternary.opacity(0.4)),
                            in: Capsule()
                        )
                        .foregroundStyle(selectedFolderId == folder.id ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded, session.loggedIn else { return }
        await load()
    }

    private func load() async {
        // 「已尝试过」即置位（失败也算）：切走再回来不自动重拉，避免 keep-alive
        // 反复进出页面反复打请求（与首页/直播页同一套语义）。
        hasLoaded = true
        guard let mid = session.user?.mid else {
            await session.refreshUser()
            guard let mid = session.user?.mid else { return }
            await loadFolders(mid: mid)
            return
        }
        await loadFolders(mid: mid)
    }

    private func loadFolders(mid: Int) async {
        // 单飞：.task 与下拉刷新撞车时只发一次收藏夹请求
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LibraryService().favoriteFolders(mid: mid)
            folders = data.list ?? []
            if let first = folders.first {
                selectFolder(first)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func selectFolder(_ folder: FavFolder) {
        selectedFolderId = folder.id
        medias = []
        page = 0
        hasMore = true
        Task { await loadFolderResources(mediaId: folder.id) }
    }

    private func loadFolderResources(mediaId: Int) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LibraryService().favoriteResources(mediaId: mediaId, page: 1)
            medias = data.medias
            BiliImages.prefetch(data.medias.map { $0.cover }, variant: .card)
            page = 1
            hasMore = data.hasMore ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 从当前收藏夹移除一条：接口成功后本地同步删除。
    private func remove(_ media: FavMedia) {
        Task {
            guard let folderID = selectedFolderId else { return }
            try? await LibraryService().removeFavorite(aid: media.id, folderId: folderID)
            medias.removeAll { $0.id == media.id }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !medias.isEmpty, let folderId = selectedFolderId else { return }
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let data = try await LibraryService().favoriteResources(mediaId: folderId, page: page + 1)
            let fresh = medias.appendUnique(data.medias)
            page += 1
            hasMore = (data.hasMore ?? false) && !fresh.isEmpty
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}
