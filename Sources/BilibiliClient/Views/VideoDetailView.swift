import SwiftUI

struct VideoDetailView: View {
    let bvid: String

    @EnvironmentObject private var session: SessionStore
    @StateObject private var player = PlayerController()
    @StateObject private var danmaku = DanmakuEngine()
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @State private var liked = false
    @State private var coined = false
    @State private var faved = false
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
        .onDisappear {
            player.stop()
            danmaku.reset()
        }
        .sheet(isPresented: $showLogin) { LoginView() }
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
                let (likedResult, coinedResult) = await (likedTask, coinedTask)
                liked = likedResult ?? false
                coined = (coinedResult ?? 0) > 0
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
                    PlayerView(player: player)
                        .overlay {
                            DanmakuOverlayView(engine: danmaku,
                                               player: player,
                                               enabled: danmakuEnabled)
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
                .foregroundStyle(liked ? Color.pink : Color.secondary)
            }
            .buttonStyle(.plain)

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

            Button {
                Task { await toggleFavorite() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: faved ? "bookmark.fill" : "bookmark")
                    Text(Formatters.count(favCount))
                        .font(.caption2)
                }
                .foregroundStyle(faved ? Color.blue : Color.secondary)
            }
            .buttonStyle(.plain)

            Menu {
                Button("复制链接") {
                    copyLink()
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
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .font(.title3)
        .padding(.vertical, 4)
    }

    private func toggleLike() async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().like(aid: view.aid, liked: !liked)
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

    private func toggleFavorite() async {
        guard requireLogin() else { return }
        guard let view = detail?.view else { return }
        do {
            try await UserActionService().favorite(aid: view.aid, faved: !faved)
            faved.toggle()
            favCount += faved ? 1 : -1
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func requireLogin() -> Bool {
        guard session.loggedIn else {
            showLogin = true
            return false
        }
        return true
    }

    private func copyLink() {
        guard let bvid = detail?.view.bvid else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("https://www.bilibili.com/video/\(bvid)", forType: .string)
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
