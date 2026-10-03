import SwiftUI

/// 推荐页（视频卡片流）
struct RecommendView: View {
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新 / 编辑按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var items: [RecommendItem] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var hasMore = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading && items.isEmpty {
                    // 首屏先用空白占位铺出卡片网格，接口返回后再原地替换成真实内容
                    VideoFeedSkeleton(mode: displayMode)
                } else {
                    VideoFeedLayout(mode: displayMode) {
                        ForEach(items) { item in
                            NavigationLink(value: item.bvid) {
                                VideoCardView(
                                    bvid: item.bvid,
                                    title: item.title,
                                    pic: item.pic,
                                    duration: item.duration,
                                    ownerName: item.owner?.name ?? "",
                                    viewCount: item.stat?.view ?? 0,
                                    badgeText: item.rcmdReason?.content
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("加入稍后再看") {
                                    Task { try? await LibraryService().addToWatchLater(aid: item.id, bvid: item.bvid) }
                                }
                            }
                        }
                    } rowContent: {
                        ForEach(items) { item in
                            NavigationLink(value: item.bvid) {
                                MediaListRow(
                                    coverURL: item.pic,
                                    title: item.title,
                                    line2: item.owner?.name ?? "未知UP主",
                                    line3: "播放 \(Formatters.count(item.stat?.view ?? 0))",
                                    durationText: Formatters.duration(item.duration)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("加入稍后再看") {
                                    Task { try? await LibraryService().addToWatchLater(aid: item.id, bvid: item.bvid) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)

            if !items.isEmpty {
                LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                    await loadMore()
                } onRetry: {
                    await loadMore()
                }
            }
        }
        .navigationTitle("推荐")
        .autoLoadMore { await loadMore() }
        .feedRefreshable { await load() }
        .toolbar {
            if isTabVisible {
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
        .overlay {
            if !isLoading, let errorMessage, items.isEmpty {
                LoadErrorView(message: errorMessage) {
                    await load()
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            await load()
        }
    }

    private func load() async {
        // 单飞 + 「已尝试过」即置位（失败后重新出现不再自动重拉，见直播页注释）
        guard !isLoading else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        do {
            let newItems = try await FeedService().recommend(page: 1)
            items = newItems
            BiliImages.prefetch(newItems.map(\.pic), variant: .card)
            page = 1
            hasMore = !newItems.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        // 首屏就绪后立即预载下一页，让内容缓冲领先于滚动位置
        if hasMore && !items.isEmpty {
            Task { await loadMore() }
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !items.isEmpty else { return }
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let newItems = try await FeedService().recommend(page: page + 1)
            let seen = Set(items.map(\.id))
            let fresh = newItems.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            page += 1
            // 本页没有新增内容（接口翻页返回重复或空）时停止自动加载，避免无限转圈
            hasMore = !fresh.isEmpty
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}
