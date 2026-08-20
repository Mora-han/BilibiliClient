import AVFoundation
import Foundation

@MainActor
final class PlayerController: ObservableObject {
    @Published var player: AVPlayer?
    @Published var state: LoadState = .idle
    @Published var errorMessage: String?

    enum LoadState {
        case idle
        case loading
        case ready
        case failed
    }

    private let proxy = HLSProxy.shared
    private var loadedKey: String?

    func load(bvid: String, cid: Int) async {
        let key = "\(bvid):\(cid)"
        guard loadedKey != key else { return }
        loadedKey = key

        player?.pause()
        player = nil
        state = .loading
        errorMessage = nil

        do {
            let service = VideoService()

            // 1. 优先 MP4 直链（html5 平台无 Referer 防盗链）
            let mp4 = try await service.playURLMP4(bvid: bvid, cid: cid)
            if let first = mp4.durl?.first,
               let url = URL(string: first.url.replacingOccurrences(of: "http://", with: "https://")) {
                let asset = AVURLAsset(url: url, options: httpAssetOptions())
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player?.automaticallyWaitsToMinimizeStalling = true
                state = .ready
                return
            }

            // 2. 降级 DASH：本地代理转 HLS
            let dash = try await service.playURLDASH(bvid: bvid, cid: cid)
            guard let dashData = dash.dash,
                  let videoStream = Self.pickVideo(dashData.video ?? []),
                  let audioStream = dashData.audio?.first else {
                throw APIError.biz(code: -1, message: "该视频暂不支持在此客户端播放")
            }

            let videoMedia = try await Self.makeMedia(from: videoStream)
            let audioMedia = try await Self.makeMedia(from: audioStream)
            let url = try proxy.start(video: videoMedia, audio: audioMedia)
            player = AVPlayer(url: url)
            player?.automaticallyWaitsToMinimizeStalling = true
            state = .ready
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

    func retry(bvid: String, cid: Int) async {
        loadedKey = nil
        await load(bvid: bvid, cid: cid)
    }

    // MARK: - Helpers

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

    private static func pickVideo(_ streams: [PlayURLData.DashStream]) -> PlayURLData.DashStream? {
        let avc = streams.filter { $0.codecs?.hasPrefix("avc1") ?? false }
        let candidates = avc.isEmpty ? streams : avc
        return candidates
            .sorted { $0.id > $1.id }
            .first { $0.id <= 80 } ?? candidates.first
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
