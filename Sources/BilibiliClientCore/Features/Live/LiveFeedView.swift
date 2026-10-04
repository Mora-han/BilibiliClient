import SwiftUI

/// 直播页：热门/推荐直播的卡片流，布局与首页视频卡片一致
/// （可切换卡片 / 列表模式），点击进入直播间。
struct LiveFeedView: View {
    /// 所在标签是否可见（见 `\.isTabVisible`）：隐藏页不声明工具栏条目，
    /// 否则 keep-alive 下会合并进当前窗口（多出刷新 / 编辑按钮）。
    @Environment(\.isTabVisible) private var isTabVisible
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card
    @State private var rooms: [LiveRoomCard] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    /// 上一次翻页是否失败（失败时底部显示可点重试行）
    @State private var loadMoreFailed = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    private var usableRooms: [LiveRoomCard] {
        rooms.filter { $0.roomid > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading && rooms.isEmpty {
                    VideoFeedSkeleton(mode: displayMode)
                } else {
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
                        LoadMoreFooter(isBusy: isLoadingMore, hasMore: hasMore, failed: loadMoreFailed) {
                            await loadMore()
                        }
                    }
                }
            }
            .padding(20)
        }
        #if os(macOS)
        // iOS 上嵌在「首页」分段容器里，标题由容器统一给（见 RecommendView 说明）
        .navigationTitle("直播")
        #endif
        .autoLoadMore { await loadMore() }
        .feedRefreshable { await load() }
        #if os(macOS)
        // 独立刷新按钮只留 macOS；iOS 用下拉刷新（见 RecommendView 同处说明）
        .toolbar {
            if isTabVisible {
                ToolbarItem {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                }
            }
        }
        #endif
        .overlay {
            if !isLoading, let errorMessage, rooms.isEmpty {
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
        // 单飞：刷新按钮连点 / 重试与 .task 撞车时只发一个请求
        guard !isLoading else { return }
        // 「已尝试过」就算失败也置位：失败后重新出现不再自动重拉，
        // 等用户点重试 / 下拉刷新（避免 keep-alive 反复进出页面撞风控）
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        do {
            rooms = try await LiveService().recommend(page: 1)
            BiliImages.prefetch(rooms.map(\.cover), variant: .card)
            page = 1
            hasMore = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore, !rooms.isEmpty else { return }
        isLoadingMore = true
        loadMoreFailed = false
        do {
            let fresh = try await LiveService().recommend(page: page + 1)
            let newRooms = rooms.appendUnique(fresh)
            page += 1
            // 推荐接口没有明确的“到底”标记：本页不足一页即视为没有更多
            hasMore = fresh.count >= 20
        } catch {
            loadMoreFailed = true
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
                    RemoteImage(url: Formatters.https(room.cover), variant: .card)
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
        .cornerRadius(12, style: .circular)
    }
}
