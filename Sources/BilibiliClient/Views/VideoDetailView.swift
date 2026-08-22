import AppKit
import AVKit
import SwiftUI

struct VideoDetailView: View {
    let bvid: String

    @EnvironmentObject private var session: SessionStore
    @StateObject private var player = PlayerController()
    @StateObject private var danmaku = DanmakuEngine()
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @State private var fullscreenDanmaku = NativeFullscreenDanmaku()
    @State private var isFullscreen = false
    @State private var pendingFullscreenAttach = false
    @State private var fullscreenObserver: NSObjectProtocol?
    @State private var liked = false
    @State private var coined = false
    @State private var faved = false
    @State private var watchLaterAdded = false
    @State private var favoriteFolders: [FavFolder] = []
    @State private var showFavoritePicker = false
    @State private var shareMessage: String?
    @State private var isFollowing = false
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await load() }
                        }
                    }
                } else if let view = detail?.view {
                    content(view)
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle(detail?.view.title ?? "视频详情")
        .task { await load() }
        .onAppear {
            registerFullscreenObservers()
        }
        .onDisappear {
            if let fullscreenObserver {
                NotificationCenter.default.removeObserver(fullscreenObserver)
            }
            fullscreenObserver = nil
            pendingFullscreenAttach = false
            fullscreenDanmaku.detach()
            player.stop()
            danmaku.reset()
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
            // 返回后再进入：恢复已停止的播放器
            if player.player == nil {
                await player.load(aid: data.view.aid, bvid: data.view.bvid, cid: data.view.cid)
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
                async let relationTask = try? RelationService().relation(fid: data.view.owner.mid)
                let (likedResult, coinedResult, relationResult) = await (likedTask, coinedTask, relationTask)
                liked = likedResult ?? false
                coined = (coinedResult ?? 0) > 0
                isFollowing = relationResult?.isFollowing ?? false
            }
            async let commentsTask: Void = loadComments(aid: data.view.aid)
            async let playerTask: Void = player.load(aid: data.view.aid, bvid: data.view.bvid, cid: data.view.cid)
            _ = await (commentsTask, playerTask)
            await loadDanmaku(cid: data.view.cid)
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func content(_ view: VideoDetailData.VideoView) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            playerSection

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
                Label("共 \(pages.count) 个分P", systemImage: "list.number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("简介").font(.headline)
            Text(view.desc.isEmpty ? "该视频没有简介" : view.desc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)

            Divider()

            commentHeader
            commentSection(view)

            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private var playerSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.black)

            switch player.state {
            case .idle, .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载播放地址…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed:
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
                if let player = player.player {
                    PlayerView(player: player,
                               onWillEnterFullscreen: { _ in
                                   playerWillEnterFullscreen()
                               },
                               onEnterFullscreen: { playerView in
                                   playerDidEnterFullscreen(playerView)
                               },
                               onExitFullscreen: { _ in
                                   playerDidExitFullscreen()
                               })
                        .overlay {
                            DanmakuOverlayView(engine: danmaku,
                                               player: player,
                                               enabled: danmakuEnabled,
                                               suspended: isFullscreen)
                        }
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if player.state == .ready {
                DanmakuToggleButton(isOn: $danmakuEnabled)
                    .padding(10)
            }
        }
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
            if isFollowing {
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
            Button {
                Task { await toggleLike() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    Text(Formatters.count(likeCount))
                        .font(.caption2)
                }
                .foregroundStyle(liked ? Color.pink : Color.black)
            }
            .buttonStyle(.plain)
            .hoverScale(scale: 1.06)

            Menu {
                Button("投 1 枚硬币") {
                    Task { await coin(multiply: 1) }
                }
                Button("投 2 枚硬币") {
                    Task { await coin(multiply: 2) }
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: coined ? "dollarsign.circle.fill" : "dollarsign.circle")
                    Text(Formatters.count(coinCount))
                        .font(.caption2)
                }
                .foregroundStyle(coined ? Color.orange : Color.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(coined)
            .hoverScale(scale: 1.06)

            Button {
                Task { await beginFavorite() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: faved ? "bookmark.fill" : "bookmark")
                    Text(Formatters.count(favCount))
                        .font(.caption2)
                }
                .foregroundStyle(faved ? Color.blue : Color.black)
            }
            .buttonStyle(.plain)
            .hoverScale(scale: 1.06)

            Menu {
                Button("复制链接") {
                    Task { await copyLink() }
                }
                Button("在浏览器打开") {
                    openInBrowser()
                }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.right")
                    Text("分享")
                        .font(.caption2)
                }
                .foregroundStyle(.black)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button { Task { await addToWatchLater() } } label: {
                VStack(spacing: 3) {
                    Image(systemName: watchLaterAdded ? "clock.fill" : "clock")
                    Text("稍后再看").font(.caption2)
                }.foregroundStyle(watchLaterAdded ? .pink : .black)
            }.buttonStyle(.plain).hoverScale(scale: 1.06)

            Spacer()
        }
        .font(.title3)
        .padding(.vertical, 4)
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

    private func coin(multiply: Int) async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().coin(aid: view.aid, multiply: multiply)
            coined = true
            coinCount += multiply
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func beginFavorite() async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        if faved { return }
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
        do { try await LibraryService().addToWatchLater(aid: view.aid, bvid: view.bvid); watchLaterAdded = true }
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

    /// 系统全屏窗口即将开始动画：此时挂载弹幕层，让它随窗口一起放大/缩小。
    private func registerFullscreenObservers() {
        guard fullscreenObserver == nil else { return }
        fullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { [self] note in
            Task { @MainActor in
                guard pendingFullscreenAttach,
                      let window = note.object as? NSWindow,
                      let avPlayer = player.player else { return }
                pendingFullscreenAttach = false
                fullscreenDanmaku.attach(engine: danmaku, player: avPlayer, to: window)
            }
        }
    }

    /// AVPlayerView 即将进入全屏：标记等待挂载，并让内嵌弹幕层挂起。
    private func playerWillEnterFullscreen() {
        pendingFullscreenAttach = true
        isFullscreen = true
    }

    /// 兜底：若窗口通知未触发，进入完成后再挂载。
    private func playerDidEnterFullscreen(_ playerView: AVPlayerView) {
        pendingFullscreenAttach = false
        guard let avPlayer = playerView.player ?? player.player else { return }
        isFullscreen = true
        guard !fullscreenDanmaku.isAttached else { return }
        let window = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.fullScreen) }
            ?? playerView.window
        fullscreenDanmaku.attach(engine: danmaku, player: avPlayer, to: window)
    }

    /// 退出系统全屏：移除挂载的弹幕层，内嵌播放器恢复驱动。
    private func playerDidExitFullscreen() {
        pendingFullscreenAttach = false
        fullscreenDanmaku.detach()
        isFullscreen = false
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
}
