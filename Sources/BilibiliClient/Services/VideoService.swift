import Foundation

struct VideoService {
    func detail(bvid: String) async throws -> VideoDetailData {
        try await APIClient.shared.get(
            "/x/web-interface/wbi/view/detail",
            query: ["bvid": bvid],
            wbi: true
        )
    }

    /// html5 平台：MP4 直链、无 Referer 防盗链限制。
    func playURLMP4(bvid: String, cid: Int) async throws -> PlayURLData {
        try await APIClient.shared.get(
            "/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": "\(cid)",
                "qn": "64",
                "fnval": "1",
                "fourk": "1",
                "high_quality": "1",
                "platform": "html5",
            ],
            wbi: true
        )
    }

    /// DASH 流（用于 MP4 不可用时降级，需要本地代理补 Referer/Cookie）。
    func playURLDASH(bvid: String, cid: Int) async throws -> PlayURLData {
        try await APIClient.shared.get(
            "/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": "\(cid)",
                "qn": "80",
                "fnval": "16",
                "fourk": "1",
                "platform": "pc",
            ],
            wbi: true
        )
    }
}
