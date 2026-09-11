import AppKit
import SwiftUI

struct VideoDetailView: View {
    let bvid: String

    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var router: AppRouter
    @StateObject private var player = PlayerController()
    @State private var danmaku = DanmakuEngine()
    /// 按需创建的播放窗口：默认不存在，画面就播在页面里
    @StateObject private var playbackWindow = PlayerWindowController()
    /// 页面里播放区域的屏幕位置：创建播放窗口时用它把窗口精确覆盖到画面处
    @State private var playerArea = PlayerAreaFrameBox()
    /// 当前选中的分P cid（nil = 播放详情默认分P，即第一个分P）
    @State private var selectedPageCid: Int?
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @State private var liked = false
    @State private var coined = false
    @State private var faved = false
    @State private var watchLaterAdded = false
    @State private var favoriteFolders: [FavFolder] = []
    @State private var showFavoritePicker = false
    @State private var shareMessage: String?
    @State private var showCoinMenu = false
    @State private var showShareMenu = false
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
        }
        .onChange(of: router.path.count) { _, newCount in
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
            closePlaybackWindow()
            player.stop()
            danmaku.reset()
        }
        // 窗口（分离窗口绿色按钮放大/缩回）状态变化后同步窗口内按钮形态
        .onChange(of: playbackWindow.isFullscreen) { _, _ in
            syncWindowContent()
        }
        .onChange(of: playbackWindow.isDetached) { _, _ in
            syncWindowContent()
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

    private func content(_ view: VideoDetailData.VideoView) -> some View {
        VStack(spacing: 0) {
            // 视频固定在页面顶部：滚动时保持原位完整可见，下方内容独立滑动
            playerSection
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 24)

                // 固定空隙：不属于滚动内容，滚动时始终保留在视频与内容之间
                Color.clear
                    .frame(height: 18)

                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !player.qualities.isEmpty {
                        HStack {
                            Spacer()
                            Menu {
                                ForEach(player.qualities) { quality in
                                    Button {
                                        Task { await player.selectQuality(quality) }
                                    } label: {
                                        if quality.id == player.currentQualityId {
                                            Label(quality.name, systemImage: "checkmark")
                                        } else {
                                            Text(quality.name)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "gear")
                                    Text(player.currentQualityName ?? "清晰度")
                                    Image(systemName: "chevron.up.chevron.down")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }

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
                    Text(view.desc.isEmpty ? "该视频没有简介" : view.desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)

                    if !tags.isEmpty {
                        FlowLayout(spacing: 8) {
                            ForEach(tags) { tag in
                                tagButton(tag)
                            }
                        }
                        .padding(.top, 14)
                    }

                    Divider()

                    commentHeader
                    commentSection(view)

                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

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
                    .fill(isCurrent ? Color.pink.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
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
                    surface(isFullscreen: false, isDetached: false)
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
        .background(
            PlayerAreaReporter(onFrame: { frame in
                playerArea.frame = frame
            })
        )
    }

    /// 画面当前是否正在页面内播放（决定页面显示播放组件还是空位）。
    private var isPlayingInline: Bool {
        player.state == .ready && player.player != nil && !playbackWindow.isOpen
    }

    private func infoRow(_ view: VideoDetailData.VideoView) -> some View {
        HStack(spacing: 14) {
            NavigationLink(value: UpRoute(mid: view.owner.mid)) {
                HStack(spacing: 8) {
                    RemoteImage(url: Formatters.https(view.owner.face ?? ""))
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
            Spacer()
            stat(view.stat.view, "play.fill")
            stat(view.stat.danmaku, "text.bubble.fill")
            stat(view.stat.like, "hand.thumbsup.fill")
        }
    }

    // MARK: - 点赞 / 投币 / 收藏 / 分享

    private func actionBar(_ view: VideoDetailData.VideoView) -> some View {
        HStack(spacing: 28) {
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
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
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
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCoinMenu, arrowEdge: .bottom) {
                coinActionCard
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
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showShareMenu, arrowEdge: .bottom) {
                shareActionCard
            }
            .hoverScale(scale: 1.06)

            Button { Task { await addToWatchLater() } } label: {
                VStack(spacing: 3) {
                    Image(systemName: watchLaterAdded ? "clock.fill" : "clock")
                    Text("稍后再看").font(.caption2)
                }.foregroundStyle(watchLaterAdded ? .pink : .primary)
            }.buttonStyle(.plain).hoverScale(scale: 1.06)

            Spacer()
        }
        .font(.title3)
        .padding(.vertical, 4)
    }

    // MARK: - 投币 / 分享 悬浮小卡片

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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        shareMessage = "已将视频链接复制到剪贴板"
    }

    private func follow(mid: Int) async {
        guard requireLogin() else { return }
        do { try await RelationService().modify(fid: mid, follow: true); isFollowing = true }
        catch { actionError = error.localizedDescription }
    }

    private func openInBrowser() {
        guard let bvid = detail?.view.bvid,
              let url = URL(string: "https://www.bilibili.com/video/\(bvid)") else { return }
        NSWorkspace.shared.open(url)
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
            frame = AppDelegate.mainWindow()?.frame
                ?? CGRect(x: 240, y: 240, width: 640, height: 360)
        }
        let controller = playbackWindow
        controller.onCloseRequested = { [weak controller] in
            controller?.onCloseRequested = nil
            controller?.close()
        }
        controller.present(frame: frame,
                           title: "视频播放",
                           content: AnyView(surface(isFullscreen: false, isDetached: false)))
    }

    /// 关闭播放窗口：画面自动回到页面内继续播放。
    private func closePlaybackWindow() {
        playbackWindow.onCloseRequested = nil
        playbackWindow.close()
    }

    /// 播放组件：同一份视图既放在页内，也放进按需窗口。
    /// 播放与全屏（含全屏动画）都由 AVKit 负责，这里只保留弹幕开关与分离按钮。
    private func surface(isFullscreen: Bool, isDetached: Bool) -> VideoPlayerSurface {
        VideoPlayerSurface(playerController: player,
                           engine: danmaku,
                           isFullscreen: isFullscreen,
                           isDetached: isDetached,
                           onToggleDetach: toggleDetach)
    }

    /// 窗口内全屏/分离状态变化后重建内容，让控制条与按钮形态同步。
    private func syncWindowContent() {
        guard playbackWindow.isOpen else { return }
        playbackWindow.updateContent(AnyView(surface(isFullscreen: playbackWindow.isFullscreen,
                                                     isDetached: playbackWindow.isDetached)))
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
                        .fill(Color(nsColor: .controlBackgroundColor))
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
private struct MenuActionRow: View {
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
