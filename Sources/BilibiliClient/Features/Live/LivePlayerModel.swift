import AVFoundation
import Foundation

/// 直播播放器：拉取 HLS 播放流并用 AVPlayer 直连播放。
/// 与视频 PlayerController 解耦（视频走 DASH/代理，直播是 HLS 直连），
/// 只负责直播房间的流地址解析、播放状态与在线人数文本。
@MainActor
final class LivePlayerModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case offline
        case failed
    }

    @Published var player: AVPlayer?
    @Published var state: LoadState = .idle
    @Published var errorMessage: String?
    @Published var isPlaying = false
    /// 观看人数文本（如 "5675.7万"），房间信息拉取后写入
    @Published var onlineText: String?

    private let service = LiveService()
    private var roomId = 0
    private var loadedKey: String?
    private var timeControlObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?

    var isLive: Bool { state == .ready || state == .loading }

    /// 加载直播间并开播。幂等：同一房间已就绪时不重复建流。
    func load(roomId: Int) async {
        let key = "\(roomId)"
        guard loadedKey != key else { return }
        loadedKey = key
        self.roomId = roomId
        await resetAndLoad()
    }

    func retry(roomId: Int) async {
        loadedKey = nil
        await load(roomId: roomId)
    }

    /// 重试当前房间（画面中断后由播放窗口内的重试按钮调用）。
    func retryCurrent() async {
        guard roomId > 0 else { return }
        loadedKey = nil
        await resetAndLoad()
    }

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// 更新在线人数展示（由页面在拿到房间信息后调用）。
    func updateOnlineText(_ text: String?) {
        onlineText = text
    }

    func stop() {
        teardownPlayer()
        loadedKey = nil
        state = .idle
        errorMessage = nil
        onlineText = nil
    }

    // MARK: - 播放控制

    private func resetAndLoad() async {
        state = .loading
        errorMessage = nil
        teardownPlayer()
        do {
            let info = try await service.playInfo(roomId: roomId)
            guard info.liveStatus != 0 else {
                state = .offline
                return
            }
            guard let url = Self.pickStreamURL(from: info) else {
                state = .failed
                errorMessage = "暂时没有可用的直播流"
                return
            }
            let asset = AVURLAsset(url: url, options: httpAssetOptions())
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            player.isMuted = false
            self.player = player
            observe(player)
            player.play()
            state = .ready
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
        }
    }

    /// 挑选 HLS 直链：优先 http_hls + avc（ts 优先于 fmp4），不选 FLV。
    private static func pickStreamURL(from info: LivePlayInfoData) -> URL? {
        guard let streams = info.playurlInfo?.playurl?.stream else { return nil }
        for protocolName in ["http_hls"] {
            for stream in streams where stream.protocolName == protocolName {
                guard let formats = stream.format else { continue }
                for formatName in ["ts", "fmp4"] {
                    guard let format = formats.first(where: { $0.formatName == formatName }),
                          let codecs = format.codec else { continue }
                    guard let codec = codecs.first(where: { $0.codecName == "avc" })
                            ?? codecs.first else { continue }
                    guard let base = codec.baseUrl,
                          let urlInfo = codec.urlInfo?.first,
                          let host = urlInfo.host,
                          let extra = urlInfo.extra,
                          let url = URL(string: host + base + extra) else { continue }
                    return url
                }
            }
        }
        return nil
    }

    /// HLS 分片请求带上直播 Referer，避免 CDN 拒播。
    private func httpAssetOptions() -> [String: Any] {
        [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Referer": "https://live.bilibili.com",
                "User-Agent": APIConstants.userAgent,
            ],
        ]
    }

    private func observe(_ player: AVPlayer) {
        timeControlObservation?.invalidate()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
        statusObservation?.invalidate()
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                guard let self, failed, self.player?.currentItem === item else { return }
                self.state = .failed
                self.errorMessage = item.error?.localizedDescription ?? "直播播放失败"
            }
        }
    }

    private func teardownPlayer() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        isPlaying = false
    }
}
