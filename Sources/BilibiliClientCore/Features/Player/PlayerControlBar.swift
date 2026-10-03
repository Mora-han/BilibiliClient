// 本文件是 macOS 专属播放器实现（AVPlayerView + 自绘控制栏 + 分离窗口）。
// iOS 用系统 AVPlayerViewController，见 IOSPlayerSurface.swift。
#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI

// MARK: - 配置

/// 自绘控制栏的输入：展示所需状态 + 宿主动作闭包。
///
/// 由 SwiftUI 播放组件在每次更新时整体推给 `PlayerBarModel.apply(_:)`
/// （与 `PlayerSurfaceView.updateNSView` 同一条路径）。
/// 全屏与画中画不在此处：它们要直接操作 `AVPlayerView`，由 `DanmakuPlayerView` 自己接。
struct PlayerBarConfig {
    /// 直播流没有时间轴，改显示"直播"徽标
    var isLive = false
    /// 弹幕开关状态；nil 表示这个播放器没有弹幕层（直播），不显示按钮
    var danmakuEnabled: Bool?
    /// 清晰度列表；空表示不显示画质入口（直播）
    var qualities: [PlayerController.Quality] = []
    var currentQualityId: Int?
    /// 空降助手在进度条上要画的片段标记（空 = 不画）
    var sponsorMarkers: [SponsorMarker] = []
    /// 空降提示卡片；nil = 不显示
    var sponsorNotice: SponsorNotice?
    var onSponsorUndo: @MainActor () -> Void = {}
    var onSponsorDismiss: @MainActor () -> Void = {}
    var onTogglePlay: @MainActor () -> Void = {}
    var onSeek: @MainActor (Double) -> Void = { _ in }
    var onSkip: @MainActor (Double) -> Void = { _ in }
    var onToggleDanmaku: @MainActor () -> Void = {}
    var onSelectQuality: @MainActor (PlayerController.Quality) -> Void = { _ in }
    /// 倍速变化回传宿主：把权威值同步进 `PlayerController`（iOS 页面工具行读它），
    /// 否则控制栏显示 1.5×、页面行还停在 1×。
    var onSetSpeed: @MainActor (Float) -> Void = { _ in }
}

// MARK: - 状态中枢

/// 自绘控制栏的状态中枢。
///
/// 它由 `DanmakuPlayerView` 持有（而不是 SwiftUI 侧）：控制栏必须活在
/// `AVPlayerView.contentOverlayView` 里，才能跟着播放器一起被系统搬进全屏窗口。
/// 时间/播放状态按 0.25s 节拍从 `AVPlayer` 读取，只刷新这个小对象，
/// 不往播放页 body 发布，避免整页重算（与 PlayerController 的取舍一致）。
@MainActor
final class PlayerBarModel: ObservableObject {
    // MARK: 宿主推入的状态
    @Published private(set) var isLive = false
    @Published private(set) var hasDanmakuToggle = false
    @Published private(set) var danmakuEnabled = true
    @Published private(set) var qualities: [PlayerController.Quality] = []
    @Published private(set) var currentQualityId: Int?
    /// 空降助手标记：跟着宿主推入的配置更新，不在节拍里重算。
    @Published private(set) var sponsorMarkers: [SponsorMarker] = []
    /// 空降提示卡片：同样由宿主推入。
    @Published private(set) var sponsorNotice: SponsorNotice?
    /// 画中画入口是否可用（AVKit 未提供该入口时隐藏按钮）
    @Published var supportsPictureInPicture = false

    // MARK: 从 AVPlayer 读出的状态
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isFullscreen = false
    @Published private(set) var speed: Float = 1

    // MARK: 交互状态
    @Published private(set) var isScrubbing = false
    @Published private(set) var scrubPreview: Double?
    @Published private(set) var isBarVisible = true
    /// 弹幕设置弹层打开中：控制栏不自动收起
    @Published private(set) var isPanelOpen = false

    /// 鼠标不动多久后收起控制栏（播放中才收）
    private static let hideDelay: Duration = .seconds(2.5)

    var onToggleFullscreen: @MainActor () -> Void = {}
    var onTogglePictureInPicture: @MainActor () -> Void = {}

    private var config = PlayerBarConfig()
    private weak var player: AVPlayer?
    private var tickTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var hoveringBar = false

    // MARK: - 生命周期

    /// 绑定播放器并启动节拍；换 player 时重新绑（倍速偏好会套用到新播放器）。
    func bind(player: AVPlayer?) {
        if self.player !== player {
            self.player = player
            if let player {
                player.defaultRate = speed
            }
        }
        startTicking()
        refresh()
        pokeActivity()
    }

    /// 宿主每次 SwiftUI 更新时推入的配置
    func apply(_ config: PlayerBarConfig) {
        self.config = config
        isLive = config.isLive
        if let enabled = config.danmakuEnabled {
            hasDanmakuToggle = true
            danmakuEnabled = enabled
        } else {
            hasDanmakuToggle = false
        }
        qualities = config.qualities
        currentQualityId = config.currentQualityId
        if sponsorMarkers != config.sponsorMarkers {
            sponsorMarkers = config.sponsorMarkers
        }
        if sponsorNotice != config.sponsorNotice {
            sponsorNotice = config.sponsorNotice
        }
    }

    /// 空降卡片上的动作（由宿主接线到 PlayerController）
    var onSponsorUndo: @MainActor () -> Void = {}
    var onSponsorDismiss: @MainActor () -> Void = {}

    func setFullscreen(_ fullscreen: Bool) {
        isFullscreen = fullscreen
        pokeActivity()
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        // 0.25s 足够让时间码与进度条看起来连续，又不至于频繁刷新
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard let player else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite, !isScrubbing {
            position = max(seconds, 0)
        }
        if let item = player.currentItem {
            let total = item.duration.seconds
            duration = (total.isFinite && total > 0) ? total : 0
        }
        isPlaying = player.timeControlStatus == .playing
        if !isPlaying, !isScrubbing {
            // 暂停时控制栏常驻，避免找不到播放键
            isBarVisible = true
        }
    }

    // MARK: - 控制栏显隐

    /// 鼠标在播放区里动了：显示控制栏并重新计时收起
    func pokeActivity() {
        isBarVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled else { return }
            self?.hideIfIdle()
        }
    }

    /// 鼠标离开播放区：播放中就立刻收起
    func mouseLeftPlayer() {
        hideTask?.cancel()
        hideTask = nil
        hideIfIdle()
    }

    /// 指针悬停在控制栏上：不收起
    func setHoveringBar(_ hovering: Bool) {
        hoveringBar = hovering
        if hovering { pokeActivity() }
    }

    /// 弹幕设置弹层开合：打开期间控制栏保持可见
    func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        pokeActivity()
    }

    private func hideIfIdle() {
        guard isPlaying, !isScrubbing, !hoveringBar, !isPanelOpen else { return }
        isBarVisible = false
    }

    // MARK: - 播放控制

    var hasTimeline: Bool { !isLive && duration > 0 }
    /// 进度条上显示的时间：拖动中优先显示拖到的位置
    var displayPosition: Double { scrubPreview ?? position }

    func togglePlay() {
        config.onTogglePlay()
        pokeActivity()
        Task { @MainActor [weak self] in self?.refresh() }
    }

    func beginScrub() {
        isScrubbing = true
        scrubPreview = position
    }

    func updateScrub(_ value: Double) {
        isScrubbing = true
        scrubPreview = max(value, 0)
        pokeActivity()
    }

    func endScrub() {
        let target = scrubPreview
        isScrubbing = false
        scrubPreview = nil
        if let target {
            position = target
            config.onSeek(target)
        }
        pokeActivity()
    }

    /// 拖动进度条时的快进快退（供快捷键复用同一入口）
    func skip(by seconds: Double) {
        config.onSkip(seconds)
        pokeActivity()
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        // 同步进 PlayerController 的权威值（iOS 页面工具行读它），
        // 两端各自持一份会导致「控制栏显示 1.5×、页面行显示 1×」。
        config.onSetSpeed(newSpeed)
        if let player {
            player.defaultRate = newSpeed
            if player.timeControlStatus == .playing {
                player.rate = newSpeed
            }
        }
        pokeActivity()
    }

    func toggleDanmaku() {
        config.onToggleDanmaku()
        danmakuEnabled.toggle()
        pokeActivity()
    }

    func selectQuality(_ quality: PlayerController.Quality) {
        config.onSelectQuality(quality)
        pokeActivity()
    }

    func toggleFullscreen() {
        onToggleFullscreen()
        pokeActivity()
    }

    func togglePictureInPicture() {
        onTogglePictureInPicture()
        pokeActivity()
    }
}

// MARK: - 控制栏 UI

/// 自绘播放控制栏：液态玻璃胶囊，两层布局——顶部一整排是进度，下面一排是按钮。
/// 悬停/移动鼠标时浮现，播放中闲置 2.5s 自动收起（弹幕设置打开时保持可见）。
///
/// 内容按"简洁优先"取舍：播放/暂停 · 倍速 · 弹幕开关 · 弹幕设置 · 画质 · 画中画 · 全屏。
/// 直播没有时间轴，进度排整体不显示，按钮排里换成"直播"徽标。
/// 外观随系统深浅自适应，弹幕设置卡片等弹层也跟随系统配色。
struct PlayerControlBar: View {
    @ObservedObject var model: PlayerBarModel
    @State private var showDanmakuSettings = false

    var body: some View {
        VStack(spacing: 8) {
            // 顶部一排：整排都是进度（拖动 + 两端时间）
            if model.hasTimeline {
                progressRow
            }

            // 按钮排
            HStack(spacing: 8) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 22)
                }
                .controlPill()
                .help(model.isPlaying ? "暂停（空格）" : "播放（空格）")

                if !model.hasTimeline {
                    liveBadge
                }

                Spacer(minLength: 10)

                speedButton

                if model.hasDanmakuToggle {
                    Button {
                        model.toggleDanmaku()
                    } label: {
                        Image(systemName: model.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 22)
                    }
                    .controlPill()
                    .help(model.danmakuEnabled ? "关闭弹幕（⌘D）" : "开启弹幕（⌘D）")

                    Button {
                        showDanmakuSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 22)
                    }
                    .controlPill()
                    .help("弹幕设置")
                }

                if !model.qualities.isEmpty {
                    qualityMenu
                }

                if model.supportsPictureInPicture {
                    Button {
                        model.togglePictureInPicture()
                    } label: {
                        Image(systemName: "pip")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 22)
                    }
                    .controlPill()
                    .help("画中画")
                }

                Button {
                    model.toggleFullscreen()
                } label: {
                    Image(systemName: model.isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .controlPill()
                .help(model.isFullscreen ? "退出全屏（⌘F）" : "全屏（⌘F）")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.06))
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .onHover { model.setHoveringBar($0) }
        .popover(isPresented: $showDanmakuSettings, arrowEdge: .bottom) {
            DanmakuSettingsCard()
        }
        .onChange(of: showDanmakuSettings) { _, open in
            model.setPanelOpen(open)
        }
        .opacity(model.isBarVisible ? 1 : 0)
        .offset(y: model.isBarVisible ? 0 : 6)
        .allowsHitTesting(model.isBarVisible)
        .animation(.easeOut(duration: 0.18), value: model.isBarVisible)
    }

    // MARK: 进度（顶部整排）

    private var progressRow: some View {
        HStack(spacing: 10) {
            Text(Formatters.duration(Int(model.displayPosition)))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)

            VStack(spacing: 2) {
                slider
                // 没有空降片段时这一层完全不出现，控制栏高度与改造前一致
                if !model.sponsorMarkers.isEmpty {
                    SponsorMarkerStrip(markers: model.sponsorMarkers, duration: model.duration)
                }
            }

            Text(Formatters.duration(Int(model.duration)))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: 进度

    private var slider: some View {
        Slider(
            value: Binding(
                get: { model.displayPosition },
                set: { model.updateScrub($0) }
            ),
            in: 0...max(model.duration, 1)
        ) { editing in
            if editing {
                model.beginScrub()
            } else {
                model.endScrub()
            }
        }
        .controlSize(.small)
        .tint(.primary)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
            Text("直播")
                .font(.system(size: 11, weight: .semibold))
        }
    }

    // MARK: 倍速

    /// 独立的倍速调节按钮：点开倍速菜单，按钮上直接显示当前倍速
    private var speedButton: some View {
        Menu {
            ForEach(PlayerController.speedOptions, id: \.self) { option in
                Button {
                    model.setSpeed(option)
                } label: {
                    if abs(model.speed - option) < 0.01 {
                        Label(speedText(option), systemImage: "checkmark")
                    } else {
                        Text(speedText(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge")
                    .font(.system(size: 10, weight: .semibold))
                Text(speedText(model.speed))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(height: 22)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlPill()
        .help("播放速度")
    }

    private func speedText(_ value: Float) -> String {
        PlayerController.speedText(value)
    }

    // MARK: 画质

    private var qualityMenu: some View {
        Menu {
            ForEach(model.qualities) { quality in
                Button {
                    model.selectQuality(quality)
                } label: {
                    if quality.id == model.currentQualityId {
                        Label(quality.name, systemImage: "checkmark")
                    } else {
                        Text(quality.name)
                    }
                }
            }
        } label: {
            Text(currentQualityName ?? "画质")
                .font(.system(size: 11, weight: .semibold))
                .frame(height: 22)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlPill()
        .help("清晰度")
    }

    private var currentQualityName: String? {
        guard let id = model.currentQualityId else { return nil }
        return model.qualities.first { $0.id == id }?.name
    }
}

// MARK: - 按钮样式

/// 控制栏按钮的悬停小胶囊：平时透明，指针移上去浮出一层浅底，
/// 让"弹幕设置""倍速"这些图标看起来是可点的按钮而不是装饰。
private struct ControlPill: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.12 : 0.001))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
    }
}

extension View {
    fileprivate func controlPill() -> some View {
        modifier(ControlPill())
    }
}

// MARK: - 空降片段标记

/// 空降片段的色块带，贴在进度条正下方，按时间比例摆放。
///
/// 不叠在系统 `Slider` 上是有原因的：macOS 的 Slider 轨道不透明，
/// 画在背后会被轨道盖住，画在前面又会挡住滑块。另起一条细带既清楚
/// 又完全不碰 Slider 自己的拖动手感。
private struct SponsorMarkerStrip: View {
    let markers: [SponsorMarker]
    let duration: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ForEach(markers) { marker in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: marker.category.markerColorHex) ?? .accentColor)
                        .frame(width: max(2, geometry.size.width * fraction(marker)), height: 3)
                        .offset(x: geometry.size.width * startFraction(marker))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: 3)
        // 让色块带与 Slider 轨道两端对齐（系统 Slider 两端会留出滑块半径的余量）
        .padding(.horizontal, 8)
        .allowsHitTesting(false)
        .help("进度条上的色块：空降助手标记的可跳过片段")
    }

    private func startFraction(_ marker: SponsorMarker) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(marker.start / duration, 0), 1)
    }

    private func fraction(_ marker: SponsorMarker) -> Double {
        guard duration > 0 else { return 0 }
        return min(max((marker.end - marker.start) / duration, 0), 1)
    }
}

// MARK: - 承载层

/// 挂在 `contentOverlayView` 里的控制栏宿主。
///
/// 职责：
/// 1. 底部居中摆放胶囊控制栏（约束让它在窄画面里自动压缩）；
/// 2. 鼠标移动/进出播放区 → 控制栏显隐；
/// 3. 画面区域双击 = 进出全屏（撤掉 AVKit 控件条后这颗手势由自绘层接管）。
final class PlayerControlsHostView: NSView {
    private let model: PlayerBarModel
    private let barView: NSHostingView<PlayerControlBar>
    private var trackingArea: NSTrackingArea?

    init(model: PlayerBarModel) {
        self.model = model
        self.barView = NSHostingView(rootView: PlayerControlBar(model: model))
        super.init(frame: .zero)

        barView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barView)
        NSLayoutConstraint.activate([
            barView.centerXAnchor.constraint(equalTo: centerXAnchor),
            barView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            barView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            barView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            barView.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // mouseMoved 只有窗口接受鼠标移动事件时才会派发
        window?.acceptsMouseMovedEvents = true
    }

    override func layout() {
        super.layout()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        model.pokeActivity()
    }

    override func mouseEntered(with event: NSEvent) {
        model.pokeActivity()
    }

    override func mouseExited(with event: NSEvent) {
        model.mouseLeftPlayer()
    }

    override func mouseDown(with event: NSEvent) {
        // 画面区域双击进出全屏；控制栏上不触发
        if event.clickCount == 2, !isPointInBar(event.locationInWindow) {
            model.toggleFullscreen()
            return
        }
        super.mouseDown(with: event)
    }

    private func isPointInBar(_ windowPoint: NSPoint) -> Bool {
        barView.frame.contains(convert(windowPoint, from: nil))
    }
}
#endif
