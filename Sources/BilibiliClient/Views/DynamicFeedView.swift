import SwiftUI

struct DynamicFeedView: View {
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @AppStorage("upBarPosition") private var upBarPosition = UpBarPosition.top.rawValue
    @State private var items: [DynamicItem] = []
    @State private var followedUPs: [FollowedUser] = []
    @State private var selectedUP: Int?
    @State private var offset: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        HStack(spacing: 0) {
            if upBarPosition == UpBarPosition.left.rawValue {
                leftBar
                Divider()
            }

            VStack(spacing: 0) {
                if upBarPosition == UpBarPosition.top.rawValue {
                    topBar
                    Divider()
                }
                feedContent
            }
        }
        .navigationTitle("动态")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView("加载中…")
            } else if let errorMessage, items.isEmpty {
                LoadErrorView(message: errorMessage) {
                    await load()
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            await prepare()
        }
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
                if displayMode == .list2 {
                    // 两列列表：动态卡片双列排布，与其他页面保持一致
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
                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                        await loadMore()
                    }
                }
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .refreshable { await load() }
        .autoLoadMore { await loadMore() }
    }

    private func chip(title: String, isSelected: Bool, avatar: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let avatar, !avatar.isEmpty {
                    RemoteImage(url: Formatters.https(avatar))
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
        isLoading = true
        errorMessage = nil
        do {
            let data = try await DynamicService().feed(hostMid: selectedUP)
            items = data.items
            offset = data.offset
            hasMore = data.hasMore ?? false
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, let offset, hasMore, !items.isEmpty else { return }
        isLoadingMore = true
        do {
            let data = try await DynamicService().feed(offset: offset, hostMid: selectedUP)
            let seen = Set(items.map(\.id))
            let fresh = data.items.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            self.offset = data.offset
            hasMore = (data.hasMore ?? false) && !fresh.isEmpty
        } catch {
            // 翻页失败静默
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
                        RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
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
                Text(text)
                    .font(.callout)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            majorContent

            if let orig = item.orig {
                DynamicQuoteView(origin: orig)
            }

            footer
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
            Label(Formatters.count(stat?.like?.count ?? 0), systemImage: "heart")
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
                RemoteImage(url: Formatters.https(origin.modules?.moduleAuthor?.face ?? ""))
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                Text(origin.modules?.moduleAuthor?.name ?? "未知用户")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            if let text = quotedText, !text.isEmpty {
                Text(text)
                    .font(.callout)
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
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            RemoteImage(url: Formatters.https(archive.cover ?? ""))
                .frame(width: 128, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))

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

    private var validURLs: [URL] {
        urls.compactMap { $0 }
    }

    var body: some View {
        if !validURLs.isEmpty {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                                count: min(max(validURLs.count, 1), 3))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(validURLs.enumerated()), id: \.offset) { _, url in
                    RemoteImage(url: url)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: maxWidth)
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
