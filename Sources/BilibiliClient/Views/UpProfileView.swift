import SwiftUI

/// UP 主主页
struct UpProfileView: View {
    let mid: Int

    @State private var card: UpCardData.Card?
    @State private var followerCount = 0
    @State private var videos: [UpVideo] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoadingInfo = true
    @State private var isLoadingVideos = true
    @State private var isLoadingMore = false
    @State private var infoError: String?
    @State private var videoError: String?

    private var usableVideos: [UpVideo] {
        videos.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerArea
                videoSection
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle(card?.name ?? "UP主页")
        .task { await load() }
    }

    @ViewBuilder
    private var headerArea: some View {
        if let card {
            header(card)
        } else if isLoadingInfo {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let infoError {
            HStack {
                Text(infoError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    Task { await loadInfo() }
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if isLoadingVideos {
            ProgressView("加载投稿中…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let videoError, usableVideos.isEmpty {
            ContentUnavailableView {
                Label("投稿加载失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(videoError)
            } actions: {
                Button("重试") {
                    Task { await loadVideos() }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                          spacing: 16) {
                    ForEach(usableVideos) { video in
                        NavigationLink(value: video.bvid ?? "") {
                            VideoCardView(
                                bvid: video.bvid ?? "",
                                title: video.title ?? "未知标题",
                                pic: video.pic ?? "",
                                duration: video.duration ?? 0,
                                ownerName: "",
                                viewCount: video.play ?? 0,
                                badgeText: nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
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

    private func header(_ card: UpCardData.Card) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: Formatters.https(card.face ?? ""))
                .frame(width: 76, height: 76)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(card.name ?? "未知用户")
                        .font(.title2.bold())
                    if let title = card.official?.title, !title.isEmpty {
                        Text(title)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                if let level = card.levelInfo?.currentLevel {
                    Text("Lv.\(level)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let sign = card.sign, !sign.isEmpty {
                    Text(sign)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 20) {
                    Text("关注 \(Formatters.count(card.attention ?? 0))")
                    Text("粉丝 \(Formatters.count(followerCount))")
                    Text("投稿 \(usableVideos.count)\(hasMore ? "+" : "")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private func load() async {
        await loadInfo()
        await loadVideos()
    }

    private func loadInfo() async {
        isLoadingInfo = true
        infoError = nil
        do {
            let data = try await UpService().info(mid: mid)
            card = data.card
            followerCount = data.follower ?? data.card?.fans ?? 0
        } catch {
            infoError = error.localizedDescription
        }
        isLoadingInfo = false
    }

    private func loadVideos() async {
        isLoadingVideos = true
        videoError = nil
        do {
            let data = try await UpService().videos(mid: mid, page: 1)
            videos = data.list?.vlist ?? []
            page = 1
            hasMore = !videos.isEmpty
        } catch {
            videoError = error.localizedDescription
        }
        isLoadingVideos = false
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
