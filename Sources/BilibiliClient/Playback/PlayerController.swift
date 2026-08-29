import AVFoundation
import Foundation

@MainActor
final class PlayerController: ObservableObject {
    /// 应用内同时只允许一个视频播放器工作，避免导航切换时旧页面仍有声音。
    private static weak var activeController: PlayerController?
    @Published var player: AVPlayer?
    @Published var state: LoadState = .idle
    @Published var errorMessage: String?
    @Published var qualities: [Quality] = []
    @Published var currentQualityId: Int?
    /// 控制条展示用：当前播放时间 / 总时长 / 播放状态
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false

    enum LoadState {
        case idle
        case loading
        case ready
        case failed
    }

    struct Quality: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    private let proxy = HLSProxy.shared
    private let service = VideoService()
    private var aid = 0
    private var bvid = ""
    private var cid = 0
    private var loadedKey: String?
    private var reportTask: Task<Void, Never>?
    /// 当前播放流地址：大幅 seek 后自动刷新播放状态时，用同一地址重建播放条目。
    private var currentStreamURL: URL?
    /// 控制条时间/状态观察者
    private var playbackObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    /// 自愈保险：播放中时间停滞超过该秒数视为解码卡住，自动重建播放条目
    private static let stallThreshold: Double = 2.0
    /// 两次自愈之间的最小间隔，避免反复重建打断观看
    private static let recoveryCooldown: Double = 8.0
    private var lastProgressTime: Double = 0
    private var stallStart: Double?
    private var lastRecoveryAt: Double = -10
    private var isRecovering = false
    private var recoveryTask: Task<Void, Never>?

    var currentQualityName: String? {
        guard let currentQualityId else { return nil }
        return qualities.first { $0.id == currentQualityId }?.name
    }

    // MARK: - 控制条操作

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    func skip(by seconds: Double) {
        guard let player else { return }
        let target = player.currentTime().seconds + seconds
        seek(to: max(target, 0))
    }

    func setVolume(_ value: Double) {
        player?.volume = Float(value)
    }

    func load(aid: Int, bvid: String, cid: Int) async {
        let key = "\(bvid):\(cid)"
        if Self.activeController !== self {
            Self.activeController?.stop()
            Self.activeController = self
        }
        guard loadedKey != key else { return }
        loadedKey = key
        self.aid = aid
        self.bvid = bvid
        self.cid = cid
        await resetAndLoad(qn: 80)
    }

    func retry(aid: Int, bvid: String, cid: Int) async {
        loadedKey = nil
        await load(aid: aid, bvid: bvid, cid: cid)
    }

    func selectQuality(_ quality: Quality) async {
        guard !bvid.isEmpty else { return }
        state = .loading
        errorMessage = nil
        teardownPlayer()
        do {
            try await loadDASH(qn: quality.id, updateQualities: false)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        reportTask?.cancel()
        reportTask = nil
        if let player, bvid != "" {
            let seconds = player.currentTime().seconds
            if seconds.isFinite, seconds > 0 {
                Task {
                    await HistoryReporter.report(aid: aid, cid: cid, progress: Int(seconds))
                }
            }
        }
        teardownPlayer()
        loadedKey = nil
        state = .idle
        if Self.activeController === self {
            Self.activeController = nil
        }
    }

    // MARK: - Private

    private func resetAndLoad(qn: Int) async {
        state = .loading
        errorMessage = nil
        teardownPlayer()
        do {
            try await loadDASH(qn: qn, updateQualities: true)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
        }
    }

    /// 拉取 DASH 播放地址并按指定清晰度开播；共用于初次加载与清晰度切换。
    private func loadDASH(qn: Int, updateQualities: Bool) async throws {
        let data = try await service.playURLDASH(bvid: bvid, cid: cid, qn: qn)
        if updateQualities {
            qualities = Self.qualityOptions(from: data)
        }
        let granted = data.quality ?? qualities.last?.id ?? qn
        currentQualityId = granted
        await play(bvid: bvid, cid: cid, qn: granted, dashFallback: data)
    }

    /// 播放：优先 MP4 直链（已验证稳定），拿不到再走 DASH 本地代理。
    /// 注意：html5 平台 MP4 最高只有 1080P，4K/HDR/1080P60 必须走 DASH。
    private func play(bvid: String, cid: Int, qn: Int, dashFallback: PlayURLData) async {
        // 1. MP4（仅 1080P 及以下）
        if qn <= 80,
           let mp4 = try? await service.playURLMP4(bvid: bvid, cid: cid, qn: qn),
           let first = mp4.durl?.first,
           let url = URL(string: first.url.replacingOccurrences(of: "http://", with: "https://")) {
            let asset = AVURLAsset(url: url, options: httpAssetOptions())
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player?.automaticallyWaitsToMinimizeStalling = true
            player?.play()
            currentStreamURL = url
            startPlaybackMonitoring()
            state = .ready
            startReportLoop()
            return
        }

        // 2. DASH 降级
        if let dashError = await startDASH(dashFallback, preferredQuality: qn) {
            // 3. 在线流式兜底：本地代理直接转发 CDN 字节流（无需 sidx）
            if await tryProgressiveStreaming(dashFallback, preferredQuality: qn) {
                state = .ready
            } else {
                state = .failed
                errorMessage = "该视频暂不支持在此客户端播放（DASH：\(dashError)）"
            }
        } else {
            state = .ready
        }
    }

    /// 返回 nil 表示成功；否则返回失败原因。
    private func startDASH(_ data: PlayURLData, preferredQuality: Int?) async -> String? {
        guard let dash = data.dash else { return "无 DASH 流" }
        guard let video = Self.pickVideo(dash.video ?? [], preferredQuality: preferredQuality ?? data.quality),
              let audio = dash.audio?.first else {
            return "缺少音视频流"
        }
        // 以实际拉到的视频流为准（服务器降级时如实显示清晰度）
        currentQualityId = video.id
        do {
            let videoMedia = try await Self.makeMedia(from: video)
            let audioMedia = try await Self.makeMedia(from: audio)
            let url = try await proxy.start(video: videoMedia, audio: audioMedia)
            player = AVPlayer(url: url)
            player?.automaticallyWaitsToMinimizeStalling = true
            player?.play()
            currentStreamURL = url
            startPlaybackMonitoring()
            startReportLoop()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 每 15 秒上报一次观看进度（播放中才报），播完上报最终进度。
    private func startReportLoop() {
        reportTask?.cancel()
        reportTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                guard let player = self.player,
                      player.timeControlStatus == .playing else { continue }
                let seconds = player.currentTime().seconds
                guard seconds.isFinite, seconds > 0 else { continue }
                await HistoryReporter.report(aid: self.aid, cid: self.cid, progress: Int(seconds))

                if let duration = player.currentItem?.duration.seconds,
                   duration.isFinite, seconds >= duration - 2 {
                    await HistoryReporter.report(aid: self.aid, cid: self.cid, progress: Int(duration))
                    break
                }
            }
        }
    }

    private func teardownPlayer() {
        stopPlaybackMonitoring()
        player?.pause()
        player = nil
        proxy.stop()
        currentStreamURL = nil
    }

    // MARK: - 播放监控与自愈保险

    /// 播放监控：0.25s 采样一次播放时间，驱动控制条数据；
    /// 同时检测「播放中时间停滞」异常，触发按需自愈刷新，正常观看无感。
    private func startPlaybackMonitoring() {
        stopPlaybackMonitoring()
        guard let player else { return }
        playbackObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                self?.tickPlaybackHealth(time: seconds)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = playing
                if !playing {
                    // 暂停/缓冲：清掉停滞计时，避免把正常等待误判为卡住
                    self?.stallStart = nil
                }
            }
        }
        durationObservation = player.currentItem?.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            let d = item.duration.seconds
            Task { @MainActor in
                self?.duration = d.isFinite ? d : 0
            }
        }
        if let d = player.currentItem?.duration.seconds, d.isFinite {
            duration = d
        }
    }

    private func stopPlaybackMonitoring() {
        if let playbackObserver, let player {
            player.removeTimeObserver(playbackObserver)
        }
        playbackObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        isRecovering = false
        lastProgressTime = 0
        stallStart = nil
    }

    /// 每次采样回调：更新控制条时间，并执行自愈检查。
    private func tickPlaybackHealth(time: Double) {
        currentTime = time
        guard time.isFinite, time >= 0 else { return }
        guard let player, player.timeControlStatus == .playing else { return }

        // 时间前进 → 正常；时间停滞（解码卡住）累计超过阈值 → 自愈
        if time - lastProgressTime > 0.001 {
            lastProgressTime = time
            stallStart = nil
        } else if stallStart == nil {
            stallStart = time
        } else if time - (stallStart ?? time) >= Self.stallThreshold {
            triggerRecovery(to: time)
        }
    }

    /// 触发一次自愈（带冷却，避免反复重建打断观看）。
    private func triggerRecovery(to target: Double) {
        guard !isRecovering else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastRecoveryAt >= Self.recoveryCooldown else { return }
        lastRecoveryAt = now
        isRecovering = true
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRecovery(to: target)
            self.isRecovering = false
        }
    }

    /// 用同一流地址重建播放条目并回到目标时间，保持原播放/暂停状态。
    private func performRecovery(to target: Double) async {
        recoveryTask = nil
        guard let player, let url = currentStreamURL else {
            isRecovering = false
            return
        }
        let wasPlaying = player.timeControlStatus == .playing
        player.pause()
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: httpAssetOptions()))
        player.replaceCurrentItem(with: item)
        startPlaybackMonitoring()
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        if wasPlaying {
            player.play()
        }
    }

    /// 在线流式兜底：通过本地代理把 CDN 字节流持续转发给 AVPlayer，
    /// 边下边播，不需要 sidx，也不需要整文件下载。
    private func tryProgressiveStreaming(_ data: PlayURLData, preferredQuality: Int?) async -> Bool {
        guard let dash = data.dash,
              let stream = Self.pickVideo(dash.video ?? [], preferredQuality: preferredQuality ?? data.quality),
              let url = URL(string: stream.baseUrl.replacingOccurrences(of: "http://", with: "https://")) else {
            return false
        }
        do {
            let streamURL = try await proxy.startProgressive(baseURL: url)
            player = AVPlayer(url: streamURL)
            player?.automaticallyWaitsToMinimizeStalling = true
            player?.play()
            currentStreamURL = streamURL
            startPlaybackMonitoring()
            return true
        } catch {
            return false
        }
    }

    private static func qualityOptions(from data: PlayURLData) -> [Quality] {
        let ids = data.acceptQuality ?? []
        let names = data.acceptDescription ?? []
        var seen = Set<Int>()
        return zip(ids, names)
            .compactMap { id, name in
                guard seen.insert(id).inserted else { return nil }
                return Quality(id: id, name: name)
            }
            .sorted { $0.id > $1.id }
    }

    /// 优先取指定清晰度；拿不到时取不高于它的最高档；再不行取 AVC 编码流。
    private static func pickVideo(_ streams: [PlayURLData.DashStream],
                                  preferredQuality: Int?) -> PlayURLData.DashStream? {
        let withSegment = streams.filter { $0.segmentBase != nil }
        let avc = withSegment.filter { $0.codecs?.hasPrefix("avc1") ?? false }
        let candidates = avc.isEmpty ? withSegment : avc
        if let preferred = preferredQuality {
            if let match = candidates.first(where: { $0.id == preferred }) {
                return match
            }
            // 降级：取不高于目标清晰度的最高档（避免挑到最低档）
            let lower = candidates.filter { $0.id <= preferred }.sorted { $0.id > $1.id }
            if let fallback = lower.first {
                return fallback
            }
        }
        return candidates.sorted { $0.id > $1.id }.first
    }

    private func httpAssetOptions() -> [String: Any] {
        var cookies: [HTTPCookie] = []
        func addCookie(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            for domain in [".bilibili.com", ".bilivideo.com"] {
                if let cookie = HTTPCookie(properties: [
                    .domain: domain,
                    .path: "/",
                    .name: name,
                    .value: value,
                ]) {
                    cookies.append(cookie)
                }
            }
        }
        let stored = APIClient.shared.cookies
        addCookie("SESSDATA", stored.sessdata)
        addCookie("bili_jct", stored.biliJct)
        addCookie("DedeUserID", stored.dedeUserID)
        return [AVURLAssetHTTPCookiesKey: cookies]
    }

    /// 在整个数据里搜索 "sidx" 特征字节并尝试解析，避开盒子跳转被截断的问题。
    private static func parseSIDXBySearching(_ data: Data, absoluteRangeStart: Int) -> [MediaSegment]? {
        let pattern = Data("sidx".utf8)
        var searchFrom = 0
        while let found = data.range(of: pattern, options: [], in: searchFrom..<data.count) {
            let offset = found.lowerBound
            // 四字节对齐才可能是盒子类型
            if offset % 4 == 0,
               let segments = SIDXParser.parse(data.subdata(in: offset..<data.count),
                                               absoluteRangeStart: absoluteRangeStart + offset) {
                return segments
            }
            searchFrom = found.lowerBound + 1
        }
        return nil
    }

    private static func makeMedia(from stream: PlayURLData.DashStream) async throws -> HLSProxy.Media {
        guard let segmentBase = stream.segmentBase,
              let url = URL(string: stream.baseUrl.replacingOccurrences(of: "http://", with: "https://")) else {
            throw APIError.invalidResponse
        }

        let initParts = segmentBase.initialization.split(separator: "-")
        let indexParts = segmentBase.indexRange.split(separator: "-")
        guard initParts.count == 2, indexParts.count == 2,
              let initStart = Int(initParts[0]),
              let initEnd = Int(initParts[1]),
              let indexStart = Int(indexParts[0]),
              let indexEnd = Int(indexParts[1]) else {
            throw APIError.invalidResponse
        }

        let (initData, _) = try await APIClient.shared.streamData(from: url, range: "\(initStart)-\(initEnd)")
        let timescale = MP4FragmentParser.timescale(inInit: initData)

        // 方案 1：sidx（小范围 + 大窗口 + 从头扫，兼容 ftyp/styp 前缀）
        var segments = try await Self.parseSIDX(url: url,
                                                indexStart: indexStart,
                                                indexEnd: indexEnd)

        // 方案 2：没有 sidx 时，直接枚举 moof/mdat 分片（不依赖 sidx）
        if segments == nil, let timescale {
            let ts = Double(timescale)
            segments = try await Self.enumerateFragments(url: url, start: indexStart, timescale: ts)
            if segments == nil {
                // index_range 可能指向错误位置（例如服务器忽略 Range 返回了文件头），从头扫
                segments = try await Self.enumerateFragments(url: url, start: 0, timescale: ts)
            }
        }

        guard let segments else {
            throw APIError.biz(code: -1, message: "无法解析视频分片（DASH：sidx 与 moof 枚举均失败，index_range \(indexStart)-\(indexEnd)）")
        }

        return HLSProxy.Media(
            baseURL: url,
            initRange: "\(initStart)-\(initEnd)",
            segments: segments,
            bandwidth: stream.bandwidth,
            codecs: stream.codecs,
            width: stream.width,
            height: stream.height
        )
    }

    /// 尝试从 index_range 与多个窗口里解析 sidx。
    private static func parseSIDX(url: URL, indexStart: Int, indexEnd: Int) async throws -> [MediaSegment]? {
        // 部分流的分片自带 ftyp/styp 前缀，index_range 只是分片起点，
        // sidx 可能在小范围之外，因此用小范围 + 大窗口两种方式尝试。
        if let (sidxData, _) = try? await APIClient.shared.streamData(from: url, range: "\(indexStart)-\(indexEnd)"),
           let segments = SIDXParser.parse(sidxData, absoluteRangeStart: indexStart) {
            return segments
        }

        // 从分片起点拉 8MB 大窗口
        let windowEnd = indexStart + 8 * 1024 * 1024 - 1
        if let (wide, _) = try? await APIClient.shared.streamData(from: url, range: "\(indexStart)-\(windowEnd)") {
            if let segments = Self.parseSIDXBySearching(wide, absoluteRangeStart: indexStart) {
                return segments
            }
            if let segments = SIDXParser.parse(wide, absoluteRangeStart: indexStart) {
                return segments
            }
        }

        // Range 可能被忽略：从文件头拉大窗口
        if let (fromZero, _) = try? await APIClient.shared.streamData(from: url, range: "0-\(windowEnd)") {
            if let segments = Self.parseSIDXBySearching(fromZero, absoluteRangeStart: 0) {
                return segments
            }
            if let segments = SIDXParser.parse(fromZero, absoluteRangeStart: 0) {
                return segments
            }
        }
        return nil
    }

    /// 不依赖 sidx 的分片枚举：每次只拉一个分片的 moof/mdat 头（小窗口），
    /// 依边界顺序跳跃前进；416 表示已到文件末尾。
    private static func enumerateFragments(url: URL,
                                           start: Int,
                                           timescale: Double) async throws -> [MediaSegment]? {
        var fragments: [MP4Fragment] = []
        var next = start
        var window = 1 * 1024 * 1024
        var fetches = 0
        var hitCap = false
        let maxFetches = 2000

        while fetches < maxFetches {
            let chunk: Data
            do {
                (chunk, _) = try await APIClient.shared.streamData(from: url, range: "\(next)-\(next + window - 1)")
            } catch let error as APIError {
                if case .http(416) = error { break }
                throw error
            }
            if chunk.isEmpty { break }
            fetches += 1

            let result = MP4FragmentParser.parseFragments(buffer: chunk,
                                                          start: 0,
                                                          timescale: timescale,
                                                          baseOffset: next)
            if let last = result.fragments.last {
                // 只保留时长合理（>0 且 <= 120s）的分片，异常结构直接判定失败
                for f in result.fragments where !(f.duration > 0 && f.duration <= 120) {
                    return nil
                }
                fragments += result.fragments
                next = last.moofOffset + last.size
                window = 1 * 1024 * 1024
                continue
            }
            if result.needsMore, window < 8 * 1024 * 1024 {
                window *= 2
                continue
            }
            break
        }
        hitCap = fetches >= maxFetches

        guard !fragments.isEmpty else { return nil }
        if hitCap {
            // 枚举到上限仍未到文件尾，避免播放中途截断，直接报错
            throw APIError.biz(code: -1, message: "无法解析视频分片（DASH：分片数量超过枚举上限）")
        }
        return fragments.map {
            MediaSegment(range: "\($0.moofOffset)-\($0.moofOffset + $0.size - 1)",
                         duration: $0.duration)
        }
    }
}
