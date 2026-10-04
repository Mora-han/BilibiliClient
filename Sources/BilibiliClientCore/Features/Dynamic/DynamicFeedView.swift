import SwiftUI

struct DynamicFeedView: View {
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新 / 编辑按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @AppStorage("upBarPosition") private var upBarPosition = UpBarPosition.top.rawValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var items: [DynamicItem] = []
    @State private var followedUPs: [FollowedUser] = []
    @State private var selectedUP: Int?
    @State private var offset: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    /// 请求代次：切 UP 时自增，用来丢弃过期请求的结果
    @State private var loadToken = 0
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    /// 上一次 `prepare()` 时的登录状态：用来区分「登录态变了要重拉」和
    /// 「标签切回来 task 又跑了一遍」，后者绝不能重新请求。
    @State private var preparedLoginState: Bool?

    var body: some View {
        HStack(spacing: 0) {
            if showsLeftBar {
                leftBar
                Divider()
            }

            VStack(spacing: 0) {
                if !showsLeftBar {
                    topBar
                    Divider()
                }
                feedContent
            }
        }
        #if os(macOS)
        // iOS 左上角不放页面标题（去掉「动态」这类页面名，直接呈现内容）
        .navigationTitle("动态")
        // 独立刷新按钮只留 macOS；iOS 用下拉刷新（见 RecommendView 同处说明）
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
        #endif
        .overlay {
            if !isLoading, let errorMessage, items.isEmpty {
                LoadErrorView(message: errorMessage) {
                    await load()
                }
            }
        }
        // 登录状态变化要重新拉一次关注 UP 栏：首次进入未登录时它会直接跳过，
        // 而扫码登录走的是 sheet，不会让本页 disappear，裸 `.task` 不会重跑。
        // 反方向同样要守住：已登录时旧守卫（`!hasLoaded || session.loggedIn`）恒真，
        // 标签切回来 task 一重跑就把动态流重刷了一遍 —— 用登录状态比对挡掉，
        // 没手动刷新就一直保留现有内容。
        .task(id: session.loggedIn) {
            if hasLoaded, preparedLoginState == session.loggedIn { return }
            await prepare()
            preparedLoginState = session.loggedIn
        }
    }

    /// 是否竖排 UP 栏。iPhone 紧凑宽度下强制回到上侧横向栏：
    /// 固定 170pt 的侧栏会把 393pt 宽的屏挤到信息流只剩 ~180pt，
    /// 卡片里的固定 128pt 封面直接把标题压没。
    private var showsLeftBar: Bool {
        upBarPosition == UpBarPosition.left.rawValue && horizontalSizeClass != .compact
    }

    private var displayItems: [DynamicItem] {
        guard selectedUP != nil else { return items }
        return items.filter {
            $0.modules.moduleDynamic?.major?.type == "MAJOR_TYPE_ARCHIVE"
        }
    }

    /// 上侧：横向滚动的 UP 筛选栏
    private var topBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", isSelected: selectedUP == nil) {
                    selectUP(nil)
                }
                ForEach(followedUPs) { up in
                    chip(title: up.uname ?? "UP", isSelected: selectedUP == up.mid, avatar: up.face ?? "") {
                        selectUP(up.mid)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 左侧：竖向固定的 UP 筛选栏
    private var leftBar: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                chip(title: "全部", isSelected: selectedUP == nil) {
                    selectUP(nil)
                }
                ForEach(followedUPs) { up in
                    chip(title: up.uname ?? "UP", isSelected: selectedUP == up.mid, avatar: up.face ?? "") {
                        selectUP(up.mid)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 170)
    }

    /// 动态内容列表（含下拉刷新与滚动自动加载）
    private var feedContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading && items.isEmpty {
                    // 首屏先铺与真实卡片同构的空白占位，接口返回后原地替换
                    DynamicFeedSkeleton(mode: displayMode)
                } else if displayMode == .list2, horizontalSizeClass != .compact {
                    // 两列列表：动态卡片双列排布，与其他页面保持一致。
                    // iPhone 紧凑宽度下同样降级成单列（原因见 `VideoFeedLayout`）。
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        ForEach(displayItems) { item in
                            DynamicCardView(item: item)
                        }
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(displayItems) { item in
                            DynamicCardView(item: item)
                        }
                    }
                }

                if !items.isEmpty {
                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                        await loadMore()
                    }
                }
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .feedRefreshable { await load() }
        .autoLoadMore { await loadMore() }
    }

    private func chip(title: String, isSelected: Bool, avatar: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let avatar, !avatar.isEmpty {
                    RemoteImage(url: Formatters.https(avatar), variant: .avatar)
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                }
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                // 液态玻璃胶囊：选中时叠加主题色
                ZStack {
                    Capsule()
                        .fill(.white.opacity(0.05))
                        .glassEffect(.regular, in: .capsule)
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
                }
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func selectUP(_ mid: Int?) {
        selectedUP = mid
        items = []
        offset = nil
        hasMore = true
        // 作废在途请求：否则旧 UP 的结果会在稍后写回 `items`，
        // 芯片高亮已经是新 UP，列表里却是上一个 UP 的内容。
        loadToken += 1
        if isLoading {
            // 正在加载时 `load()` 会被 guard 挡掉；放掉标记，等它按 token 丢弃旧结果后补一次。
            isLoading = false
        }
        Task { await load() }
    }

    private func prepare() async {
        if session.loggedIn {
            if session.user == nil {
                await session.refreshUser()
            }
            if let mid = session.user?.mid {
                do {
                    let data = try await RelationService().followings(mid: mid, page: 1, pageSize: 50)
                    followedUPs = data.list
                } catch {
                    // 关注栏失败不影响动态流
                }
            }
        }
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        // 「已尝试过」即置位（失败也算）：与其余信息流页同一套语义
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        loadToken += 1
        let token = loadToken
        do {
            let data = try await DynamicService().feed(hostMid: selectedUP)
            // 请求期间用户又切了 UP：这份结果已经过期，直接丢弃
            guard token == loadToken else { return }
            items = data.items
            BiliImages.prefetchDynamic(data.items)
            offset = data.offset
            hasMore = data.hasMore ?? false
        } catch {
            guard token == loadToken else { return }
            errorMessage = error.localizedDescription
        }
        if token == loadToken {
            isLoading = false
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, let offset, hasMore, !items.isEmpty else { return }
        isLoadingMore = true
        loadMoreFailed = false
        let token = loadToken
        do {
            let data = try await DynamicService().feed(offset: offset, hostMid: selectedUP)
            guard token == loadToken else {
                isLoadingMore = false
                return
            }
            let fresh = items.appendUnique(data.items)
            self.offset = data.offset
            hasMore = (data.hasMore ?? false) && !fresh.isEmpty
        } catch {
            if token == loadToken { loadMoreFailed = true }
        }
        isLoadingMore = false
    }
}

/// 动态卡片：视频动态点击直接播放；图片/文字/图文/转发等其他动态点击进入详情页。
struct DynamicCardView: View {
    let item: DynamicItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            authorHeader

            if isVideoPost {
                cardBody
            } else {
                NavigationLink(value: DynamicRoute(id: item.idStr)) {
                    cardBody
                }
                .buttonStyle(.plain)
            }

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 14)
    }

    /// 是否属于“视频投稿”动态（点击目标为播放视频）。
    private var isVideoPost: Bool {
        item.modules.moduleDynamic?.major?.type == "MAJOR_TYPE_ARCHIVE"
    }

    // MARK: - 头部

    private var authorHeader: some View {
        HStack(spacing: 10) {
            Group {
                if let mid = item.modules.moduleAuthor?.mid {
                    NavigationLink(value: UpRoute(mid: mid)) {
                        RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""), variant: .avatar)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""), variant: .avatar)
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.modules.moduleAuthor?.name ?? "未知用户")
                    .font(.callout.weight(.semibold))
                if let time = item.modules.moduleAuthor?.pubTime {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    // MARK: - 正文

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = dynamicText, !text.isEmpty {
                RichText(text: text, font: .callout, lineSpacing: 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            majorContent

            if let orig = item.orig {
                DynamicQuoteView(origin: orig)
            }
        }
    }

    /// 卡片主文字：图文动态优先取 desc，其次摘要；其余取动态正文。
    private var dynamicText: String? {
        if let text = item.modules.moduleDynamic?.desc?.text, !text.isEmpty {
            return text
        }
        if item.modules.moduleDynamic?.major?.type == "MAJOR_TYPE_OPUS" {
            return item.modules.moduleDynamic?.major?.opus?.summary?.text
        }
        return nil
    }

    @ViewBuilder
    private var majorContent: some View {
        if let major = item.modules.moduleDynamic?.major {
            switch major.type {
            case "MAJOR_TYPE_ARCHIVE":
                if let archive = major.archive {
                    DynamicArchiveRow(archive: archive)
                }
            case "MAJOR_TYPE_DRAW":
                if let draw = major.draw {
                    DynamicImageGridView(urls: draw.imageURLs)
                }
            case "MAJOR_TYPE_OPUS":
                if let opus = major.opus {
                    if !opus.picsURLs.isEmpty {
                        DynamicImageGridView(urls: opus.picsURLs)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            DynamicLikeButton(dynamicID: item.idStr,
                              initialLiked: stat?.like?.status ?? false,
                              initialCount: stat?.like?.count ?? 0)
            Label(Formatters.count(stat?.comment?.count ?? 0), systemImage: "bubble.right")
            Label(Formatters.count(stat?.forward?.count ?? 0), systemImage: "arrowshape.turn.up.right")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var stat: DynamicItem.ModuleStat? {
        item.modules.moduleStat
    }
}

/// 转发动态中的引用内容块：动态流内仅展示（外层已是转发详情链接）；
/// 详情页中开启 opensOrigin 后，整块可点跳转到原动态自己的详情页。
struct DynamicQuoteView: View {
    let origin: DynamicOrigin
    var opensOrigin = false

    var body: some View {
        let box = quoteBox
        if opensOrigin, let oid = origin.idStr, !oid.isEmpty {
            NavigationLink(value: DynamicRoute(id: oid)) {
                box
            }
            .buttonStyle(.plain)
            .help("查看原动态")
        } else {
            box
        }
    }

    private var quoteBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RemoteImage(url: Formatters.https(origin.modules?.moduleAuthor?.face ?? ""), variant: .avatar)
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                Text(origin.modules?.moduleAuthor?.name ?? "未知用户")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            if let text = quotedText, !text.isEmpty {
                RichText(text: text, font: .callout, selectable: false)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            quotedContent
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private var quotedText: String? {
        if let text = origin.modules?.moduleDynamic?.desc?.text, !text.isEmpty {
            return text
        }
        if origin.modules?.moduleDynamic?.major?.type == "MAJOR_TYPE_OPUS" {
            return origin.modules?.moduleDynamic?.major?.opus?.summary?.text
        }
        return nil
    }

    @ViewBuilder
    private var quotedContent: some View {
        let major = origin.modules?.moduleDynamic?.major
        if let archive = major?.archive {
            DynamicArchiveRow(archive: archive, linked: false)
        } else if let draw = major?.draw {
            DynamicImageGridView(urls: draw.imageURLs, maxWidth: 220)
        } else if let opus = major?.opus {
            DynamicImageGridView(urls: opus.picsURLs, maxWidth: 220)
        }
    }
}

/// 视频动态的封面信息行：点击进入播放。
struct DynamicArchiveRow: View {
    let archive: DynamicItem.ModuleDynamic.Major.Archive
    var linked = true

    var body: some View {
        if linked, let bvid = archive.bvid, !bvid.isEmpty {
            NavigationLink(value: bvid) {
                rowContent
            }
            .buttonStyle(.plain)
            .videoHeroSource(bvid)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            RemoteImage(url: Formatters.https(archive.cover ?? ""), variant: .card)
                .frame(width: 128, height: 76)
                .cornerRadius(8, style: .circular)

            VStack(alignment: .leading, spacing: 4) {
                Text(archive.title ?? "")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let desc = archive.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let duration = archive.durationText {
                    Text(duration)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 统一的动态图片网格（兼容带图 draw 与图文 opus.pics）。
struct DynamicImageGridView: View {
    let urls: [URL?]
    var maxWidth: CGFloat = .infinity
    var spacing: CGFloat = 6
    var cornerRadius: CGFloat = 8

    private var validURLs: [URL] {
        urls.compactMap { $0 }
    }

    var body: some View {
        if !validURLs.isEmpty {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                                count: min(max(validURLs.count, 1), 3))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(validURLs.enumerated()), id: \.offset) { _, url in
                    DynamicImageTile(url: url, cornerRadius: cornerRadius)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
    }
}

/// 动态图片块：以所在宽度为基准强制 1:1 正方形并裁剪铺满。
/// 不给原图尺寸参与布局的机会，避免图片把卡片/容器撑宽造成错位。
struct DynamicImageTile: View {
    let url: URL
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: url, variant: .keepAspect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .cornerRadius(cornerRadius, style: .circular)
    }
}

/// 动态点赞按钮：乐观更新，失败自动回滚。
struct DynamicLikeButton: View {
    let dynamicID: String
    let initialLiked: Bool
    let initialCount: Int

    @State private var liked: Bool
    @State private var count: Int
    @State private var isBusy = false

    init(dynamicID: String, initialLiked: Bool, initialCount: Int) {
        self.dynamicID = dynamicID
        self.initialLiked = initialLiked
        self.initialCount = initialCount
        _liked = State(initialValue: initialLiked)
        _count = State(initialValue: initialCount)
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: liked ? "heart.fill" : "heart")
                Text(Formatters.count(count))
            }
            .font(.caption)
            .foregroundStyle(liked ? Color.red : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(liked ? "取消点赞" : "点赞")
    }

    private func toggle() {
        guard !isBusy else { return }
        isBusy = true
        let target = !liked
        let delta = target ? 1 : -1
        liked = target
        count = max(0, count + delta)
        Task {
            defer { isBusy = false }
            do {
                try await DynamicService().like(dynamicID: dynamicID, liked: target)
            } catch {
                liked = !target
                count = max(0, count - delta)
            }
        }
    }
}

extension DynamicItem.ModuleDynamic.Major.Draw {
    var imageURLs: [URL?] {
        (items ?? []).map { Formatters.https($0.src ?? "") }
    }
}

extension DynamicItem.ModuleDynamic.Major.Opus {
    var picsURLs: [URL?] {
        (pics ?? []).map { Formatters.https($0.url ?? $0.src ?? "") }
    }
}
