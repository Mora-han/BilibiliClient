import SwiftUI

struct SearchView: View {
    let query: String

    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var results: [SearchVideo] = []
    @State private var page = 0
    /// 结果总数：接口没给（App 端端点）时为 nil，界面就不显示假的「0 个视频」。
    @State private var numResults: Int?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    @State private var errorMessage: String?
    @State private var order: SearchOrder = .totalrank
    /// 上一次真正搜过的词：同词重入不重搜（见 `.task(id: query)` 的守卫）。
    @State private var lastSearched: String?
    /// 被限流时的自动重试时间：界面倒计时到点后自己补一次搜索。
    @State private var autoRetryAt: Date?

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
            // 页面重新出现（标签切回、被盖住再回来）时 task 会重跑：同一词已有
            // 结果就不再重搜，没手动刷新前保留现有结果；失败后（结果为空）重进
            // 照常再试一次，换词则由 id 变化触发、不受影响。
            if lastSearched == query, !results.isEmpty { return }
            lastSearched = query
            await search(reset: true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(query)
                .font(.headline)
                .lineLimit(1)
            if let numResults {
                Text("找到 \(Formatters.count(numResults)) 个视频")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("搜索结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            // 先用与结果区同宽同列的空白占位，避免「搜索中」白屏
            ScrollView {
                VideoFeedSkeleton(mode: displayMode)
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        } else if let errorMessage, results.isEmpty {
            VStack(spacing: 14) {
                LoadErrorView(message: errorMessage) {
                    await search(reset: true)
                }
                if let at = autoRetryAt, at.timeIntervalSinceNow > 0 {
                    Text("已暂停自动重试，\(Int(at.timeIntervalSinceNow.rounded())) 秒后继续")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
                guard let at = autoRetryAt, now >= at else { return }
                autoRetryAt = nil
                Task { await search(reset: true) }
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
                    VideoFeedLayout(mode: displayMode) {
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
                    } rowContent: {
                        ForEach(results) { video in
                            if let bvid = video.bvid, !bvid.isEmpty {
                                NavigationLink(value: bvid) {
                                    row(video)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !results.isEmpty {
                        LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                            await search(reset: false)
                        } onRetry: {
                            await search(reset: false)
                        }
                    }
                }
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .feedRefreshable {
                await search(reset: true)
            }
            // 搜索结果页把预取距离收紧一些：默认 2000 会在一次搜索里连着翻好几页，
            // 搜索接口对短时间内的连续请求比较敏感（容易吃到风控），少翻两页更稳。
            .autoLoadMore(threshold: 900) {
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
            numResults = nil
            hasMore = true
            loadMoreFailed = false
            errorMessage = nil
            isLoading = true
        } else {
            guard !isLoadingMore, hasMore, !results.isEmpty else { return }
            isLoadingMore = true
            loadMoreFailed = false
        loadMoreFailed = false
        }

        do {
            let targetPage = reset ? 1 : page + 1
            let data = try await SearchService().videos(keyword: trimmed, page: targetPage, order: order.apiValue)
            var addedCount = 0
            if reset {
                results = data.result
                BiliImages.prefetch(data.result.map(\.pic), variant: .card)
                page = 1
                addedCount = results.count
            } else {
                let seen = Set(results.map(\.id))
                let fresh = data.result.filter { !seen.contains($0.id) }
                results.append(contentsOf: fresh)
                page = targetPage
                addedCount = fresh.count
            }
            autoRetryAt = nil
            numResults = data.numResults
            // 本页没有新增内容时停止，避免无限重复请求；总数未知就只看「有没有新增」
            hasMore = addedCount > 0
                && results.count < (numResults ?? Int.max)
                && (data.numPages ?? 1) > targetPage
        } catch {
            autoRetryAt = SearchService.rateLimitRetryAt
            if reset {
                errorMessage = error.localizedDescription
            } else {
                loadMoreFailed = true
            }
        }
        isLoading = false
        isLoadingMore = false
        // 打字期间上一轮还在跑时，新词的那次调用会被上面的 isLoading 守卫跳过：
        // 等这轮结束对比一下当前词，不是同一个就补搜最新词，保证「最新输入必达」。
        if reset, query.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed {
            await search(reset: true)
        }
    }
}
