import SwiftUI

@MainActor
struct WatchLaterView: View {
    @EnvironmentObject private var session: SessionStore
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var items: [ToViewItem] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var showLogin = false

    private var usableItems: [ToViewItem] {
        items.filter { !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !session.loggedIn {
                loginPrompt
            } else {
                content
            }
        }
        .navigationTitle("稍后再看")
        .sheet(isPresented: $showLogin) { LoginView() }
        .task { await loadIfNeeded() }
    }

    private var loginPrompt: some View {
        LoginRequiredView(title: "登录后查看稍后再看",
                          systemImage: "clock.badge.checkmark",
                          message: "需要登录哔哩哔哩账号才能同步稍后再看列表",
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
                    Text("稍后再看是空的")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    HStack {
                        Text("共 \(totalCount) 个视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 2)

                    VideoFeedLayout(mode: displayMode) {
                        ForEach(usableItems) { item in
                            NavigationLink(value: item.bvid ?? "") {
                                VideoCardView(
                                    bvid: item.bvid ?? "",
                                    title: item.title ?? "未知标题",
                                    pic: item.pic ?? "",
                                    duration: item.duration ?? 0,
                                    ownerName: item.owner?.name ?? "未知UP主",
                                    viewCount: item.stat?.view ?? 0,
                                    badgeText: nil
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } rowContent: {
                        ForEach(usableItems) { item in
                            NavigationLink(value: item.bvid ?? "") {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .refreshable { await load() }
    }

    private func row(_ item: ToViewItem) -> some View {
        let duration = Double(item.duration ?? 0)
        let progress = duration > 0 ? Double(item.progress ?? 0) / duration : 0

        return MediaListRow(
            coverURL: item.pic ?? "",
            title: item.title ?? "未知标题",
            line2: item.owner?.name ?? "未知UP主",
            line3: "添加于 \(Formatters.timeAgo(item.addAt ?? 0)) · 播放 \(Formatters.count(item.stat?.view ?? 0))",
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
            let data = try await LibraryService().watchLater()
            items = data.list
            totalCount = data.count ?? items.count
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
