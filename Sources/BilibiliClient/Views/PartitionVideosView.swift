import SwiftUI

/// 分区排行榜页（卡片流 + 排行序号）
struct PartitionVideosView: View {
    let zone: BiliZone

    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var videos: [PopularVideo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var usableVideos: [PopularVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage {
                    LoadErrorView(message: errorMessage) {
                        await load()
                    }
                } else if usableVideos.isEmpty {
                    Text("该分区暂无排行数据")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    if displayMode == .card {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                                  spacing: 16) {
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
                        }
                    } else {
                        LazyVStack(spacing: 12) {
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
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("\(zone.name) 排行榜")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let data = try await HomeService().ranking(rid: zone.id, type: "all")
            videos = data.list
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
