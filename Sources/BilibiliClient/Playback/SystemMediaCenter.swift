import AppKit
import MediaPlayer

/// 系统媒体键与“正在播放”集成：
/// - F7 = 左方向键（后退 15 秒）
/// - F8 = 空格（播放/暂停）
/// - F9 = 右方向键（前进 15 秒；若系统把 F1-F12 设为标准功能键，
///        长按 F9 与右方向键长按一致，进入 2x 快进）
/// 媒体键由系统截获后以 MPRemoteCommand 事件送达，App 在后台也能响应；
/// 同时向 MPNowPlayingInfoCenter 上报标题/时长/进度，控制中心可显示与拖动进度。
@MainActor
final class SystemMediaCenter {
    static let shared = SystemMediaCenter()

    private weak var player: PlayerController?
    private var title = ""
    private var artist = ""
    private var artwork: MPMediaItemArtwork?
    private var lastProgressPush = Date.distantPast
    private var installed = false
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// F9 长按 2x 快进（仅“标准功能键”模式下的 keyDown/keyUp 路径）
    private var holdTask: Task<Void, Never>?
    private var f9Down = false
    private var fastForwardActive = false

    private init() {}

    // MARK: - 安装

    func install() {
        guard !installed else { return }
        installed = true
        registerRemoteCommands()
        installFunctionKeyMonitor()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelF9Hold() }
        }
    }

    // MARK: - 绑定 / 解绑

    /// 视频页加载成功后调用：把当前播放器注册为系统“正在播放”，
    /// 之后媒体键（F7/F8/F9）都会路由到该播放器。
    func bind(player: PlayerController, title: String, artist: String, artworkURL: URL?) {
        self.player = player
        self.title = title
        self.artist = artist
        artwork = nil
        if let artworkURL {
            loadArtwork(artworkURL)
        }
        syncNowPlaying(force: true)
    }

    /// 播放器停止（离开页面/切换视频）时解绑，避免媒体键继续控制已停播的播放器。
    func playerDidStop(_ player: PlayerController) {
        guard self.player === player else { return }
        unbind()
    }

    private func unbind() {
        player = nil
        title = ""
        artist = ""
        artwork = nil
        cancelF9Hold()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    // MARK: - Now Playing 上报

    /// 播放器时间节拍/状态变化时调用；内部限频（约 1 秒一次），force 用于关键状态变化。
    func syncNowPlaying(force: Bool = false) {
        guard player != nil else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastProgressPush) < 1 { return }
        lastProgressPush = now
        guard let avPlayer = player?.player, let info = makeNowPlayingInfo() else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // macOS 必须显式设置播放状态，远程控制（媒体键/控制中心）才会路由到本 App
        center.playbackState = avPlayer.timeControlStatus == .playing ? .playing : .paused
    }

    private func makeNowPlayingInfo() -> [String: Any]? {
        guard let avPlayer = player?.player else { return nil }
        var info: [String: Any] = [:]
        if !title.isEmpty { info[MPMediaItemPropertyTitle] = title }
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let duration = avPlayer.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        let current = avPlayer.currentTime().seconds
        if current.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(current, 0)
        }
        let isPlaying = avPlayer.timeControlStatus == .playing
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(avPlayer.rate) : 0
        return info
    }

    private func loadArtwork(_ url: URL) {
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return }
            artwork = MPMediaItemArtwork(boundsSize: NSSize(width: 512, height: 512)) { _ in image }
            syncNowPlaying(force: true)
        }
    }

    // MARK: - 系统媒体键（MPRemoteCommandCenter）

    private enum Action {
        case play
        case pause
        case toggle
        case skip(Double)
        case seek(Double)
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.play) }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.pause) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.toggle) }
            return .success
        }
        // F7/F9：后退/前进（兼容“上一曲/下一曲”与“跳转”两种系统事件形态）
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.skip(-15)) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.skip(15)) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.skip(-15)) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.dispatch(.skip(15)) }
            return .success
        }
        // 控制中心拖动进度条
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? -1
            Task { @MainActor in self?.dispatch(.seek(seconds)) }
            return .success
        }
    }

    private func dispatch(_ action: Action) {
        guard let player, player.player != nil else { return }
        switch action {
        case .play:
            player.playIfPaused()
        case .pause:
            player.pauseIfPlaying()
        case .toggle:
            player.togglePlay()
        case .skip(let seconds):
            player.skip(by: seconds)
        case .seek(let seconds):
            guard seconds.isFinite, seconds >= 0 else { return }
            player.seek(to: seconds)
        }
        syncNowPlaying(force: true)
    }

    // MARK: - 标准功能键模式（F7/F8/F9 作为普通按键事件到达时）

    private func installFunctionKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }
            // 先取出纯值，再进隔离区；本地事件监视器与键盘分发都在主线程执行
            let type = event.type
            let keyCode = event.keyCode
            let isRepeat = event.isARepeat
            let handled = MainActor.assumeIsolated {
                self.handleLocalKey(type: type, keyCode: keyCode, isRepeat: isRepeat)
            }
            return handled ? nil : event
        }
    }

    /// 返回是否已消费该按键事件；消费时监视器吞掉事件，避免继续向下分发。
    private func handleLocalKey(type: NSEvent.EventType, keyCode: UInt16, isRepeat: Bool) -> Bool {
        switch (type, keyCode) {
        case (.keyDown, 98): // F7
            dispatch(.skip(-15))
            return true
        case (.keyDown, 100): // F8
            if !isRepeat {
                dispatch(.toggle)
            }
            return true
        case (.keyDown, 101): // F9
            f9KeyDown()
            return true
        case (.keyUp, 101):
            f9KeyUp()
            return true
        default:
            return false
        }
    }

    private func f9KeyDown() {
        guard !f9Down else { return }
        f9Down = true
        fastForwardActive = false
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.f9Down, !Task.isCancelled else { return }
            self.fastForwardActive = true
            self.player?.beginHoldFastForward()
        }
    }

    private func f9KeyUp() {
        guard f9Down else { return }
        f9Down = false
        holdTask?.cancel()
        holdTask = nil
        if fastForwardActive {
            fastForwardActive = false
            player?.endHoldFastForward()
        } else {
            player?.skip(by: 15)
        }
    }

    /// App 失去焦点时取消 F9 长按（避免错过 keyUp 导致倍速卡住）
    private func cancelF9Hold() {
        f9Down = false
        holdTask?.cancel()
        holdTask = nil
        if fastForwardActive {
            fastForwardActive = false
            player?.endHoldFastForward()
        }
    }
}
