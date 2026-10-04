import SwiftUI

/// 分区排行榜页（卡片流 + 排行序号）
struct PartitionVideosView: View {
    let zone: BiliZone

    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var videos: [PopularVideo] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    private var usableVideos: [PopularVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 与其余列表页同一套判据：只有「正在加载/出错且手上没内容」才换掉列表，
                // 否则下拉刷新会把已有内容整页吃掉、刷新失败还会覆盖成错误页。
                if isLoading && videos.isEmpty {
                    VideoFeedSkeleton(mode: displayMode)
                } else if let errorMessage, videos.isEmpty {
                    LoadErrorView(message: errorMessage) {
                        await load()
                    }
                } else if usableVideos.isEmpty {
                    EmptyStateView(title: "该分区暂无排行数据", systemImage: "chart.bar")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
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
                            .videoHeroSource(video.bvid ?? "")
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
                            .videoHeroSource(video.bvid ?? "")
                        }
                    }
                }
            }
            .padding(20)
        }
        #if os(macOS)
        // 独立刷新按钮只留 macOS；iOS 用下拉刷新（见 RecommendView 同处说明）
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
        #endif
        .navigationTitle("\(zone.name) 排行榜")
        .feedRefreshable { await load() }
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
            let data = try await HomeService().ranking(rid: zone.id, type: "all")
            videos = data.list
            BiliImages.prefetch(data.list.map(\.pic), variant: .card)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
