#if os(macOS)
import AppKit
#endif
import SwiftUI

struct VideoDetailView: View {
    let bvid: String

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var router: AppRouter
    /// 本页所在的标签页是否可见：隐藏标签不响应全局 path 变化，见 `\.isTabVisible`
    @Environment(\.isTabVisible) private var isTabVisible
    /// 宽度类：用来区分 iPad（regular）与 iPhone / 窄 iPad（compact）。
    /// 只在 iOS 的两栏布局里读；macOS 不参与，行为不变。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// 高度类：iPhone 横屏为 compact。用来切横屏的播放页布局。
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// iPhone 横屏（垂直方向紧凑）：此时可用高度不足以同时容纳 16:9 画面与信息区。
    private var isCompactHeight: Bool { verticalSizeClass == .compact }
    @StateObject private var player = PlayerController()
    @State private var danmaku = DanmakuEngine()
    /// 按需创建的播放窗口：默认不存在，画面就播在页面里
    @StateObject private var playbackWindow = PlayerWindowController()
    /// 页面里播放区域的屏幕位置：创建播放窗口时用它把窗口精确覆盖到画面处
    @State private var playerArea = PlayerAreaFrameBox()
    /// 当前选中的分P cid（nil = 播放详情默认分P，即第一个分P）
    @State private var selectedPageCid: Int?
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("danmakuSpeed") private var danmakuSpeed = DanmakuSpeed.normal.rawValue
    @AppStorage("danmakuOpacity") private var danmakuOpacity = DanmakuSettings.default.opacity
    @AppStorage("danmakuFontScale") private var danmakuFontScale = DanmakuSettings.default.fontScale
    @AppStorage("danmakuFullscreenScale") private var danmakuFullscreenScale = DanmakuSettings.default.fullscreenScale
    @AppStorage("danmakuDisplayArea") private var danmakuDisplayArea = DanmakuSettings.default.displayArea.rawValue
    @AppStorage("danmakuShowsFloating") private var danmakuShowsFloating = DanmakuSettings.default.showsFloating
    @AppStorage("danmakuShowsTop") private var danmakuShowsTop = DanmakuSettings.default.showsTop
    @AppStorage("danmakuShowsBottom") private var danmakuShowsBottom = DanmakuSettings.default.showsBottom
    @AppStorage("danmakuAllowsOverlap") private var danmakuAllowsOverlap = DanmakuSettings.default.allowsOverlap
    @State private var liked = false
    @State private var coined = false
    @State private var faved = false
    @State private var watchLaterAdded = false
    @State private var favoriteFolders: [FavFolder] = []
    @State private var showFavoritePicker = false
    @State private var shareMessage: String?
    @State private var showCoinMenu = false
    @State private var showShareMenu = false
    @State private var showQualityMenu = false
    @State private var showDanmakuSettings = false
    @State private var isFollowing = false
    @State private var relationLoaded = false
    @State private var likeCount = 0
    @State private var coinCount = 0
    @State private var favCount = 0
    @State private var actionError: String?
    @State private var showLogin = false
    @State private var detail: VideoDetailData?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var comments: [CommentItem] = []
    @State private var commentPage = 0
    @State private var isLoadingComments = false
    @State private var hasMoreComments = true
    @State private var commentError: String?
    @State private var commentTotal: Int?
    @State private var tags: [VideoTagData] = []
    /// 长按点赞蓄力反馈：是否按住中 / 蓄力进度 0...1 / 蓄满后的脉冲
    @State private var likePressActive = false
    @State private var likePressProgress: Double = 0
    @State private var likeChargeTask: Task<Void, Never>?
    @State private var likeChargedPulse = false
    /// 本页首次出现时导航栈的深度（记录后，栈变深=被新页面覆盖，变回=回到本页）
    @State private var navBaseCount = 0

    var body: some View {
        Group {
            if isLoading {
                ScrollView {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            } else if let errorMessage {
                ScrollView {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await load() }
                        }
                    }
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            } else if let view = detail?.view {
                content(view)
            }
        }
        .navigationTitle(detail?.view.title ?? "视频详情")
        .task { await load() }
        .onAppear {
            navBaseCount = router.path.count
            bindPlaybackMenu()
        }
        .onChange(of: danmakuEnabled) { _, newValue in
            PlaybackMenuState.shared.setDanmakuEnabled(newValue)
        }
        .onChange(of: playbackWindow.isDetached) { _, newValue in
            PlaybackMenuState.shared.setDetached(newValue)
        }
        .onChange(of: router.path.count) { _, newCount in
            // 隐藏标签里这一页的 `navBaseCount` 与全局计数是两回事：别的标签把深度动回
            // 这个数时会误判成「回到本页」，于是被停止的播放器又被 `load()` 拉起来，
            // 出现两个标签同时出声。不可见时一律不响应。
            guard isTabVisible else { return }
            if newCount > navBaseCount {
                // 被推入的新页面覆盖（如 UP 主页、评论中的 UP 等）：收起播放窗口并停止播放
                closePlaybackWindow()
                player.stop()
                danmaku.reset()
            } else if newCount == navBaseCount {
                // 回到本页：恢复播放器与弹幕
                Task { await load() }
            }
        }
        .onDisappear {
            PlaybackMenuState.shared.unbind()
            closePlaybackWindow()
            // iOS 的系统全屏（`AVPlayerViewController` 自带）会把整页盖住，SwiftUI 因此
            // 也会发 `onDisappear` —— 可用户并没有离开播放页。按"离开"处理就会：一点
            // 全屏就暂停、弹幕立刻消失，而且播放器一被拆掉，系统在退出时就失去了可以
            // 平滑缩回去的落点，原生退出动画只能退化成下滑渐隐。
            // 全屏中与否由 AVKit 的 delegate 回调给出（见 `IOSPlayerSurface`）；
            // macOS 没有这个形态，恒为 false，行为与改动前完全一致。
            guard !PlayerPresentationState.shared.isSystemFullscreen else { return }
            player.stop()
            danmaku.reset()
        }
        .onChange(of: player.state) { _, state in
            if state == .ready { bindSystemPlayer() }
        }
        .sheet(isPresented: $showLogin) { LoginView() }
        .sheet(isPresented: $showFavoritePicker) {
            FavoritePickerView(folders: favoriteFolders) { folder in
                Task { await saveFavorite(folderId: folder.id) }
                showFavoritePicker = false
            }
        }
        .alert("提示", isPresented: Binding(get: { shareMessage != nil }, set: { if !$0 { shareMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(shareMessage ?? "") }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func load() async {
        if let data = detail {
            // 返回后再进入：恢复已停止的播放器与弹幕
            if player.player == nil {
                await player.load(aid: data.view.aid, bvid: data.view.bvid, cid: activePageCid)
                await loadDanmaku(cid: activePageCid)
            }
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await VideoService().detail(bvid: bvid)
            detail = data
            isLoading = false
            likeCount = data.view.stat.like
            coinCount = data.view.stat.coin ?? 0
            favCount = data.view.stat.favorite ?? 0
            if session.loggedIn {
                async let likedTask = try? UserActionService().hasLiked(aid: data.view.aid)
                async let coinedTask = try? UserActionService().coinCount(aid: data.view.aid)
                async let favedTask = try? UserActionService().hasFavorite(aid: data.view.aid)
                async let watchLaterTask = try? LibraryService().watchLater()
                async let relationTask = try? RelationService().relation(fid: data.view.owner.mid)
                let (likedResult, coinedResult, favedResult, watchLaterResult, relationResult) = await (likedTask, coinedTask, favedTask, watchLaterTask, relationTask)
                liked = likedResult ?? false
                coined = (coinedResult ?? 0) > 0
                faved = favedResult ?? false
                watchLaterAdded = watchLaterResult?.list.contains { $0.aid == data.view.aid || $0.bvid == data.view.bvid } ?? false
                if let relationResult {
                    isFollowing = relationResult.isFollowing
                    relationLoaded = true
                }
            }
            async let commentsTask: Void = loadComments(aid: data.view.aid)
            async let playerTask: Void = player.load(aid: data.view.aid, bvid: data.view.bvid, cid: activePageCid)
            _ = await (commentsTask, playerTask)
            await loadDanmaku(cid: activePageCid)
            await loadTags(aid: data.view.aid, bvid: data.view.bvid)
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// iPad 两栏布局的最小宽度。低于它就说明是「竖屏窄 iPad、分屏、Stage Manager 小窗」——
    /// 硬拆两栏会两边都挤，不如回到单栏。
    private static let twoColumnMinWidth: CGFloat = 820

    /// 播放页主体。
    ///
    /// - iPad（规则宽度 + 屏幕够宽）：两栏 —— 左「画面 + 视频信息」、右「评论」，
    ///   两块各自独立滚动，一屏同时能看到简介与评论。
    /// - 其余（macOS / iPhone / 窄 iPad）：原来那一栏纵向排布，画面固定在顶部。
    @ViewBuilder
    private func content(_ view: VideoDetailData.VideoView) -> some View {
        #if os(iOS)
        // 用 `GeometryReader` 而不是先量后布局：宽度在首帧就已经拿到，
        // 不会先按单栏画一帧再跳成两栏。
        GeometryReader { proxy in
            if horizontalSizeClass == .regular, proxy.size.width >= Self.twoColumnMinWidth {
                wideContent(view, width: proxy.size.width)
            } else {
                stackedContent(view)
            }
        }
        #else
        stackedContent(view)
        #endif
    }

    /// 单栏：macOS 与 iPhone / 窄 iPad 共用。画面固定在页面顶部，下方内容整体滚动。
    ///
    /// 例外是 iPhone 横屏（垂直方向紧凑）：可用高度只有 ~330pt，把画面钉在顶部会
    /// 占掉 16:9 所需的一大半，剩下的信息区被压到放不下。此时改成画面占满整幅宽度、
    /// 随内容一起滚动 —— 看画面时它就在最上方，往下读评论时它自然滚走。
    private func stackedContent(_ view: VideoDetailData.VideoView) -> some View {
        // 紧凑宽度下 24pt 的左右留白对 390pt 的屏来说太多，画面会明显窄一圈
        let horizontalPadding: CGFloat = horizontalSizeClass == .compact ? 16 : 24
        return Group {
            if isCompactHeight {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        playerSection
                        videoInfoSection(view)

                        Divider()

                        commentHeader
                        commentSection(view)

                        Spacer(minLength: 40)
                    }
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            } else {
                VStack(spacing: 0) {
                    // 视频固定在页面顶部：滚动时保持原位完整可见，下方内容独立滑动
                    playerSection
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, 24)

                    // 固定空隙：不属于滚动内容，滚动时始终保留在视频与内容之间
                    Color.clear
                        .frame(height: 18)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            videoInfoSection(view)

                            Divider()

                            commentHeader
                            commentSection(view)

                            Spacer(minLength: 40)
                        }
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
    }

    /// 视频信息：工具行、标题、UP 主与数据、操作栏、分P、简介、TAG。
    /// 单栏与 iPad 两栏共用同一份，保证两种布局里信息一致。
    @ViewBuilder
    private func videoInfoSection(_ view: VideoDetailData.VideoView) -> some View {
        playbackToolbar

        Text(view.title)
            .font(.title2.bold())
            .textSelection(.enabled)

        infoRow(view)

        actionBar(view)

        if let pages = view.pages, pages.count > 1 {
            partSelector(pages)
        }

        Divider()

        Text("简介").font(.headline)
        RichText(text: view.desc.isEmpty ? "该视频没有简介" : view.desc,
                 font: .callout, lineSpacing: 4)
            .foregroundStyle(.secondary)

        if !tags.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(tags) { tag in
                    tagButton(tag)
                }
            }
            .padding(.top, 14)
        }
    }

    #if os(iOS)
    /// iPad 宽屏两栏：左「画面 + 视频信息」，右「评论」，各自独立滚动。
    private func wideContent(_ view: VideoDetailData.VideoView, width: CGFloat) -> some View {
        // 评论栏给固定宽度（随页面宽微调，但有上下限），剩下的全给画面与视频信息
        let commentWidth = min(max(width * 0.38, 320), 460)
        return HStack(alignment: .top, spacing: 0) {
            // 左栏：画面照旧固定在顶部，下面的视频信息自己滚动
            VStack(spacing: 0) {
                playerSection
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                Color.clear
                    .frame(height: 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        videoInfoSection(view)
                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            commentColumn(view)
                .frame(width: commentWidth)
        }
    }

    /// 右栏：评论区独立一列。标题固定，评论自己滚动，与左栏互不影响。
    private func commentColumn(_ view: VideoDetailData.VideoView) -> some View {
        VStack(spacing: 0) {
            commentHeader
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                commentSection(view)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .background(Color.cardSolidBackground)
    }
    #endif

    // MARK: - 分P选集

    /// 当前应播放的分P cid：用户点选优先，未选时用详情默认 cid（第一个分P）。
    private var activePageCid: Int {
        guard let view = detail?.view else { return 0 }
        if let selectedPageCid,
           view.pages?.contains(where: { $0.cid == selectedPageCid }) == true {
            return selectedPageCid
        }
        return view.cid
    }

    /// 下载入口用的请求描述：跟着当前选中的分P 走。
    private func downloadRequest(for view: VideoDetailData.VideoView) -> DownloadRequest {
        let cid = activePageCid
        let page = view.pages?.first { $0.cid == cid }
        return DownloadRequest(bvid: view.bvid,
                               cid: cid,
                               title: view.title,
                               pageTitle: page?.part,
                               pageIndex: page?.page)
    }

    /// 分P选集：标题行 + 可横向滑动的分P卡片列表（点击切换播放）。
    private func partSelector(_ pages: [VideoDetailData.VideoPage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("共 \(pages.count) 个分P", systemImage: "list.number")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(pages) { page in
                        partCard(page)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 单个分P卡片：序号 + 标题 + 时长，横向排布、高度紧凑。
    private func partCard(_ page: VideoDetailData.VideoPage) -> some View {
        let isCurrent = page.cid == activePageCid
        return Button {
            Task { await selectPart(page) }
        } label: {
            HStack(spacing: 8) {
                Text("P\(page.page)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(isCurrent ? Color.pink : Color.primary.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.part)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(Formatters.duration(page.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.pink)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 210, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCurrent ? Color.pink.opacity(0.1) : Color.cardSolidBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isCurrent ? Color.pink.opacity(0.45) : Color.primary.opacity(0.1), lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverScale(scale: 1.02)
    }

    /// 切换分P：重载播放器与弹幕；播放窗口保持吸附，流程与首次进入一致。
    private func selectPart(_ page: VideoDetailData.VideoPage) async {
        guard let view = detail?.view else { return }
        let cid = page.cid
        selectedPageCid = cid
        guard player.cid != cid || player.player == nil else { return }
        danmaku.reset()
        await player.load(aid: view.aid, bvid: view.bvid, cid: cid)
        await loadDanmaku(cid: cid)
    }

    @ViewBuilder
    private var playerSection: some View {
        ZStack {
            switch player.state {
            case .idle, .loading:
                Rectangle().fill(.black)
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载播放地址…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                Rectangle().fill(.black)
                VStack(spacing: 10) {
                    Image(systemName: "play.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("播放失败").font(.headline)
                    Text(player.errorMessage ?? "未知错误")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await retryPlayer() }
                    }
                }
                .padding()
            case .ready:
                if isPlayingInline, let avPlayer = player.player {
                    // 默认形态：播放组件就是页面里的普通视图
                    surface()
                        .id(avPlayer)
                } else {
                    // 画面已移入播放窗口（分离/全屏）：页面位置留空
                    Color.clear
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay {
            // 有画面时保持完整矩形画面，不画边框；占位状态保留一圈细边
            if !isPlayingInline {
                Rectangle()
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
        }
        #if os(macOS)
        // 只有 macOS 需要知道画面的屏幕位置（分离窗口要精确覆盖到画面上）
        .background(
            PlayerAreaReporter(onFrame: { frame in
                playerArea.frame = frame
            })
        )
        #endif
    }

    /// 画面当前是否正在页面内播放（决定页面显示播放组件还是空位）。
    private var isPlayingInline: Bool {
        player.state == .ready && player.player != nil && !playbackWindow.isOpen
    }

    /// 视频下方那一行：观看人数、弹幕开关、分离窗口与清晰度切换。
    /// 页内播放时这三个控件原本浮在画面上，现在统一收在这一行里，画面保持干净。
    @ViewBuilder
    private var playbackToolbar: some View {
        if player.player != nil {
            HStack(spacing: 16) {
                if let text = player.onlineText {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                        Text("\(text) 人在看")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("同时在看的观众数")
                }

                Button {
                    danmakuEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                        Text("弹幕")
                    }
                    .font(.caption)
                    .foregroundStyle(danmakuEnabled ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(danmakuEnabled ? "关闭弹幕" : "开启弹幕")

                Button {
                    showDanmakuSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("弹幕设置")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("调整不透明度、字号、显示区域、速度与显示类型")
                .popover(isPresented: $showDanmakuSettings, arrowEdge: .bottom) {
                    DanmakuSettingsCard()
                        // iPhone 上 popover 默认会自适应成 sheet / 全屏 cover，
                        // 一个设置小卡片被拉成整屏很突兀；显式要求紧凑宽度下仍按 popover 呈现。
                        .presentationCompactAdaptation(.popover)
                }

                #if os(macOS)
                Button {
                    toggleDetach()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: playbackWindow.isDetached ? "pin" : "pin.slash")
                        Text(playbackWindow.isDetached ? "吸附回播放页" : "分离窗口")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(playbackWindow.isDetached ? "把画面收回播放页" : "把画面分离为独立窗口")
                #endif

                Spacer(minLength: 0)

                if !player.qualities.isEmpty {
                    Button {
                        showQualityMenu = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "gear")
                            Text(player.currentQualityName ?? "清晰度")
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showQualityMenu, arrowEdge: .bottom) {
                        qualityActionCard
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
        }
    }

    private func infoRow(_ view: VideoDetailData.VideoView) -> some View {
        // iPhone 的宽度放不下「UP主 + 关注 + 发布时间 + 三项统计」，
        // 紧凑宽度下拆成两行：上排 UP主 与关注，下排发布时间与统计。
        // macOS 的 horizontalSizeClass 是 nil，布局与改造前一致。
        Group {
            if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ownerSection(view)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 14) {
                        publishTimeTag(view.pubdate)
                        statsSection(view)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: 14) {
                    ownerSection(view)
                    Spacer()
                    publishTimeTag(view.pubdate)
                    statsSection(view)
                }
            }
        }
    }

    /// UP 主头像 + 昵称 + 关注按钮
    @ViewBuilder
    private func ownerSection(_ view: VideoDetailData.VideoView) -> some View {
        NavigationLink(value: UpRoute(mid: view.owner.mid)) {
            HStack(spacing: 8) {
                RemoteImage(url: Formatters.https(view.owner.face ?? ""), variant: .avatar)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                Text(view.owner.name)
                    .font(.callout.weight(.medium))
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            player.stop()
            danmaku.reset()
        })
        if !session.loggedIn || !relationLoaded {
            EmptyView()
        } else if isFollowing {
            Text("已关注").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        } else {
            Button("+关注") { Task { await follow(mid: view.owner.mid) } }
                .buttonStyle(.borderedProminent).tint(.pink).controlSize(.small)
        }
    }

    /// 播放量 / 弹幕数 / 点赞数
    @ViewBuilder
    private func statsSection(_ view: VideoDetailData.VideoView) -> some View {
        stat(view.stat.view, "play.fill")
        stat(view.stat.danmaku, "text.bubble.fill")
        stat(view.stat.like, "hand.thumbsup.fill")
    }

    /// 发布时间标签：与播放量等并排，悬停（iOS 长按）可看完整日期。
    ///
    /// 相对时间用现成的 `Formatters.timeAgo`：一个月内是「N 天前」，
    /// 更早自动退回 `yyyy-MM-dd`，这正好是 B 站自己那套显示规则。
    @ViewBuilder
    private func publishTimeTag(_ timestamp: Int) -> some View {
        if timestamp > 0 {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(Formatters.timeAgo(timestamp))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(Color.primary.opacity(0.07))
            }
            .help("发布于 \(Self.absoluteDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp))))")
        }
    }

    /// 标签悬停提示里的完整时间。
    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - 点赞 / 投币 / 收藏 / 分享

    private func actionBar(_ view: VideoDetailData.VideoView) -> some View {
        // 动作栏又加了一项（下载），iPhone 的宽度放不下原来的 28pt 间距，
        // 紧凑宽度下收窄；macOS 的 horizontalSizeClass 是 nil，间距维持原样。
        HStack(spacing: horizontalSizeClass == .compact ? 14 : 28) {
            VStack(spacing: 3) {
                Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                Text(Formatters.count(likeCount))
                    .font(.caption2)
            }
            .foregroundStyle(liked ? Color.pink : Color.primary)
            .contentShape(Rectangle())
            // 单击点赞/取消赞；长按 0.6s 一键三连（长按识别后松手不会再触发单击）
            .onTapGesture {
                Task { await toggleLike() }
            }
            .onLongPressGesture(
                minimumDuration: 0.6,
                perform: {
                    Task { await triple() }
                    pulseCharged()
                },
                onPressingChanged: { pressing in
                    if pressing {
                        beginLikeCharge()
                    } else {
                        withAnimation(.easeOut(duration: 0.18)) {
                            endLikeCharge()
                        }
                    }
                }
            )
            .onHover { hovering in
                AppPlatform.setPointingHandCursor(hovering)
            }
            .hoverScale(scale: 1.06)
            .help("点赞 · 长按一键三连")
            .overlay(alignment: .top) {
                if likePressActive {
                    likeChargeHUD
                        .offset(y: -46)
                        .allowsHitTesting(false)
                }
            }

            Button {
                guard !coined else { return }
                showCoinMenu = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: coined ? "dollarsign.circle.fill" : "dollarsign.circle")
                    Text(Formatters.count(coinCount))
                        .font(.caption2)
                }
                .foregroundStyle(coined ? Color.orange : Color.primary)
                // 手机上把整块 44pt 的行高都纳入点击范围，避免点空白处没反应
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCoinMenu, arrowEdge: .bottom) {
                coinActionCard
                    .presentationCompactAdaptation(.popover)
            }
            .hoverScale(scale: 1.06)

            Button {
                Task { await toggleFavorite() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: faved ? "bookmark.fill" : "bookmark")
                    Text(Formatters.count(favCount))
                        .font(.caption2)
                }
                .foregroundStyle(faved ? Color.blue : Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverScale(scale: 1.06)

            Button {
                showShareMenu = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.right")
                    Text("分享")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showShareMenu, arrowEdge: .bottom) {
                shareActionCard
                    .presentationCompactAdaptation(.popover)
            }
            .hoverScale(scale: 1.06)

            Button { Task { await addToWatchLater() } } label: {
                VStack(spacing: 3) {
                    Image(systemName: watchLaterAdded ? "clock.fill" : "clock")
                    Text("稍后再看").font(.caption2)
                }
                .foregroundStyle(watchLaterAdded ? .pink : .primary)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).hoverScale(scale: 1.06)

            // 下载入口：跟随当前选中的分P
            DownloadActionItem(request: downloadRequest(for: view))

            Spacer()
        }
        .font(.title3)
        // 动作栏整体保证 44pt 高：HIG 的最小可点尺寸，手机上点赞/投币/收藏
        // 原先的热区只有 ~36pt 且相邻仅隔 14pt，很容易点到隔壁
        .frame(minHeight: 44)
        .padding(.vertical, 4)
    }

    // MARK: - 画质 / 投币 / 分享 悬浮小卡片

    /// 点击清晰度按钮弹出的液态玻璃小卡片（与投币、分享同一套弹层样式）。
    private var qualityActionCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(player.qualities.enumerated()), id: \.element.id) { index, quality in
                if index > 0 {
                    Divider().padding(.horizontal, 10)
                }
                MenuActionRow(icon: quality.id == player.currentQualityId ? "checkmark.circle.fill" : "circle",
                              title: quality.name) {
                    showQualityMenu = false
                    Task { await player.selectQuality(quality) }
                }
            }
        }
        .padding(6)
        .frame(width: 190)
    }


    /// 点击投币按钮弹出的液态玻璃小卡片（与左下角账户卡片同一套弹层样式）。
    private var coinActionCard: some View {
        VStack(spacing: 0) {
            MenuActionRow(icon: "dollarsign.circle", title: "投 1 枚硬币") {
                showCoinMenu = false
                Task { await coin(multiply: 1) }
            }
            Divider().padding(.horizontal, 10)
            MenuActionRow(icon: "dollarsign.circle.fill", title: "投 2 枚硬币") {
                showCoinMenu = false
                Task { await coin(multiply: 2) }
            }
        }
        .padding(6)
        .frame(width: 190)
    }

    /// 点击分享按钮弹出的液态玻璃小卡片。
    private var shareActionCard: some View {
        VStack(spacing: 0) {
            // iPhone 用户的预期是系统分享面板（微信/AirDrop/…），而不是只有复制链接。
            // `ShareLink` 在 macOS 上同样表现为系统分享，两端都合适。
            if let url = shareURL {
                ShareLink(item: url) {
                    Label("分享…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.horizontal, 10)
            }
            MenuActionRow(icon: "doc.on.doc", title: "复制链接") {
                showShareMenu = false
                Task { await copyLink() }
            }
            Divider().padding(.horizontal, 10)
            MenuActionRow(icon: "safari", title: "在浏览器打开") {
                showShareMenu = false
                openInBrowser()
            }
        }
        .padding(6)
        .frame(width: 190)
    }

    private func toggleLike() async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().like(aid: view.aid, bvid: view.bvid, liked: !liked)
            liked.toggle()
            likeCount += liked ? 1 : -1
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// 一键三连：点赞 + 投币 1 枚 + 收藏到默认收藏夹。
    private func triple() async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().triple(aid: view.aid, bvid: view.bvid)
            if !liked { liked = true; likeCount += 1 }
            if !coined { coined = true; coinCount += 1 }
            if !faved { faved = true; favCount += 1 }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - 长按蓄力反馈

    /// 按下点赞按钮：启动 0.6s 蓄力进度计时，驱动三枚图标逐一亮起。
    private func beginLikeCharge() {
        likeChargeTask?.cancel()
        likePressActive = true
        likePressProgress = 0
        likeChargedPulse = false
        likeChargeTask = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let progress = min(Date().timeIntervalSince(start) / 0.6, 1)
                likePressProgress = progress
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// 松开（或长按被打断）：停止蓄力并隐藏提示。
    private func endLikeCharge() {
        likeChargeTask?.cancel()
        likeChargeTask = nil
        likePressActive = false
        likePressProgress = 0
        likeChargedPulse = false
    }

    /// 蓄满触发三连时的脉冲：胶囊放大一下再回落。
    private func pulseCharged() {
        guard likePressActive else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) {
            likeChargedPulse = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                likeChargedPulse = false
            }
        }
    }

    /// 长按中的蓄力提示：赞/币/收藏随进度逐一亮起，蓄满后整颗胶囊脉冲。
    private var likeChargeHUD: some View {
        HStack(spacing: 6) {
            chargeIcon("hand.thumbsup.fill", .pink, order: 0)
            chargeIcon("dollarsign.circle.fill", .orange, order: 1)
            chargeIcon("bookmark.fill", .blue, order: 2)
            Text("长按三连")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .scaleEffect(likeChargedPulse ? 1.15 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: likeChargedPulse)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    /// 单个蓄力图标：进度超过 (order+1)/3 时点亮并弹入。
    private func chargeIcon(_ name: String, _ color: Color, order: Int) -> some View {
        let threshold = Double(order + 1) / 3
        let lit = likePressProgress >= threshold
        return Image(systemName: name)
            .foregroundStyle(color.opacity(lit ? 1 : 0.35))
            .scaleEffect(lit ? 1 : 0.6)
            .opacity(likePressProgress > 0 ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: lit)
            .animation(.easeOut(duration: 0.15), value: likePressProgress > 0)
    }

    private func coin(multiply: Int) async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().coin(aid: view.aid, bvid: view.bvid, multiply: multiply)
            coined = true
            coinCount += multiply
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func toggleFavorite() async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        if faved {
            do {
                let folders = favoriteFolders.isEmpty ? try await UserActionService().favoriteFolders() : favoriteFolders
                guard let folder = folders.first else { throw APIError.biz(code: -1, message: "没有可用收藏夹") }
                try await LibraryService().removeFavorite(aid: view.aid, folderId: folder.id)
                faved = false
                favCount = max(0, favCount - 1)
            } catch { actionError = error.localizedDescription }
            return
        }
        do {
            favoriteFolders = try await UserActionService().favoriteFolders()
            let behavior = FavoriteBehavior(rawValue: UserDefaults.standard.string(forKey: "favoriteBehavior") ?? "") ?? .defaultFolder
            if behavior == .ask { showFavoritePicker = true }
            else if let first = favoriteFolders.first { await saveFavorite(folderId: first.id) }
        } catch { actionError = error.localizedDescription }
    }

    private func saveFavorite(folderId: Int) async {
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().favorite(aid: view.aid, folderId: folderId)
            faved = true; favCount += 1
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func addToWatchLater() async {
        guard requireLogin(), let view = detail?.view else { return }
        do {
            if watchLaterAdded {
                try await LibraryService().removeFromWatchLater(aid: view.aid)
                watchLaterAdded = false
            } else {
                try await LibraryService().addToWatchLater(aid: view.aid, bvid: view.bvid)
                watchLaterAdded = true
            }
        }
        catch { actionError = error.localizedDescription }
    }

    private func requireLogin() -> Bool {
        guard session.loggedIn else {
            showLogin = true
            return false
        }
        return true
    }

    private func copyLink() async {
        guard let bvid = detail?.view.bvid else { return }
        let link = detail?.view.shortLinkV2 ?? "https://www.bilibili.com/video/\(bvid)"
        AppPlatform.copyToPasteboard(link)
        shareMessage = "已将视频链接复制到剪贴板"
    }

    private func follow(mid: Int) async {
        guard requireLogin() else { return }
        do { try await RelationService().modify(fid: mid, follow: true); isFollowing = true }
        catch { actionError = error.localizedDescription }
    }

    private func openInBrowser() {
        guard let url = shareURL else { return }
        AppPlatform.openExternally(url)
    }

    /// 本视频的网页地址（分享与「在浏览器打开」共用）。
    private var shareURL: URL? {
        guard let bvid = detail?.view.bvid else { return nil }
        return URL(string: "https://www.bilibili.com/video/\(bvid)")
    }

    private func stat(_ value: Int, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(Formatters.count(value))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var commentHeader: some View {
        HStack {
            Text("评论").font(.headline)
            if let commentTotal, commentTotal > 0 {
                Text(Formatters.count(commentTotal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func commentSection(_ view: VideoDetailData.VideoView) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(comments) { comment in
                CommentCardView(comment: comment, aid: view.aid)
                Divider().opacity(0.4)
            }

            if isLoadingComments {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if let commentError, comments.isEmpty {
                Text(commentError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if comments.isEmpty {
                Text("暂无评论")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if hasMoreComments {
                Button {
                    Task { await loadMoreComments(aid: view.aid) }
                } label: {
                    Text("加载更多评论")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadComments(aid: Int) async {
        guard !isLoadingComments else { return }
        isLoadingComments = true
        commentError = nil
        do {
            let data = try await CommentService().videoComments(aid: aid, page: 1)
            comments = data.replies
            commentPage = 1
            hasMoreComments = !data.replies.isEmpty
            commentTotal = data.page?.acount ?? data.page?.count
        } catch {
            commentError = error.localizedDescription
        }
        isLoadingComments = false
    }

    private func loadMoreComments(aid: Int) async {
        guard !isLoadingComments, hasMoreComments else { return }
        isLoadingComments = true
        do {
            let data = try await CommentService().videoComments(aid: aid, page: commentPage + 1)
            let seen = Set(comments.map(\.id))
            comments.append(contentsOf: data.replies.filter { !seen.contains($0.id) })
            commentPage += 1
            hasMoreComments = !data.replies.isEmpty
        } catch {
            commentError = error.localizedDescription
        }
        isLoadingComments = false
    }

    /// 分离/吸附：分离后成为普通可移动缩放窗口，再点一次把画面收回页面内。
    private func toggleDetach() {
        guard player.state == .ready, player.player != nil else { return }
        if playbackWindow.isDetached {
            closePlaybackWindow()
        } else if !playbackWindow.isOpen {
            presentPlaybackWindow()
        }
    }

    /// 创建分离窗口并把同一个播放组件搬进去（窗口正好盖住页面里的画面位置）。
    private func presentPlaybackWindow() {
        bindSystemPlayer()
        var frame = playerArea.frame
        if frame.width < 40 || frame.height < 40 {
            #if os(macOS)
            frame = AppDelegate.mainWindow()?.frame
                ?? CGRect(x: 240, y: 240, width: 640, height: 360)
            #else
            frame = CGRect(x: 240, y: 240, width: 640, height: 360)
            #endif
        }
        let controller = playbackWindow
        controller.onCloseRequested = { [weak controller] in
            controller?.onCloseRequested = nil
            controller?.close()
        }
        controller.present(frame: frame,
                           title: "视频播放",
                           content: AnyView(surface()))
    }

    /// 关闭播放窗口：画面自动回到页面内继续播放。
    private func closePlaybackWindow() {
        playbackWindow.onCloseRequested = nil
        playbackWindow.close()
    }

    /// 把页面上的三个开关挂到顶部“播放”菜单：菜单点与页面点完全等价。
    private func bindPlaybackMenu() {
        PlaybackMenuState.shared.bind(
            danmakuEnabled: danmakuEnabled,
            isDetached: playbackWindow.isDetached,
            toggleDanmaku: { danmakuEnabled.toggle() },
            toggleDetach: { toggleDetach() }
        )
    }

    /// 播放组件：同一份视图既放在页内，也放进按需窗口；画面区不带任何悬浮按钮。
    private func surface() -> VideoPlayerSurface {
        VideoPlayerSurface(playerController: player, engine: danmaku, danmakuSettings: danmakuSettings)
    }

    /// 当前弹幕设置（与设置页共用同一批 `@AppStorage` 键，改完立刻推给渲染层）
    private var danmakuSettings: DanmakuSettings {
        DanmakuSettings(opacity: danmakuOpacity,
                        fontScale: danmakuFontScale,
                        fullscreenScale: danmakuFullscreenScale,
                        displayArea: DanmakuDisplayArea(rawValue: danmakuDisplayArea) ?? .full,
                        showsFloating: danmakuShowsFloating,
                        showsTop: danmakuShowsTop,
                        showsBottom: danmakuShowsBottom,
                        allowsOverlap: danmakuAllowsOverlap)
    }

    /// 播放窗口建起时把当前视频注册为系统“正在播放”，媒体键（F7/F8/F9）
    /// 与控制中心进度条才会路由到这个播放器。
    private func bindSystemPlayer() {
        guard let view = detail?.view else { return }
        SystemMediaCenter.shared.bind(
            player: player,
            title: view.title,
            artist: view.owner.name,
            artworkURL: Formatters.https(view.pic)
        )
    }

    private func loadDanmaku(cid: Int) async {
        do {
            let items = try await DanmakuService.fetch(cid: cid)
            danmaku.load(items)
        } catch {
            // 弹幕拉取失败不影响播放，静默忽略
        }
    }

    private func retryPlayer() async {
        guard let view = detail?.view else { return }
        await player.retry(aid: view.aid, bvid: view.bvid, cid: view.cid)
    }

    private func loadTags(aid: Int, bvid: String) async {
        do {
            tags = try await VideoService().tags(aid: aid, bvid: bvid)
        } catch {
            // 标签拉取失败不影响视频页，静默忽略
        }
    }

    /// 视频 TAG 实色小卡片；点击用标签内容进入搜索页。
    private func tagButton(_ tag: VideoTagData) -> some View {
        Button {
            router.path.append(SearchRoute(query: tag.tagName))
        } label: {
            Text(tag.tagName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cardSolidBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
    }
}

/// 悬浮小卡片中的一行操作，带系统菜单同款悬停高亮。
/// 下载卡片复用同一种行样式，所以这里是 internal 而不是 private。
struct MenuActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
