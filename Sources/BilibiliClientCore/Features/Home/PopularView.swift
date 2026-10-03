import SwiftUI

/// 热门页：按排行顺序的卡片流，封面右上角标记序号
struct PopularView: View {
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var videos: [PopularVideo] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    private var usableVideos: [PopularVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading && videos.isEmpty {
                    VideoFeedSkeleton(mode: displayMode)
                } else {
                    if !usableVideos.isEmpty {
                        Text("共 \(Formatters.count(usableVideos.count)) 个热门视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VideoFeedLayout(mode: displayMode) {
                        ForEach(usableVideos.indices, id: \.self) { index in
                            let video = usableVideos[index]
                            NavigationLink(value: video.bvid ?? "") {
                                VideoCardView(
                                    bvid: video.bvid ?? "",
                                    title: video.title ?? "未知标题",
                                    pic: video.pic ?? "",
                                    duration: video.duration ?? 0,
                                    ownerName: video.owner?.name ?? "",
                                    viewCount: video.stat?.view ?? 0,
                                    rank: index + 1
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } rowContent: {
                        ForEach(usableVideos.indices, id: \.self) { index in
                            let video = usableVideos[index]
                            NavigationLink(value: video.bvid ?? "") {
                                MediaListRow(
                                    coverURL: video.pic ?? "",
                                    title: video.title ?? "未知标题",
                                    line2: "#\(index + 1) \(video.owner?.name ?? "未知UP主")",
                                    line3: "播放 \(Formatters.count(video.stat?.view ?? 0))",
                                    durationText: Formatters.duration(video.duration ?? 0)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !usableVideos.isEmpty {
                        LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                            await loadMore()
                        } onRetry: {
                            await loadMore()
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("热门")
        .autoLoadMore { await loadMore() }
        .feedRefreshable { await load() }
        .overlay {
            if !isLoading, let errorMessage, videos.isEmpty {
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
        // 单飞 + 「已尝试过」即置位（见直播页注释）
        guard !isLoading else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        do {
            let data = try await HomeService().popular(page: 1, pageSize: 20)
            videos = data.list
            BiliImages.prefetch(data.list.map(\.pic), variant: .card)
            page = 1
            hasMore = !(data.noMore ?? false)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !videos.isEmpty else { return }
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let data = try await HomeService().popular(page: page + 1, pageSize: 20)
            let seen = Set(videos.map(\.id))
            let fresh = data.list.filter { !seen.contains($0.id) }
            videos.append(contentsOf: fresh)
            page += 1
            hasMore = !(data.noMore ?? false) && !fresh.isEmpty
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}
