import SwiftUI

struct HomeFeedView: View {
    @State private var items: [RecommendItem] = []
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                      spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item.bvid) {
                        VideoCardView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)

            if !items.isEmpty {
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
                .disabled(isLoadingMore)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("推荐")
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
        isLoading = true
        errorMessage = nil
        do {
            let newItems = try await FeedService().recommend(page: 1)
            items = newItems
            page = 1
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let newItems = try await FeedService().recommend(page: page + 1)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: newItems.filter { !seen.contains($0.id) })
            page += 1
        } catch {
            // 翻页失败静默，用户可再点一次
        }
        isLoadingMore = false
    }
}

struct VideoCardView: View {
    let item: RecommendItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text(item.owner?.name ?? "未知UP主")
                    .lineLimit(1)
                Spacer()
                if let stat = item.stat, stat.view > 0 {
                    Image(systemName: "play.fill")
                    Text(Formatters.count(stat.view))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(hovering ? 0.22 : 0), lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: Formatters.https(item.pic))
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)

            if item.duration > 0 {
                Text(Formatters.duration(item.duration))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if let reason = item.rcmdReason?.content, !reason.isEmpty {
                Text(reason)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.pink.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
