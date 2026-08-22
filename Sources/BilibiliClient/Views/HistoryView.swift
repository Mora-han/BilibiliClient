import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var items: [HistoryItem] = []
    @State private var cursor: HistoryCursor?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var showLogin = false

    private var usableItems: [HistoryItem] {
        items.filter { !($0.history?.bvid ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !session.loggedIn {
                loginPrompt
            } else {
                content
            }
        }
        .navigationTitle("历史记录")
        .sheet(isPresented: $showLogin) { LoginView() }
        .task { await loadIfNeeded() }
    }

    private var loginPrompt: some View {
        LoginRequiredView(title: "登录后查看历史",
                          systemImage: "clock.arrow.circlepath",
                          message: "需要登录哔哩哔哩账号才能同步观看历史",
                          showLogin: $showLogin)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading && items.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, items.isEmpty {
                    LoadErrorView(message: errorMessage) {
                        await load()
                    }
                } else if usableItems.isEmpty {
                    Text("暂无观看历史")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VideoFeedLayout(mode: displayMode) {
                        ForEach(usableItems) { item in
                            NavigationLink(value: item.history?.bvid ?? "") {
                                VideoCardView(
                                    bvid: item.history?.bvid ?? "",
                                    title: item.title ?? "未知标题",
                                    pic: item.cover ?? "",
                                    duration: item.duration ?? 0,
                                    ownerName: item.authorName ?? "未知UP主",
                                    viewCount: 0,
                                    badgeText: nil
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除历史记录", role: .destructive) {
                                    Task {
                                        guard let aid = item.history?.oid else { return }
                                        try? await LibraryService().removeHistory(aid: aid)
                                        items.removeAll { $0.id == item.id }
                                    }
                                }
                            }
                        }
                    } rowContent: {
                        ForEach(usableItems) { item in
                            NavigationLink(value: item.history?.bvid ?? "") {
                                row(item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删除历史记录", role: .destructive) {
                                    Task {
                                        guard let aid = item.history?.oid else { return }
                                        try? await LibraryService().removeHistory(aid: aid)
                                        items.removeAll { $0.id == item.id }
                                    }
                                }
                            }
                        }
                    }

                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                        await loadMore()
                    }
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .refreshable { await load() }
        .autoLoadMore { await loadMore() }
    }

    private func row(_ item: HistoryItem) -> some View {
        let duration = Double(item.duration ?? 0)
        let progress = duration > 0 ? Double(item.progress ?? 0) / duration : 0
        let done = (item.progress ?? 0) >= Int(duration) && duration > 0

        return MediaListRow(
            coverURL: item.cover ?? "",
            title: item.title ?? "未知标题",
            line2: item.authorName ?? "未知UP主",
            line3: "\(item.badge ?? (done ? "已看完" : "看到 \(Formatters.duration(item.progress ?? 0))")) · \(Formatters.timeAgo(item.viewAt ?? 0))",
            durationText: Formatters.duration(item.duration ?? 0),
            progress: progress
        )
    }

    private func loadIfNeeded() async {
        guard !hasLoaded, session.loggedIn else { return }
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LibraryService().history()
            items = data.list
            cursor = data.cursor
            hasMore = !data.list.isEmpty
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !items.isEmpty, let cursor else { return }
        isLoadingMore = true
        do {
            let data = try await LibraryService().history(
                max: cursor.max ?? 0,
                business: cursor.business ?? "",
                viewAt: cursor.viewAt ?? 0
            )
            let seen = Set(items.map(\.id))
            let fresh = data.list.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            self.cursor = data.cursor
            hasMore = !fresh.isEmpty
        } catch {
            // 静默失败
        }
        isLoadingMore = false
    }
}
