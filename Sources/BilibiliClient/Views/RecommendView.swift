import SwiftUI

/// 推荐页（视频卡片流）
struct RecommendView: View {
    @State private var items: [RecommendItem] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var hasMore = true

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                      spacing: 16) {
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
            }
            .padding(20)

            if hasMore {
                LoadMoreFooter(isBusy: isLoadingMore) {
                    await loadMore()
                }
            }
        }
        .navigationTitle("推荐")
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
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let newItems = try await FeedService().recommend(page: page + 1)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: newItems.filter { !seen.contains($0.id) })
            page += 1
            hasMore = !newItems.isEmpty
        } catch {
            // 翻页失败静默
        }
        isLoadingMore = false
    }
}
