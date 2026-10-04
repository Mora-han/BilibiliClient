import SwiftUI

/// UP 主主页
struct UpProfileView: View {
    let mid: Int

    @EnvironmentObject private var session: SessionStore
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
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
    /// `load()`（info + videos 两连发）是否在途：单飞用它判断，
    /// **不能**借用 `isLoadingInfo` —— 它的初值是 true（用来首屏出骨架），
    /// v1.9.12 曾拿它当守卫，结果 `.task` 首次调用就被挡死，页面永远停在骨架屏。
    @State private var isLoadInFlight = false
    /// 「已尝试过」：进过页就置位（失败也不再自动重拉），下拉刷新与手动重试不受影响。
    @State private var hasLoaded = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
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
            .contentWidth()
            .padding(24)
        }
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
        .navigationTitle(card?.name ?? "UP主页")
        .autoLoadMore { await loadMore() }
        .feedRefreshable { await load() }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .task {
            // 「已尝试过」即不再自动重拉：切走再回来不重新请求（下拉刷新仍可用）
            guard !hasLoaded else { return }
            await load()
        }
    }

    @ViewBuilder
    private var headerArea: some View {
        if let card {
            header(card)
        } else if isLoadingInfo {
            ProfileHeaderSkeleton()
        } else if let infoError {
            LoadErrorView(message: infoError) {
                await loadInfo()
            }
            .frame(maxWidth: .infinity, minHeight: 100)
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        if isLoadingVideos && usableVideos.isEmpty {
            VideoFeedSkeleton(mode: displayMode)
        } else if let videoError, usableVideos.isEmpty {
            LoadErrorView(message: videoError) {
                await loadVideos()
            }
        } else if usableVideos.isEmpty {
            EmptyStateView(title: "还没有投稿视频", systemImage: "video")
                .frame(maxWidth: .infinity, minHeight: 160)
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
                        .videoHeroSource(video.bvid ?? "")
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
                        .videoHeroSource(video.bvid ?? "")
                    }
                }

                if !usableVideos.isEmpty {
                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                        await loadMore()
                    }
                }
            }
        }
    }

    private func header(_ card: UpCardData.Card) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: Formatters.https(card.face ?? ""), variant: .avatar)
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
        // 单飞：刷新手势与 .task 撞车时只跑一轮
        guard !isLoadInFlight else { return }
        isLoadInFlight = true
        hasLoaded = true
        await loadInfo()
        await loadVideos()
        isLoadInFlight = false
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
            BiliImages.prefetch(data.archives.compactMap(\.pic), variant: .card)
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
        loadMoreFailed = false
        do {
            let data = try await UpService().videos(mid: mid, page: page + 1, order: order.apiValue)
            let fresh = videos.appendUnique(data.archives)
            page += 1
            hasMore = !fresh.isEmpty
        } catch {
            loadMoreFailed = true
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
