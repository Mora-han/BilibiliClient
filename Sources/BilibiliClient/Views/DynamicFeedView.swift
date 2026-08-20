import SwiftUI

struct DynamicFeedView: View {
    @State private var items: [DynamicItem] = []
    @State private var offset: String?
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
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
            await load()
        }
    }

    private func load() async {
        guard !isLoading else { return }
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
        guard !isLoadingMore, let offset, hasMore else { return }
        isLoadingMore = true
        do {
            let data = try await DynamicService().feed(offset: offset)
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
            RemoteImage(url: Formatters.https(item.modules.moduleAuthor?.face ?? ""))
                .frame(width: 36, height: 36)
                .clipShape(Circle())
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
