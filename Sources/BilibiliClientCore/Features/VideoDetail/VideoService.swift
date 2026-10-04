import Foundation

struct VideoService {
    func detail(bvid: String) async throws -> VideoDetailData {
        do {
            return try await APIClient.shared.get(
                "/x/web-interface/wbi/view/detail",
                query: ["bvid": bvid],
                wbi: true
            )
        } catch {
            // wbi 接口被风控时（返回 -352，解码时表现为 `data` 里没有 `View`），
            // 调试参数 `-legacyApi` 下退回老接口（老接口的 `data` 就是 view 字段本身）。
            guard PlayerDebugArgs.legacyAPI else { throw error }
            let legacy: LegacyData = try await APIClient.shared.get(
                "/x/web-interface/view",
                query: ["bvid": bvid]
            )
            return VideoDetailData(view: legacy.view, related: legacy.related)
        }
    }

    /// html5 平台：MP4 直链、无 Referer 防盗链限制。
    func playURLMP4(bvid: String, cid: Int, qn: Int = 64) async throws -> PlayURLData {
        try await APIClient.shared.get(
            PlayerDebugArgs.legacyAPI ? "/x/player/playurl" : "/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": "\(cid)",
                "qn": "\(qn)",
                "fnval": "1",
                "fourk": "1",
                "high_quality": "1",
                "platform": "html5",
            ],
            wbi: !PlayerDebugArgs.legacyAPI
        )
    }

    /// DASH 流（需要本地代理补 Referer/Cookie），返回清晰度列表。
    func playURLDASH(bvid: String, cid: Int, qn: Int = 80) async throws -> PlayURLData {
        try await APIClient.shared.get(
            PlayerDebugArgs.legacyAPI ? "/x/player/playurl" : "/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": "\(cid)",
                "qn": "\(qn)",
                "fnval": "16",
                "fourk": "1",
                "platform": "pc",
            ],
            wbi: !PlayerDebugArgs.legacyAPI
        )
    }

    /// 视频在线人数（web 端在线人数接口）。
    func onlineTotal(aid: Int, cid: Int) async throws -> VideoOnlineData {
        try await APIClient.shared.get(
            "/x/player/online/total",
            query: ["aid": "\(aid)", "cid": "\(cid)"]
        )
    }

    /// 视频 TAG 列表（旧版经典 TAG 接口）。
    func tags(aid: Int, bvid: String) async throws -> [VideoTagData] {
        try await APIClient.shared.get(
            "/x/tag/archive/tags",
            query: ["aid": "\(aid)", "bvid": bvid]
        )
    }
}

/// 视频在线人数（`data` 字段）。
struct VideoOnlineData: Decodable {
    /// 所有终端总计人数，如 "9.4万+"
    let total: String?
    /// web 端实时在线人数
    let count: String?
    /// 数据显示控制
    let showSwitch: ShowSwitch?

    struct ShowSwitch: Decodable {
        let total: Bool?
        let count: Bool?
    }
}

/// 视频 TAG（`data` 数组元素）。
struct VideoTagData: Decodable, Hashable, Identifiable {
    let tagId: Int
    let tagName: String

    var id: Int { tagId }
}

/// 老接口 `x/web-interface/view` 的 `data`（仅 `-legacyApi` 调试兜底用）：
/// view 的字段平铺在 data 上，`Related` 挂在同层（APIClient 已经把外层信封剥掉，
/// 这里解的就是 `data` 本身）。
private struct LegacyData: Decodable {
    let view: VideoDetailData.VideoView
    let related: [VideoDetailData.RelatedVideo]?

    private enum CodingKeys: String, CodingKey {
        case related = "Related"
    }

    init(from decoder: Decoder) throws {
        // 老接口把 view 的字段平铺在 data 上，直接用同一份 container 解 VideoView
        view = try VideoDetailData.VideoView(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        related = (try? container.decode([Lossy<VideoDetailData.RelatedVideo>].self, forKey: .related))?
            .compactMap { $0.value }
    }
}
