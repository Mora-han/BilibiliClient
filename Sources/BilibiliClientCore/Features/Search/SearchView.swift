import SwiftUI

struct SearchView: View {
    /// 路由带来的初始搜索词（标签跳转、macOS 侧边栏搜索提交都会带词进来）。
    let query: String
    /// 已提交的搜索词：iOS 的页内输入框改的就是它；macOS 没有页内输入框，
    /// 初始值等于路由词，行为与改动前一致。
    @State private var submitted: String
    /// 页内输入框的当前文字（仅 iOS 展示，见 `searchField`）。
    @State private var input: String
    #if os(iOS)
    @FocusState private var inputFocused: Bool
    #endif

    init(query: String) {
        self.query = query
        _submitted = State(initialValue: query)
        _input = State(initialValue: query)
    }

    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
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
    /// 上一次真正搜过的词：同词重入不重搜（见 `.task(id: submitted)` 的守卫）。
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
            #if os(iOS)
            // 页内搜索输入栏（App Store 搜索页形态）：顶栏胶囊里的放大镜按钮推进本页，
            // 输入框就在这里、空词进入自动聚焦。刻意不用系统 `.searchable`——它会给
            // 顶栏另挂一颗自己的放大镜，和头像那组并排出现两颗（实测）。
            searchField
            Divider()
            #endif
            if !submitted.isEmpty {
                header
                Divider()
            }
            // 挂在结果区（而不是最外层 VStack）：iOS 的刷新控件按「锚点中心落在哪个
            // UIScrollView」定位，锚点对准结果区中心才稳；同时骨架 / 出错 / 空结果
            // 三个分支也都能拉了 —— 原先只有「有结果」分支里能拉。
            resultArea
                .feedRefreshable {
                    await search(reset: true)
                }
        }
        #if os(macOS)
        // 独立刷新按钮只留 macOS；iOS 用下拉刷新（见 RecommendView 同处说明）
        .toolbar {
            if isTabVisible {
                ToolbarItem {
                    Button {
                        Task { await search(reset: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
            }
        }
        #endif
        .navigationTitle("搜索")
        .task(id: submitted) {
            guard !submitted.isEmpty else { return }
            // 页面重新出现（标签切回、被盖住再回来）时 task 会重跑：同一词已有
            // 结果就不再重搜，没手动刷新前保留现有结果；失败后（结果为空）重进
            // 照常再试一次，换词则由 id 变化触发、不受影响。
            if lastSearched == submitted, !results.isEmpty { return }
            lastSearched = submitted
            await search(reset: true)
        }
        .onChange(of: query) { _, newValue in
            // 路由带新词进来（如标签点击、再次带词推入同一页）：同步页内状态，
            // 上面的 task(id:) 接着搜。同一目的地复用 @State 时 init 不会重跑，
            // 这条 onChange 是唯一的同步点。
            guard newValue != submitted else { return }
            submitted = newValue
            input = newValue
        }
    }

    #if os(iOS)
    /// 页内搜索输入栏：胶囊输入框，回车即搜（App Store 搜索页同款形态）。
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索视频 / UP 主", text: $input)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($inputFocused)
                .onSubmit { submitInput() }
            if !input.isEmpty {
                Button {
                    input = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear {
            // 顶栏放大镜空词进入：自动聚焦、键盘直接可用；标签带词跳转进来不打扰
            if submitted.isEmpty { inputFocused = true }
        }
    }

    /// 提交输入框：空词不动；与当前词相同不重复搜；不同则替换 submitted 触发 task(id:)。
    private func submitInput() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != submitted else { return }
        submitted = trimmed
        inputFocused = false
    }
    #endif

    private var header: some View {
        HStack(spacing: 12) {
            Text(submitted)
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
        if submitted.isEmpty {
            // 多包一层 VStack 只为固定最小高度，EmptyStateView 自己就能撑开
            EmptyStateView(title: emptyHint,
                           systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if isLoading && results.isEmpty {
            // 先用与结果区同宽同列的空白占位，避免「搜索中」白屏
            ScrollView {
                VideoFeedSkeleton(mode: displayMode)
                    .contentWidth()
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
            EmptyStateView(title: "没有找到相关视频",
                           systemImage: "magnifyingglass")
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
                                .videoHeroSource(bvid)
                            }
                        }
                    } rowContent: {
                        ForEach(results) { video in
                            if let bvid = video.bvid, !bvid.isEmpty {
                                NavigationLink(value: bvid) {
                                    row(video)
                                }
                                .buttonStyle(.plain)
                                .videoHeroSource(bvid)
                            }
                        }
                    }

                    if !results.isEmpty {
                        LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                            await search(reset: false)
                        }
                    }
                }
                .contentWidth()
                .padding(20)
            }
            // 与首页信息流完全一致（默认 threshold 2000）：滚动到离底部还有约两屏时
            // 就预取下一页，内容始终领着滚动走，基本看不到底部「加载中」。
            // 请求风暴的根因是 LoadMoreFooter 的 onAppear 自循环和「停在顶部就预取」，
            // 已由 autoLoadMore 的三道闸门（滚动过才触发 / 单飞 / 每次贴底最多 5 页）
            // 拦住，不再靠缩小阈值来防。
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

    /// 空词提示：iOS 输入框就在本页顶部，macOS 靠侧边栏搜索框。
    private var emptyHint: String {
        #if os(iOS)
        return "在上方输入关键词搜索视频"
        #else
        return "在左上角搜索框输入关键词"
        #endif
    }

    private func search(reset: Bool) async {
        let trimmed = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
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
                let fresh = results.appendUnique(data.result)
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
        if reset, submitted.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed {
            await search(reset: true)
        }
    }
}
