import SwiftUI

/// 推荐页（视频卡片流）
struct RecommendView: View {
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var items: [RecommendItem] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var hasMore = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
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
                    }
                }
            }
            .padding(20)

            if !items.isEmpty {
                LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                    await loadMore()
                }
            }
        }
        .navigationTitle("推荐")
        .autoLoadMore { await loadMore() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView("加载中…")
            } else if let errorMessage, items.isEmpty {
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
        isLoading = true
        errorMessage = nil
        do {
            let newItems = try await FeedService().recommend(page: 1)
            items = newItems
            page = 1
            hasLoaded = true
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
        do {
            let newItems = try await FeedService().recommend(page: page + 1)
            let seen = Set(items.map(\.id))
            let fresh = newItems.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            page += 1
            // 本页没有新增内容（接口翻页返回重复或空）时停止自动加载，避免无限转圈
            hasMore = !fresh.isEmpty
        } catch {
            // 翻页失败：保留 hasMore，点击底部提示可重试
        }
        isLoadingMore = false
    }
}
