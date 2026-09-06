import SwiftUI

/// 直播页：热门/推荐直播的卡片流，布局与首页视频卡片一致
/// （可切换卡片 / 列表模式），点击进入直播间。
struct LiveFeedView: View {
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var rooms: [LiveRoomCard] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    private var usableRooms: [LiveRoomCard] {
        rooms.filter { $0.roomid > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !usableRooms.isEmpty {
                    Text("共 \(Formatters.count(usableRooms.count)) 个直播")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VideoFeedLayout(mode: displayMode) {
                    ForEach(usableRooms) { room in
                        NavigationLink(value: LiveRoute(room: room)) {
                            LiveCardView(room: room)
                        }
                        .buttonStyle(.plain)
                    }
                } rowContent: {
                    ForEach(usableRooms) { room in
                        NavigationLink(value: LiveRoute(room: room)) {
                            MediaListRow(
                                coverURL: room.cover,
                                title: room.title ?? "未知直播",
                                line2: room.uname ?? "未知主播",
                                line3: watchingText(room) ?? "",
                                durationText: nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !usableRooms.isEmpty {
                    LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore) {
                        await loadMore()
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("直播")
        .autoLoadMore { await loadMore() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .overlay {
            if isLoading && rooms.isEmpty {
                ProgressView("加载中…")
            } else if let errorMessage, rooms.isEmpty {
                LoadErrorView(message: errorMessage) {
                    await load()
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            await load()
        }
    }

    private func watchingText(_ room: LiveRoomCard) -> String? {
        if let text = room.watchedShow?.textSmall, !text.isEmpty {
            return "\(text) 人在看"
        }
        guard let online = room.online, online > 0 else { return nil }
        return "\(Formatters.count(online)) 人在看"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            rooms = try await LiveService().recommend(page: 1)
            page = 1
            hasMore = true
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !rooms.isEmpty else { return }
        isLoadingMore = true
        do {
            let fresh = try await LiveService().recommend(page: page + 1)
            let seen = Set(rooms.map(\.roomid))
            let newRooms = fresh.filter { !seen.contains($0.roomid) }
            rooms.append(contentsOf: newRooms)
            page += 1
            // 推荐接口没有明确的“到底”标记：本页不足一页即视为没有更多
            hasMore = fresh.count >= 50
        } catch {
            // 翻页失败：保留 hasMore，下拉可重试
        }
        isLoadingMore = false
    }
}

/// 直播卡片：与视频卡片同尺寸布局（16:9 封面固定、标题两行等高），
/// 左上角红色“直播”徽标，底部展示主播与观看人数。
struct LiveCardView: View {
    let room: LiveRoomCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            ZStack(alignment: .topLeading) {
                Text("\n")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .hidden()
                Text(room.title ?? "未知直播")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                Text(room.uname?.isEmpty == false ? room.uname! : "未知主播")
                    .lineLimit(1)
                Spacer()
                if let text = watchingText {
                    Image(systemName: "person.2.fill")
                    Text(text)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .contentCard()
        .hoverScale(cornerRadius: 18)
    }

    private var watchingText: String? {
        if let text = room.watchedShow?.textSmall, !text.isEmpty {
            return text
        }
        guard let online = room.online, online > 0 else { return nil }
        return Formatters.count(online)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RemoteImage(url: Formatters.https(room.cover))
                }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("直播")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
