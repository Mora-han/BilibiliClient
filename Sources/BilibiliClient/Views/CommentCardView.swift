import SwiftUI

struct CommentCardView: View {
    let comment: CommentItem
    let aid: Int

    @State private var isExpanded = false
    @State private var replies: [CommentItem] = []
    @State private var replyPage = 0
    @State private var isLoadingReplies = false
    @State private var hasMoreReplies = true
    @State private var replyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                RemoteImage(url: Formatters.https(comment.member?.avatar ?? ""))
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(comment.member?.uname ?? "匿名用户")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if let level = comment.member?.levelInfo?.currentLevel {
                            Text("Lv.\(level)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if comment.upAction?.like == true {
                            Label("UP 赞了", systemImage: "hand.thumbsup.fill")
                                .font(.caption2)
                                .foregroundStyle(.pink)
                        }
                    }

                    Text(comment.content?.message ?? "")
                        .font(.callout)
                        .textSelection(.enabled)

                    HStack(spacing: 14) {
                        Text(Formatters.timeAgo(comment.ctime ?? 0))
                        Label(Formatters.count(comment.like ?? 0), systemImage: "hand.thumbsup")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let rcount = comment.rcount, rcount > 0 {
                Button {
                    toggleReplies()
                } label: {
                    Label(isExpanded ? "收起回复" : "\(rcount) 条回复",
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 42)
            }

            if isExpanded {
                replyList
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var replyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(replies) { reply in
                ReplyRowView(reply: reply)
            }

            if isLoadingReplies && replies.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else if let replyError, replies.isEmpty {
                Text(replyError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("点击重试") {
                    Task { await loadReplies() }
                }
                .font(.caption)
                .buttonStyle(.plain)
            } else if replies.isEmpty {
                Text("暂无回复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hasMoreReplies {
                Button {
                    Task { await loadReplies() }
                } label: {
                    if isLoadingReplies {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("加载更多回复")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 42)
        .padding(.top, 6)
    }

    private func toggleReplies() {
        isExpanded.toggle()
        guard isExpanded, replies.isEmpty else { return }
        // 先用接口返回的内嵌回复预览，立即展示；随后拉取完整列表
        replies = comment.replies ?? []
        replyPage = 0
        Task { await loadReplies() }
    }

    private func loadReplies() async {
        guard !isLoadingReplies else { return }
        isLoadingReplies = true
        replyError = nil
        do {
            let data = try await CommentService().videoCommentReplies(aid: aid,
                                                                      root: comment.rpid,
                                                                      page: replyPage + 1)
            let seen = Set(replies.map(\.id))
            replies.append(contentsOf: data.replies.filter { !seen.contains($0.id) })
            replyPage += 1
            hasMoreReplies = !data.replies.isEmpty
        } catch {
            replyError = error.localizedDescription
        }
        isLoadingReplies = false
    }
}

struct ReplyRowView: View {
    let reply: CommentItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RemoteImage(url: Formatters.https(reply.member?.avatar ?? ""))
                .frame(width: 24, height: 24)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reply.member?.uname ?? "匿名用户")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if reply.upAction?.like == true {
                        Label("UP 赞了", systemImage: "hand.thumbsup.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                    Spacer()
                }

                Text(reply.content?.message ?? "")
                    .font(.caption)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    Text(Formatters.timeAgo(reply.ctime ?? 0))
                    Label(Formatters.count(reply.like ?? 0), systemImage: "hand.thumbsup")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}
