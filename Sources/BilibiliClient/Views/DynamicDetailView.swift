import SwiftUI

/// 动态详情页：展示动态文字内容、图片、引用内容与评论区。
@MainActor
struct DynamicDetailView: View {
    let id: String

    @State private var item: DynamicItem?
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var comments: [CommentItem] = []
    @State private var commentPage = 1
    @State private var isLoadingComments = false
    @State private var hasMoreComments = true

    @State private var preview: PreviewTarget?

    private let service = DynamicService()
    private let commentService = CommentService()

    var body: some View {
        Group {
            if isLoading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                LoadErrorView(message: errorMessage) {
                    await load()
                }
            } else if let item {
                content(item)
            }
        }
        .navigationTitle("动态详情")
        .task {
            guard item == nil else { return }
            await load()
        }
        .sheet(item: $preview) { target in
            DynamicImagePreview(url: target.url)
        }
    }

    private func content(_ item: DynamicItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                authorHeader(item)
                if let text = mainText(item), !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                imageArea(item)

                if let archive = item.modules.moduleDynamic?.major?.archive {
                    DynamicArchiveRow(archive: archive)
                }

                if let orig = item.orig {
                    DynamicQuoteView(origin: orig, opensOrigin: true)
                }

                statBar(item)
                Divider()
                commentSection(item)
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: - 内容

    private func authorHeader(_ item: DynamicItem) -> some View {
        HStack(spacing: 12) {
            if let mid = item.modules.moduleAuthor?.mid {
                NavigationLink(value: UpRoute(mid: mid)) {
                    RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
                    .frame(width: 46, height: 46)
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.modules.moduleAuthor?.name ?? "未知用户")
                    .font(.headline)
                if let time = item.modules.moduleAuthor?.pubTime {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func mainText(_ item: DynamicItem) -> String? {
        if let text = item.modules.moduleDynamic?.desc?.text, !text.isEmpty {
            return text
        }
        if item.modules.moduleDynamic?.major?.type == "MAJOR_TYPE_OPUS" {
            return item.modules.moduleDynamic?.major?.opus?.summary?.text
        }
        return nil
    }

    private func imageArea(_ item: DynamicItem) -> some View {
        let urls = imageURLs(of: item)
        if urls.isEmpty {
            return AnyView(EmptyView())
        }
        return AnyView(detailImageGrid(urls))
    }

    private func imageURLs(of item: DynamicItem) -> [URL] {
        let major = item.modules.moduleDynamic?.major
        if let draw = major?.draw {
            return (draw.items ?? []).compactMap { Formatters.https($0.src ?? "") }
        }
        if let opus = major?.opus {
            return (opus.pics ?? []).compactMap { Formatters.https($0.src ?? "") }
        }
        return []
    }

    private func detailImageGrid(_ urls: [URL]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 10)],
                  spacing: 10) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                Button {
                    preview = PreviewTarget(url: url)
                } label: {
                    RemoteImage(url: url)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("查看大图")
            }
        }
    }

    private func statBar(_ item: DynamicItem) -> some View {
        HStack(spacing: 24) {
            Label(Formatters.count(stat(item)?.like?.count ?? 0), systemImage: "heart")
            Label(Formatters.count(stat(item)?.comment?.count ?? 0), systemImage: "bubble.right")
            Label(Formatters.count(stat(item)?.forward?.count ?? 0), systemImage: "arrowshape.turn.up.right")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func stat(_ item: DynamicItem) -> DynamicItem.ModuleStat? {
        item.modules.moduleStat
    }

    // MARK: - 评论区

    @ViewBuilder
    private func commentSection(_ item: DynamicItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("评论 \(commentCountText(item))")
                .font(.title3.weight(.semibold))

            if isLoadingComments && comments.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if comments.isEmpty {
                Text("还没有评论")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(comments) { comment in
                    DynamicCommentRowView(comment: comment)
                    if comment.id != comments.last?.id {
                        Divider()
                    }
                }

                if hasMoreComments {
                    Button {
                        Task { await loadMoreComments() }
                    } label: {
                        if isLoadingComments {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("加载更多评论")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func commentCountText(_ item: DynamicItem) -> String {
        let count = stat(item)?.comment?.count ?? 0
        return count > 0 ? Formatters.count(count) : ""
    }

    /// 评论定位：优先用接口下发的 basic 信息；缺失时按动态类型兜底。
    private var commentTarget: (type: Int, oid: String)? {
        guard let item else { return nil }
        if let basic = item.basic,
           let type = basic.commentType, type > 0,
           let oid = basic.commentIdStr, !oid.isEmpty {
            return (type, oid)
        }
        let major = item.modules.moduleDynamic?.major
        if let drawID = major?.draw?.id {
            return (11, "\(drawID)")
        }
        return (17, item.idStr)
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let data = try await service.detail(id: id)
            item = data.item
            if item == nil {
                errorMessage = "动态不存在或已删除"
            }
            commentPage = 1
            comments = []
            hasMoreComments = true
            await loadFirstComments()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadFirstComments() async {
        guard commentTarget != nil else {
            hasMoreComments = false
            return
        }
        isLoadingComments = true
        defer { isLoadingComments = false }
        do {
            if let target = commentTarget {
                let data = try await commentService.comments(type: target.type, oid: target.oid, page: 1)
                comments = data.replies
                hasMoreComments = data.replies.count >= 20
                commentPage = 2
            }
        } catch {
            hasMoreComments = false
        }
    }

    private func loadMoreComments() async {
        guard let target = commentTarget, !isLoadingComments else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }
        do {
            let data = try await commentService.comments(type: target.type,
                                                         oid: target.oid,
                                                         page: commentPage,
                                                         pageSize: 20)
            let seen = Set(comments.map(\.id))
            let fresh = data.replies.filter { !seen.contains($0.id) }
            comments.append(contentsOf: fresh)
            commentPage += 1
            hasMoreComments = fresh.count >= 20
        } catch {
            hasMoreComments = false
        }
    }
}

/// 动态评论行（仅展示）。
struct DynamicCommentRowView: View {
    let comment: CommentItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let mid = Int(comment.member?.mid ?? "") {
                    NavigationLink(value: UpRoute(mid: mid)) {
                        RemoteImage(url: Formatters.https(comment.member?.avatar ?? ""))
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    RemoteImage(url: Formatters.https(comment.member?.avatar ?? ""))
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.member?.uname ?? "匿名用户")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(Formatters.timeAgo(comment.ctime ?? 0))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                Text(comment.content?.message ?? "")
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    Label(Formatters.count(comment.like ?? 0), systemImage: "hand.thumbsup")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 大图预览（点击任意位置或 Esc 关闭）。
struct DynamicImagePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteImage(url: url)
                .scaledToFit()
                .frame(maxWidth: 1000, maxHeight: 800)
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(14)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .frame(minWidth: 300, minHeight: 200)
    }
}

/// 预览目标包装（URL 需符合 Identifiable 才能用于 sheet(item:)）。
private struct PreviewTarget: Identifiable {
    let id = UUID()
    let url: URL
}
