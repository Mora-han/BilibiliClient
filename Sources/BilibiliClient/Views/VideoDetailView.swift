import SwiftUI

struct VideoDetailView: View {
    let bvid: String

    @StateObject private var player = PlayerController()
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
        .onDisappear { player.stop() }
    }

    private func load() async {
        if let data = detail {
            // 返回后再进入：恢复已停止的播放器
            if player.player == nil {
                await player.load(bvid: data.view.bvid, cid: data.view.cid)
            }
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await VideoService().detail(bvid: bvid)
            detail = data
            isLoading = false
            async let commentsTask: Void = loadComments(aid: data.view.aid)
            async let playerTask: Void = player.load(bvid: data.view.bvid, cid: data.view.cid)
            _ = await (commentsTask, playerTask)
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
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func infoRow(_ view: VideoDetailData.VideoView) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                RemoteImage(url: Formatters.https(view.owner.face ?? ""))
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                Text(view.owner.name)
                    .font(.callout.weight(.medium))
            }
            Spacer()
            stat(view.stat.view, "play.fill")
            stat(view.stat.danmaku, "text.bubble.fill")
            stat(view.stat.like, "hand.thumbsup.fill")
        }
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

    private func retryPlayer() async {
        guard let view = detail?.view else { return }
        await player.retry(bvid: view.bvid, cid: view.cid)
    }
}
