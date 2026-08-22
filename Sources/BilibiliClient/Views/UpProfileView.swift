import SwiftUI

/// UP 主主页
struct UpProfileView: View {
    let mid: Int

    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var card: UpCardData.Card?
    @State private var order: UpOrder = .pubdate
    @State private var followerCount = 0
    @State private var videos: [SeriesArchive] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoadingInfo = true
    @State private var isLoadingVideos = true
    @State private var isLoadingMore = false
    @State private var infoError: String?
    @State private var videoError: String?
    @State private var isFollowing = false
    @State private var isTogglingFollow = false
    @State private var showLogin = false

    enum UpOrder: String, CaseIterable, Identifiable {
        case pubdate = "最新发布"
        case views = "最多播放"

        var id: String { rawValue }

        var apiValue: String {
            switch self {
            case .pubdate: return "pubdate"
            case .views: return "views"
            }
        }
    }

    private var usableVideos: [SeriesArchive] {
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
        .autoLoadMore { await loadMore() }
        .refreshable { await load() }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
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
            LoadErrorView(message: infoError) {
                await loadInfo()
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if isLoadingVideos {
            ProgressView("加载投稿中…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let videoError, usableVideos.isEmpty {
            LoadErrorView(message: videoError) {
                await loadVideos()
            }
        } else if usableVideos.isEmpty {
            Text("还没有投稿视频")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("投稿视频")
                        .font(.title3.bold())
                    Spacer()
                    Menu {
                        ForEach(UpOrder.allCases) { item in
                            Button {
                                guard order != item else { return }
                                order = item
                                Task { await loadVideos() }
                            } label: {
                                if item == order {
                                    Label(item.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(item.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(order.rawValue)
                                .font(.callout)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                VideoFeedLayout(mode: displayMode) {
                    ForEach(usableVideos) { video in
                        NavigationLink(value: video.bvid ?? "") {
                            VideoCardView(
                                bvid: video.bvid ?? "",
                                title: video.title ?? "未知标题",
                                pic: video.pic ?? "",
                                duration: video.duration ?? 0,
                                ownerName: "",
                                viewCount: video.stat?.view ?? 0,
                                badgeText: nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } rowContent: {
                    ForEach(usableVideos) { video in
                        NavigationLink(value: video.bvid ?? "") {
                            MediaListRow(
                                coverURL: video.pic ?? "",
                                title: video.title ?? "未知标题",
                                line2: "投稿视频",
                                line3: "播放 \(Formatters.count(video.stat?.view ?? 0))",
                                durationText: Formatters.duration(video.duration ?? 0)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !usableVideos.isEmpty {
                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                        await loadMore()
                    }
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

            followButton
        }
        .padding(14)
        .contentCard(cornerRadius: 16)
    }

    private var followButton: some View {
        Group {
            if isFollowing {
                Button {
                    toggleFollow()
                } label: {
                    Label("已关注", systemImage: "checkmark")
                        .font(.callout.weight(.medium))
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    toggleFollow()
                } label: {
                    if isTogglingFollow {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 64)
                    } else {
                        Label("关注", systemImage: "plus")
                            .font(.callout.weight(.medium))
                            .frame(minWidth: 64)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .disabled(isTogglingFollow)
        .help(isFollowing ? "取消关注" : "关注")
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
            if session.loggedIn {
                isFollowing = (try? await RelationService().relation(fid: mid))?.isFollowing ?? false
            }
        } catch {
            infoError = error.localizedDescription
        }
        isLoadingInfo = false
    }

    private func loadVideos() async {
        isLoadingVideos = true
        videoError = nil
        do {
            let data = try await UpService().videos(mid: mid, page: 1, order: order.apiValue)
            videos = data.archives
            page = 1
            hasMore = !videos.isEmpty
        } catch {
            videoError = error.localizedDescription
        }
        isLoadingVideos = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !videos.isEmpty else { return }
        isLoadingMore = true
        do {
            let data = try await UpService().videos(mid: mid, page: page + 1, order: order.apiValue)
            let seen = Set(videos.map(\.id))
            let fresh = data.archives.filter { !seen.contains($0.id) }
            videos.append(contentsOf: fresh)
            page += 1
            hasMore = !fresh.isEmpty
        } catch {
            // 翻页失败静默，滚动后可重试
        }
        isLoadingMore = false
    }

    private func toggleFollow() {
        guard session.loggedIn else {
            showLogin = true
            return
        }
        guard !isTogglingFollow else { return }
        isTogglingFollow = true
        let target = !isFollowing
        Task {
            do {
                try await RelationService().modify(fid: mid, follow: target)
                isFollowing = target
                followerCount += target ? 1 : -1
            } catch {
                // 失败保持原状，静默
            }
            isTogglingFollow = false
        }
    }
}
