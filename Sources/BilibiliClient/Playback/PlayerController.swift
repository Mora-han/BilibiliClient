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

    var currentQualityName: String? {
        guard let currentQualityId else { return nil }
        return qualities.first { $0.id == currentQualityId }?.name
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
            let data = try await service.playURLDASH(bvid: bvid, cid: cid, qn: quality.id)
            let granted = data.quality ?? quality.id
            currentQualityId = granted
            await play(bvid: bvid, cid: cid, qn: granted, dashFallback: data)
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
            let data = try await service.playURLDASH(bvid: bvid, cid: cid, qn: qn)
            qualities = Self.qualityOptions(from: data)
            let granted = data.quality ?? qualities.last?.id ?? qn
            currentQualityId = granted
            await play(bvid: bvid, cid: cid, qn: granted, dashFallback: data)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
        }
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
        player?.pause()
        player = nil
        proxy.stop()
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
