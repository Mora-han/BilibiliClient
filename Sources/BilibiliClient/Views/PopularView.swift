import SwiftUI

/// 热门页：按排行顺序的卡片流，封面右上角标记序号
struct PopularView: View {
    @State private var videos: [PopularVideo] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    private var usableVideos: [PopularVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !usableVideos.isEmpty {
                    Text("共 \(Formatters.count(usableVideos.count)) 个热门视频")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                if hasMore && !usableVideos.isEmpty {
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
            .padding(20)
        }
        .navigationTitle("热门")
        .overlay {
            if isLoading && videos.isEmpty {
                ProgressView("加载中…")
            } else if let errorMessage, videos.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
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
            let data = try await HomeService().popular(page: 1, pageSize: 20)
            videos = data.list
            page = 1
            hasMore = !(data.noMore ?? true)
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await HomeService().popular(page: page + 1, pageSize: 20)
            let seen = Set(videos.map(\.id))
            videos.append(contentsOf: data.list.filter { !seen.contains($0.id) })
            page += 1
            hasMore = !(data.noMore ?? true)
        } catch {
            // 静默失败
        }
        isLoadingMore = false
    }
}
