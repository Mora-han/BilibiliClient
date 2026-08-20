import SwiftUI

/// UP 主主页
struct UpProfileView: View {
    let mid: Int

    @State private var info: UpInfo?
    @State private var videos: [UpVideo] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    private var usableVideos: [UpVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let info {
                    header(info)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }

                if let errorMessage, videos.isEmpty {
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
                    Text("还没有投稿视频")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("投稿视频")
                            .font(.title3.bold())
                        LazyVStack(spacing: 12) {
                            ForEach(usableVideos) { video in
                                NavigationLink(value: video.bvid ?? "") {
                                    row(video)
                                }
                                .buttonStyle(.plain)
                            }
                            if hasMore {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    if isLoadingMore {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("加载更多")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle(info?.name ?? "UP主页")
        .task { await load() }
    }

    private func header(_ info: UpInfo) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: Formatters.https(info.face ?? ""))
                .frame(width: 76, height: 76)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(info.name ?? "未知用户")
                        .font(.title2.bold())
                    if let title = info.official?.title, !title.isEmpty {
                        Text(title)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                if let level = info.level {
                    Text("Lv.\(level)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let sign = info.sign, !sign.isEmpty {
                    Text(sign)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 20) {
                    Text("关注 \(Formatters.count(info.attention ?? 0))")
                    Text("粉丝 \(Formatters.count(info.fans ?? 0))")
                    Text("硬币 \(Formatters.decimal(info.coins ?? 0))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private func row(_ video: UpVideo) -> some View {
        MediaListRow(
            coverURL: video.pic ?? "",
            title: video.title ?? "未知标题",
            line2: "播放 \(Formatters.count(video.play ?? 0)) · \(Formatters.timeAgo(video.created ?? 0))",
            line3: video.description ?? "",
            durationText: video.length ?? Formatters.duration(video.duration ?? 0)
        )
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let infoTask: UpInfo = UpService().info(mid: mid)
            async let videosTask: UpVideosData = UpService().videos(mid: mid, page: 1)
            let (infoResult, videosResult) = try await (infoTask, videosTask)
            info = infoResult
            videos = videosResult.list?.vlist ?? []
            page = 1
            hasMore = !videos.isEmpty
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await UpService().videos(mid: mid, page: page + 1)
            let seen = Set(videos.map(\.id))
            videos.append(contentsOf: (data.list?.vlist ?? []).filter { !seen.contains($0.id) })
            page += 1
            hasMore = !(data.list?.vlist ?? []).isEmpty
        } catch {
            // 静默失败
        }
        isLoadingMore = false
    }
}
