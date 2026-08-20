import SwiftUI

struct HomeFeedView: View {
    var onSearch: (String) -> Void = { _ in }

    @State private var items: [RecommendItem] = []
    @State private var popular: [PopularVideo] = []
    @State private var hotTags: [String] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var isLoadingPopular = false
    @State private var isLoadingTags = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                partitionSection
                hotTagsSection
                popularSection
                Divider()
                recommendSection
            }
            .padding(20)
        }
        .navigationTitle("首页")
        .task {
            guard !hasLoaded else { return }
            await loadAll()
        }
    }

    // MARK: - 分区

    private var partitionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分区")
                .font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(BiliZones.main) { zone in
                        NavigationLink(value: PartitionRoute(tid: zone.id, name: zone.name)) {
                            VStack(spacing: 6) {
                                Image(systemName: zone.icon)
                                    .font(.title3)
                                Text(zone.name)
                                    .font(.caption)
                            }
                            .foregroundStyle(.primary)
                            .frame(width: 66, height: 66)
                            .glassCard(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 热门标签

    @ViewBuilder
    private var hotTagsSection: some View {
        if !hotTags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("热门标签")
                    .font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hotTags, id: \.self) { tag in
                            Button {
                                onSearch(tag)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "flame.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Text(tag)
                                        .font(.callout)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassCard(cornerRadius: 16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - 热门视频

    @ViewBuilder
    private var popularSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("热门视频")
                .font(.title3.bold())

            if isLoadingPopular {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 10) {
                    ForEach(popular.prefix(6)) { video in
                        if let bvid = video.bvid, !bvid.isEmpty {
                            NavigationLink(value: bvid) {
                                MediaListRow(
                                    coverURL: video.pic ?? "",
                                    title: video.title ?? "",
                                    line2: "\(video.owner?.name ?? "未知UP主") · \(video.tname ?? "")",
                                    line3: "播放 \(Formatters.count(video.stat?.view ?? 0)) · 弹幕 \(Formatters.count(video.stat?.danmaku ?? 0)) · \(Formatters.timeAgo(video.pubdate ?? 0))",
                                    durationText: Formatters.duration(video.duration ?? 0)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 推荐

    private var recommendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("推荐")
                .font(.title3.bold())

            if isLoading && items.isEmpty {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        Task { await loadAll() }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                          spacing: 16) {
                    ForEach(items) { item in
                        NavigationLink(value: item.bvid) {
                            VideoCardView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !items.isEmpty {
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

    // MARK: - 数据

    private func loadAll() async {
        async let recommendTask: Void = loadRecommend()
        async let popularTask: Void = loadPopular()
        async let tagsTask: Void = loadHotTags()
        _ = await (recommendTask, popularTask, tagsTask)
        hasLoaded = true
    }

    private func loadRecommend() async {
        isLoading = true
        errorMessage = nil
        do {
            let newItems = try await FeedService().recommend(page: 1)
            items = newItems
            page = 1
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadPopular() async {
        guard !isLoadingPopular else { return }
        isLoadingPopular = true
        do {
            let data = try await HomeService().popular(page: 1, pageSize: 10)
            popular = data.list
        } catch {
            // 热门视频失败不影响首页其他部分
        }
        isLoadingPopular = false
    }

    private func loadHotTags() async {
        guard !isLoadingTags else { return }
        isLoadingTags = true
        do {
            let data = try await HomeService().hotTags(limit: 16)
            hotTags = (data.trending?.list ?? []).compactMap { $0.keyword }.filter { !$0.isEmpty }
        } catch {
            // 失败静默
        }
        isLoadingTags = false
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let newItems = try await FeedService().recommend(page: page + 1)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: newItems.filter { !seen.contains($0.id) })
            page += 1
        } catch {
            // 静默失败
        }
        isLoadingMore = false
    }
}

struct VideoCardView: View {
    let item: RecommendItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text(item.owner?.name ?? "未知UP主")
                    .lineLimit(1)
                Spacer()
                if let stat = item.stat, stat.view > 0 {
                    Image(systemName: "play.fill")
                    Text(Formatters.count(stat.view))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(hovering ? 0.22 : 0), lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: Formatters.https(item.pic))
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)

            if item.duration > 0 {
                Text(Formatters.duration(item.duration))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if let reason = item.rcmdReason?.content, !reason.isEmpty {
                Text(reason)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.pink.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
