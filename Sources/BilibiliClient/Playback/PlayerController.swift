import AVFoundation
import Foundation

@MainActor
final class PlayerController: ObservableObject {
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
    private var bvid = ""
    private var cid = 0
    private var loadedKey: String?

    var currentQualityName: String? {
        guard let currentQualityId else { return nil }
        return qualities.first { $0.id == currentQualityId }?.name
    }

    func load(bvid: String, cid: Int) async {
        let key = "\(bvid):\(cid)"
        guard loadedKey != key else { return }
        loadedKey = key
        self.bvid = bvid
        self.cid = cid
        await resetAndLoad(qn: 80)
    }

    func retry(bvid: String, cid: Int) async {
        loadedKey = nil
        await load(bvid: bvid, cid: cid)
    }

    func selectQuality(_ quality: Quality) async {
        guard !bvid.isEmpty else { return }
        state = .loading
        errorMessage = nil
        player?.pause()
        player = nil
        proxy.stop()
        do {
            let data = try await service.playURLDASH(bvid: bvid, cid: cid, qn: quality.id)
            currentQualityId = data.quality ?? quality.id
            await startPlayback(data, preferredQuality: currentQualityId)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        player?.pause()
        player = nil
        proxy.stop()
    }

    // MARK: - Private

    private func resetAndLoad(qn: Int) async {
        state = .loading
        errorMessage = nil
        player?.pause()
        player = nil
        proxy.stop()
        do {
            let data = try await service.playURLDASH(bvid: bvid, cid: cid, qn: qn)
            qualities = Self.qualityOptions(from: data)
            currentQualityId = data.quality ?? qualities.last?.id ?? qn
            await startPlayback(data, preferredQuality: currentQualityId)
        } catch {
            state = .failed
            errorMessage = error.localizedDescription
        }
    }

    private func startPlayback(_ data: PlayURLData, preferredQuality: Int?) async {
        // 优先 DASH：选中目标清晰度对应的视频流，本地代理转 HLS
        if let dash = data.dash {
            let streams = dash.video ?? []
            if let video = Self.pickVideo(streams, preferredQuality: preferredQuality ?? data.quality),
               let audio = dash.audio?.first {
                do {
                    let videoMedia = try await Self.makeMedia(from: video)
                    let audioMedia = try await Self.makeMedia(from: audio)
                    let url = try proxy.start(video: videoMedia, audio: audioMedia)
                    player = AVPlayer(url: url)
                    player?.automaticallyWaitsToMinimizeStalling = true
                    state = .ready
                    return
                } catch {
                    // 代理失败时降级 MP4
                }
            }
        }

        // 降级：MP4 直链
        if let first = data.durl?.first,
           let url = URL(string: first.url.replacingOccurrences(of: "http://", with: "https://")) {
            let asset = AVURLAsset(url: url, options: httpAssetOptions())
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player?.automaticallyWaitsToMinimizeStalling = true
            state = .ready
            return
        }

        state = .failed
        errorMessage = "该视频暂不支持在此客户端播放"
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
        let avc = streams.filter { $0.codecs?.hasPrefix("avc1") ?? false }
        let candidates = avc.isEmpty ? streams : avc
        if let preferred = preferredQuality {
            if let match = candidates.first(where: { $0.id == preferred }) {
                return match
            }
            if let granted = candidates.first(where: { $0.id <= preferred }) {
                return granted
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

        let (sidxData, _) = try await APIClient.shared.streamData(
            from: url,
            range: "\(indexStart)-\(indexEnd)"
        )
        guard let segments = SIDXParser.parse(sidxData, absoluteRangeStart: indexStart) else {
            throw APIError.biz(code: -1, message: "无法解析视频分片（DASH）")
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
}
