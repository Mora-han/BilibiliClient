import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var folders: [FavFolder] = []
    @State private var selectedFolderId: Int?
    @State private var medias: [FavMedia] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var errorMessage: String?
    @State private var hasLoaded = false
    @State private var showLogin = false

    private var usableMedias: [FavMedia] {
        medias.filter { $0.isUsable && ($0.type ?? 0) == 2 && !($0.bvid ?? "").isEmpty }
    }

    var body: some View {
        Group {
            if !session.loggedIn {
                loginPrompt
            } else {
                content
            }
        }
        .navigationTitle("收藏")
        .sheet(isPresented: $showLogin) { LoginView() }
        .task { await loadIfNeeded() }
    }

    private var loginPrompt: some View {
        LoginRequiredView(title: "登录后查看收藏",
                          systemImage: "bookmark",
                          message: "需要登录哔哩哔哩账号才能同步收藏夹",
                          showLogin: $showLogin)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !folders.isEmpty {
                    folderChips
                }

                if isLoading && medias.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let errorMessage, medias.isEmpty {
                    LoadErrorView(message: errorMessage) {
                        await load()
                    }
                } else if usableMedias.isEmpty {
                    Text("这个收藏夹里还没有视频")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(usableMedias) { media in
                            NavigationLink(value: media.bvid ?? "") {
                                MediaListRow(
                                    coverURL: media.cover ?? "",
                                    title: media.title ?? "",
                                    line2: media.upper?.name ?? "未知UP主",
                                    line3: "收藏于 \(Formatters.timeAgo(media.favTime ?? 0)) · 播放 \(Formatters.count(media.cntInfo?.play ?? 0))",
                                    durationText: Formatters.duration(media.duration ?? 0)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if hasMore {
                            LoadMoreFooter(isBusy: isLoadingMore) {
                                await loadMore()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .refreshable { await load() }
        .autoLoadMore { await loadMore() }
    }

    private var folderChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(folders) { folder in
                    Button {
                        selectFolder(folder)
                    } label: {
                        HStack(spacing: 5) {
                            Text(folder.title ?? "未命名")
                            if let count = folder.mediaCount {
                                Text("\(count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selectedFolderId == folder.id
                                ? AnyShapeStyle(.tint.opacity(0.2))
                                : AnyShapeStyle(.quaternary.opacity(0.4)),
                            in: Capsule()
                        )
                        .foregroundStyle(selectedFolderId == folder.id ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func loadIfNeeded() async {
        guard !hasLoaded, session.loggedIn else { return }
        await load()
    }

    private func load() async {
        guard let mid = session.user?.mid else {
            await session.refreshUser()
            guard let mid = session.user?.mid else { return }
            await loadFolders(mid: mid)
            return
        }
        await loadFolders(mid: mid)
    }

    private func loadFolders(mid: Int) async {
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LibraryService().favoriteFolders(mid: mid)
            folders = data.list ?? []
            if let first = folders.first {
                selectFolder(first)
            }
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func selectFolder(_ folder: FavFolder) {
        selectedFolderId = folder.id
        medias = []
        page = 0
        hasMore = true
        Task { await loadFolderResources(mediaId: folder.id) }
    }

    private func loadFolderResources(mediaId: Int) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LibraryService().favoriteResources(mediaId: mediaId, page: 1)
            medias = data.medias
            page = 1
            hasMore = data.hasMore ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !medias.isEmpty, let folderId = selectedFolderId else { return }
        isLoadingMore = true
        do {
            let data = try await LibraryService().favoriteResources(mediaId: folderId, page: page + 1)
            let seen = Set(medias.map(\.id))
            let fresh = data.medias.filter { !seen.contains($0.id) }
            medias.append(contentsOf: fresh)
            page += 1
            hasMore = (data.hasMore ?? false) && !fresh.isEmpty
        } catch {
            // 静默失败
        }
        isLoadingMore = false
    }
}
