import SwiftUI

/// 菜单栏弹出的卡片：顶部用户信息，下方单列动态流，点击视频跳转主界面。
struct MenuBarPanelView: View {
    @ObservedObject var session: SessionStore
    @ObservedObject var router: AppRouter
    var onOpenVideo: (String) -> Void = { _ in }
    var onOpenApp: () -> Void = {}

    @State private var items: [DynamicItem] = []
    @State private var offset: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: 380, height: 540)
        .onAppear {
            guard !hasLoaded else { return }
            Task { await load() }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
    }

    // MARK: - 顶部用户信息

    private var header: some View {
        HStack(spacing: 12) {
            if let user = session.user {
                RemoteImage(url: Formatters.https(user.face))
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(user.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Lv.\(user.level) · 关注 \(Formatters.count(user.following)) · 粉丝 \(Formatters.count(user.follower)) · 硬币 \(Formatters.decimal(user.coin))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.loggedIn ? "同步中…" : "未登录")
                        .font(.headline)
                    Text("登录后查看关注动态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                if session.loggedIn {
                    Task { await load(force: true) }
                } else {
                    showLogin = true
                }
            } label: {
                Image(systemName: session.loggedIn ? "arrow.clockwise" : "qrcode")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .help(session.loggedIn ? "刷新动态" : "扫码登录")

            Button {
                onOpenApp()
            } label: {
                Image(systemName: "macwindow")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .help("返回主界面")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 动态列表（单列）

    @ViewBuilder
    private var list: some View {
        if isLoading && items.isEmpty {
            ProgressView("加载动态中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, items.isEmpty {
            VStack(spacing: 10) {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await load(force: true) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if items.isEmpty {
            Text(session.loggedIn ? "暂无动态" : "登录后查看关注动态")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            MenuBarDynamicRow(item: item) { bvid in
                                onOpenVideo(bvid)
                            }
                            Divider()
                                .padding(.leading, 56)
                        }
                    }

                    if !items.isEmpty {
                        LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                            await loadMore()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // 接近底部自动预载下一页，与主界面一致的无感连续加载
            .autoLoadMore(threshold: 500) { await loadMore() }
        }
    }

    private func load(force: Bool = false) async {
        guard !isLoading else { return }
        if force {
            items = []
            offset = nil
            hasMore = true
        }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await DynamicService().feed()
            items = data.items
            offset = data.offset
            hasMore = data.hasMore ?? false
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !items.isEmpty, let offset else { return }
        isLoadingMore = true
        do {
            let data = try await DynamicService().feed(offset: offset)
            let seen = Set(items.map(\.id))
            let fresh = data.items.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            self.offset = data.offset
            hasMore = (data.hasMore ?? false) && !fresh.isEmpty
        } catch {
            // 翻页失败：保留 hasMore，滚动或点击可重试
        }
        isLoadingMore = false
    }
}

/// 菜单栏里的紧凑动态行：UP 头像 + 内容；视频动态可点击跳转。
private struct MenuBarDynamicRow: View {
    let item: DynamicItem
    var onOpen: (String) -> Void

    private var author: DynamicItem.ModuleAuthor? { item.modules.moduleAuthor }
    private var dynamic: DynamicItem.ModuleDynamic? { item.modules.moduleDynamic }
    private var archive: DynamicItem.ModuleDynamic.Major.Archive? {
        guard let major = dynamic?.major, major.type == "MAJOR_TYPE_ARCHIVE" else { return nil }
        return major.archive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RemoteImage(url: Formatters.https(author?.face ?? ""))
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                Text(author?.name ?? "未知用户")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let time = author?.pubTime {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if let text = dynamic?.desc?.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let archive {
                Button {
                    onOpen(archive.bvid ?? "")
                } label: {
                    HStack(spacing: 10) {
                        RemoteImage(url: Formatters.https(archive.cover ?? ""))
                            .frame(width: 108, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(archive.title ?? "")
                                .font(.callout.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            if let duration = archive.durationText {
                                Text(duration)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在应用中打开")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
