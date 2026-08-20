import SwiftUI

struct DynamicFeedView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var items: [DynamicItem] = []
    @State private var followedUPs: [FollowedUser] = []
    @State private var selectedUP: Int?
    @State private var offset: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            upBar
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(displayItems) { item in
                        DynamicCardView(item: item)
                    }

                if hasMore && !items.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .onAppear {
                            Task { await loadMore() }
                        }
                }
            }
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
        .navigationTitle("动态")
        .overlay {
            if isLoading && items.isEmpty {
                ProgressView("加载中…")
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            await prepare()
        }
    }

    private var displayItems: [DynamicItem] {
        guard selectedUP != nil else { return items }
        return items.filter {
            $0.modules.moduleDynamic?.major?.type == "MAJOR_TYPE_ARCHIVE"
        }
    }

    private var upBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", isSelected: selectedUP == nil) {
                    selectUP(nil)
                }
                ForEach(followedUPs) { up in
                    chip(title: up.uname ?? "UP", isSelected: selectedUP == up.mid, avatar: up.face ?? "") {
                        selectUP(up.mid)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func chip(title: String, isSelected: Bool, avatar: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let avatar, !avatar.isEmpty {
                    RemoteImage(url: Formatters.https(avatar))
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                }
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    private func selectUP(_ mid: Int?) {
        selectedUP = mid
        items = []
        offset = nil
        hasMore = true
        Task { await load() }
    }

    private func prepare() async {
        if session.loggedIn {
            if session.user == nil {
                await session.refreshUser()
            }
            if let mid = session.user?.mid {
                do {
                    let data = try await RelationService().followings(mid: mid, page: 1, pageSize: 50)
                    followedUPs = data.list
                } catch {
                    // 关注栏失败不影响动态流
                }
            }
        }
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await DynamicService().feed(hostMid: selectedUP)
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
        guard !isLoadingMore, let offset, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await DynamicService().feed(offset: offset, hostMid: selectedUP)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: data.items.filter { !seen.contains($0.id) })
            self.offset = data.offset
            hasMore = data.hasMore ?? false
        } catch {
            // 翻页失败静默
        }
        isLoadingMore = false
    }
}

struct DynamicCardView: View {
    let item: DynamicItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let text = item.modules.moduleDynamic?.desc?.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            majorContent

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let mid = item.modules.moduleAuthor?.mid {
                    NavigationLink(value: UpRoute(mid: mid)) {
                        RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.modules.moduleAuthor?.name ?? "未知用户")
                    .font(.callout.weight(.semibold))
                if let time = item.modules.moduleAuthor?.pubTime {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var majorContent: some View {
        if let major = item.modules.moduleDynamic?.major {
            switch major.type {
            case "MAJOR_TYPE_ARCHIVE":
                if let archive = major.archive {
                    archiveCard(archive)
                }
            case "MAJOR_TYPE_DRAW":
                if let draw = major.draw {
                    drawGrid(Array(draw.items?.prefix(9) ?? []))
                }
            case "MAJOR_TYPE_OPUS":
                if let text = major.opus?.summary?.text, !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            default:
                EmptyView()
            }
        }
    }

    private func archiveCard(_ archive: DynamicItem.ModuleDynamic.Major.Archive) -> some View {
        NavigationLink(value: archive.bvid ?? "") {
            HStack(spacing: 10) {
                RemoteImage(url: Formatters.https(archive.cover ?? ""))
                    .frame(width: 128, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(archive.title ?? "")
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let desc = archive.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let duration = archive.durationText {
                        Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func drawGrid(_ items: [DynamicItem.ModuleDynamic.Major.Draw.DrawItem]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                            count: min(max(items.count, 1), 3))
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                RemoteImage(url: Formatters.https(items[index].src ?? ""))
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Label(Formatters.count(stat?.like?.count ?? 0), systemImage: "heart")
            Label(Formatters.count(stat?.comment?.count ?? 0), systemImage: "bubble.right")
            Label(Formatters.count(stat?.forward?.count ?? 0), systemImage: "arrowshape.turn.up.right")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var stat: DynamicItem.ModuleStat? {
        item.modules.moduleStat
    }
}
