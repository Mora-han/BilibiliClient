import SwiftUI

struct SearchView: View {
    let query: String

    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var results: [SearchVideo] = []
    @State private var page = 0
    @State private var numResults = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var order: SearchOrder = .totalrank

    enum SearchOrder: String, CaseIterable, Identifiable {
        case totalrank = "综合排序"
        case click = "最多播放"
        case pubdate = "最新发布"
        case dm = "最多弹幕"
        case stow = "最多收藏"
        case scores = "最多评论"

        var id: String { rawValue }

        var apiValue: String {
            switch self {
            case .totalrank: return "totalrank"
            case .click: return "click"
            case .pubdate: return "pubdate"
            case .dm: return "dm"
            case .stow: return "stow"
            case .scores: return "scores"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !query.isEmpty {
                header
                Divider()
            }
            resultArea
        }
        .navigationTitle("搜索")
        .task(id: query) {
            guard !query.isEmpty else { return }
            await search(reset: true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(query)
                .font(.headline)
                .lineLimit(1)
            Text("找到 \(Formatters.count(numResults)) 个视频")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(SearchOrder.allCases) { item in
                    Button {
                        guard order != item else { return }
                        order = item
                        Task { await search(reset: true) }
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
        .padding(14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var resultArea: some View {
        if query.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("在左上角搜索框输入关键词")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if isLoading && results.isEmpty {
            ProgressView("搜索中…")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let errorMessage, results.isEmpty {
            LoadErrorView(message: errorMessage) {
                await search(reset: true)
            }
        } else if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("没有找到相关视频")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if displayMode == .card {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                                  spacing: 16) {
                            ForEach(results) { video in
                                if let bvid = video.bvid, !bvid.isEmpty {
                                    NavigationLink(value: bvid) {
                                        VideoCardView(
                                            bvid: bvid,
                                            title: video.cleanTitle,
                                            pic: video.pic ?? "",
                                            duration: Formatters.seconds(fromDurationText: video.duration),
                                            ownerName: video.author ?? "未知UP主",
                                            viewCount: video.play ?? 0,
                                            badgeText: nil
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(results) { video in
                                if let bvid = video.bvid, !bvid.isEmpty {
                                    NavigationLink(value: bvid) {
                                        row(video)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if !results.isEmpty {
                        LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                            await search(reset: false)
                        }
                    }
                }
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .refreshable {
                await search(reset: true)
            }
            .autoLoadMore {
                await search(reset: false)
            }
        }
    }

    private func row(_ video: SearchVideo) -> some View {
        MediaListRow(
            coverURL: video.pic ?? "",
            title: video.cleanTitle,
            line2: "\(video.author ?? "未知UP主") · \(video.typename ?? "")",
            line3: "播放 \(Formatters.count(video.play ?? 0)) · 弹幕 \(Formatters.count(video.videoReview ?? 0)) · 收藏 \(Formatters.count(video.favorites ?? 0)) · \(Formatters.timeAgo(video.pubdate ?? 0))",
            durationText: video.duration
        )
    }

    private func search(reset: Bool) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if reset {
            guard !isLoading else { return }
            page = 0
            results = []
            numResults = 0
            hasMore = true
            errorMessage = nil
            isLoading = true
        } else {
            guard !isLoadingMore, hasMore, !results.isEmpty else { return }
            isLoadingMore = true
        }

        do {
            let targetPage = reset ? 1 : page + 1
            let data = try await SearchService().videos(keyword: trimmed, page: targetPage, order: order.apiValue)
            var addedCount = 0
            if reset {
                results = data.result
                page = 1
                addedCount = results.count
            } else {
                let seen = Set(results.map(\.id))
                let fresh = data.result.filter { !seen.contains($0.id) }
                results.append(contentsOf: fresh)
                page = targetPage
                addedCount = fresh.count
            }
            numResults = data.numResults ?? results.count
            // 本页没有新增内容时停止，避免无限重复请求
            hasMore = addedCount > 0 && results.count < numResults && (data.numPages ?? 1) > targetPage
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
        isLoadingMore = false
    }
}
