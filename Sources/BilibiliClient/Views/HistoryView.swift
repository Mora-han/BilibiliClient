import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var session: SessionStore
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
        ContentUnavailableView {
            Label("登录后查看历史", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("需要登录哔哩哔哩账号才能同步观看历史")
        } actions: {
            Button("扫码登录") { showLogin = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading && items.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, items.isEmpty {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else if usableItems.isEmpty {
                    Text("暂无观看历史")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(usableItems) { item in
                            NavigationLink(value: item.history?.bvid ?? "") {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }

                        if hasMore {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                if isLoadingMore {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("加载更多")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
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
        guard !isLoadingMore, hasMore, let cursor else { return }
        isLoadingMore = true
        do {
            let data = try await LibraryService().history(
                max: cursor.max ?? 0,
                business: cursor.business ?? "",
                viewAt: cursor.viewAt ?? 0
            )
            let seen = Set(items.map(\.id))
            items.append(contentsOf: data.list.filter { !seen.contains($0.id) })
            self.cursor = data.cursor
            hasMore = !data.list.isEmpty
        } catch {
            // 静默失败
        }
        isLoadingMore = false
    }
}
