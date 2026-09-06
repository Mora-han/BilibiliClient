import SwiftUI

/// 直播路由：由直播卡片/列表点击进入，携带直播间基础信息做首屏展示。
struct LiveRoute: Hashable {
    let roomId: Int
    let uname: String?
    let face: String?
    let title: String?

    init(roomId: Int, uname: String? = nil, face: String? = nil, title: String? = nil) {
        self.roomId = roomId
        self.uname = uname
        self.face = face
        self.title = title
    }

    init(room: LiveRoomCard) {
        roomId = room.roomid
        uname = room.uname
        face = room.face
        title = room.title
    }
}

/// 直播间详情页：整体照搬视频播放页框架 —— 顶部 16:9 播放区域
/// （直播画面由 LiveWindow 嵌入窗口承载并随页面钉位）+ 下方滚动内容；
/// 原来的评论区替换为“实时弹幕”聊天区，展示实时更新的弹幕/礼物/进场消息。
struct LiveDetailView: View {
    let route: LiveRoute

    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = LivePlayerModel()
    @StateObject private var danmaku: LiveDanmakuEngine
    /// 本页首次出现时导航栈的深度（记录后，栈变深=被新页面覆盖，变回=回到本页）
    @State private var navBaseCount = 0
    @State private var detail: LiveRoomDetail?
    @State private var anchorName: String?
    @State private var anchorFace: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(route: LiveRoute) {
        self.route = route
        _danmaku = StateObject(wrappedValue: LiveDanmakuEngine(roomId: route.roomId))
    }

    var body: some View {
        Group {
            if isLoading {
                ScrollView {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                        .frame(maxWidth: 980)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            } else if let errorMessage {
                ScrollView {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await load() }
                        }
                    }
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            } else if let detail {
                content(detail)
            }
        }
        .navigationTitle(detail?.title ?? "直播间")
        .task { await load() }
        .onAppear {
            navBaseCount = router.path.count
        }
        .onChange(of: router.path.count) { _, newCount in
            if newCount > navBaseCount {
                // 被推入的新页面覆盖（如 UP 主页）：关闭直播窗口并停止播放
                closePlayback()
            } else if newCount == navBaseCount {
                // 回到本页：恢复直播画面与弹幕连接
                Task { await load() }
            }
        }
        .onDisappear {
            closePlayback()
        }
        .onChange(of: danmaku.popularity) { _, popularity in
            // 心跳会带实时热度，刷新播放窗口左上角与状态行的在线人数
            if let popularity, popularity > 0 {
                model.updateOnlineText(Formatters.count(popularity))
            }
        }
    }

    // MARK: - 加载

    private func load() async {
        if let data = detail {
            // 返回后再进入：恢复已停止的直播与弹幕
            if model.player == nil {
                await model.load(roomId: data.roomId)
            }
            await danmaku.connect()
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let data = try await LiveService().roomInfo(roomId: route.roomId)
            detail = data
            isLoading = false
            anchorName = route.uname
            anchorFace = route.face
            model.updateOnlineText(watchingText(data.online))
            // 主播昵称/头像若路由未带则补拉一次
            if (route.uname?.isEmpty ?? true) || (route.face?.isEmpty ?? true) {
                let anchor = try? await LiveService().anchorInfo(uid: data.uid)
                if anchorName == nil || anchorName?.isEmpty == true {
                    anchorName = anchor?.info?.uname
                }
                if anchorFace == nil || anchorFace?.isEmpty == true {
                    anchorFace = anchor?.info?.face
                }
            }
            async let playerTask: Void = model.load(roomId: data.roomId)
            async let danmakuTask: Void = danmaku.connect()
            _ = await (playerTask, danmakuTask)
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 页面销毁/被覆盖时统一收尾：关闭直播窗口、停流、断开弹幕。
    private func closePlayback() {
        LiveWindow.shared?.forceClose()
        LiveWindow.shared = nil
        model.stop()
        danmaku.disconnect()
        danmaku.reset()
    }

    private func watchingText(_ online: Int) -> String? {
        guard online > 0 else { return nil }
        return Formatters.count(online)
    }

    // MARK: - 内容

    private func content(_ detail: LiveRoomDetail) -> some View {
        VStack(spacing: 0) {
            // 直播固定在页面顶部：滚动时保持原位完整可见，下方内容独立滑动
            playerSection
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 24)

            Color.clear
                .frame(height: 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    infoRow(detail)

                    Text(detail.title ?? "未知直播")
                        .font(.title2.bold())
                        .textSelection(.enabled)

                    statusRow(detail)

                    Divider()

                    Text("简介").font(.headline)
                    Text(detail.description?.isEmpty == false ? detail.description! : "主播还没有填写直播间简介")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)

                    Divider()

                    danmakuSection

                    Spacer(minLength: 40)
                }
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    /// 顶部 16:9 播放区域：画面由 LiveWindow 子窗口承载（钉在本区域），
    /// 就绪后这里只保留透明占位撑布局 + FrameReporter 定位直播窗口。
    @ViewBuilder
    private var playerSection: some View {
        ZStack {
            switch model.state {
            case .idle, .loading:
                Rectangle().fill(.black)
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在连接直播间…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .offline:
                Rectangle().fill(.black)
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("主播还未开播").font(.headline)
                    Text("可以先去看看别的直播间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                Rectangle().fill(.black)
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("直播加载失败").font(.headline)
                    Text(model.errorMessage ?? "未知错误")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await model.retry(roomId: detail?.roomId ?? route.roomId) }
                    }
                }
                .padding()
            case .ready:
                // 直播画面由 LiveWindow 子窗口承载，这里不放可见占位
                Color.clear
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(
            Rectangle()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .background(
            FrameReporter(onFrame: { frame in
                if let liveWindow = LiveWindow.shared, liveWindow.isOpen {
                    liveWindow.updateEmbedFrame(frame)
                } else if model.state == .ready, model.player != nil {
                    openLiveWindow(at: frame)
                }
            }, force: model.state == .ready)
        )
    }

    private func openLiveWindow(at frame: CGRect) {
        guard model.state == .ready, model.player != nil,
              let window = AppDelegate.mainWindow() else { return }
        if let existing = LiveWindow.shared, existing.isOpen {
            existing.updateEmbedFrame(frame)
            return
        }
        let liveWindow = LiveWindow()
        LiveWindow.shared = liveWindow
        liveWindow.open(model: model, parent: window, frame: frame)
        liveWindow.focusPlayer()
    }

    /// 主播信息行：头像 + 昵称（可点击进入 UP 主页）。
    private func infoRow(_ detail: LiveRoomDetail) -> some View {
        HStack(spacing: 14) {
            NavigationLink(value: UpRoute(mid: detail.uid)) {
                HStack(spacing: 8) {
                    RemoteImage(url: Formatters.https(anchorFace ?? ""))
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                    Text(anchorName?.isEmpty == false ? anchorName! : "未知主播")
                        .font(.callout.weight(.medium))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text("房间号 \(detail.roomId)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func statusRow(_ detail: LiveRoomDetail) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Circle()
                    .fill(detail.isLive ? Color.red : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(detail.isLive ? "直播中" : "未开播")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(detail.isLive ? Color.red : Color.secondary)
            }
            if detail.online > 0 {
                Label("\(watchingText(detail.online) ?? "0") 人在看",
                      systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !(detail.parentAreaName?.isEmpty ?? true) || !(detail.areaName?.isEmpty ?? true) {
                Label([detail.parentAreaName, detail.areaName]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "),
                      systemImage: "square.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 实时弹幕区

    private var danmakuSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时弹幕", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                Spacer()
                if danmaku.isConnected {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("已连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = danmaku.errorText {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("连接中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LiveChatPanel(engine: danmaku)
        }
    }
}

/// 实时弹幕聊天面板：新弹幕追加在底部并自动跟随滚动；
/// 手动向上翻阅时暂停跟随，滑回底部后恢复。
private struct LiveChatPanel: View {
    @ObservedObject var engine: LiveDanmakuEngine
    @State private var autoFollow = true
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(engine.messages) { message in
                        LiveChatRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isDark ? 0.6 : 0.8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                    }
            }
            .frame(height: 420)
            .onChange(of: engine.messages.count) { _, _ in
                guard autoFollow, let last = engine.messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
            } action: { _, remaining in
                autoFollow = remaining < 32
            }
            .overlay {
                if engine.messages.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text(engine.errorText ?? "等待弹幕…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// 弹幕聊天区的一行：用户名 + 内容，按类型区分视觉样式。
private struct LiveChatRow: View {
    let message: LiveDanmakuMessage

    var body: some View {
        switch message.kind {
        case .danmaku:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.user)
                    .font(.caption)
                    .foregroundStyle(Color.pink.opacity(0.8))
                    .lineLimit(1)
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        case .welcome:
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.user)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("进入了直播间")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .gift:
            HStack(spacing: 6) {
                Image(systemName: "gift.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                Text(message.user)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
            }
        case .superChat:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "star.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(message.user.isEmpty ? "醒目留言" : message.user)
                        .font(.caption.weight(.semibold))
                }
                Text(message.text)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.yellow.opacity(0.12))
            )
            .padding(.vertical, 2)
        }
    }
}
