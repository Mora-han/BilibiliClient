import SwiftUI

/// 分区排行榜页
struct PartitionVideosView: View {
    let zone: BiliZone

    @State private var videos: [PopularVideo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var usableVideos: [PopularVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await load() }
                        }
                    }
                } else if usableVideos.isEmpty {
                    Text("该分区暂无排行数据")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(usableVideos) { video in
                            NavigationLink(value: video.bvid ?? "") {
                                row(video)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .navigationTitle("\(zone.name) 排行榜")
        .task { await load() }
    }

    private func row(_ video: PopularVideo) -> some View {
        MediaListRow(
            coverURL: video.pic ?? "",
            title: video.title ?? "未知标题",
            line2: "\(video.owner?.name ?? "未知UP主") · \(video.tname ?? "")",
            line3: "播放 \(Formatters.count(video.stat?.view ?? 0)) · 弹幕 \(Formatters.count(video.stat?.danmaku ?? 0)) · \(Formatters.timeAgo(video.pubdate ?? 0))",
            durationText: Formatters.duration(video.duration ?? 0)
        )
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
