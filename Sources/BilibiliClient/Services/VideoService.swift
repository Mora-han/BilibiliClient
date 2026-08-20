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
    func playURLMP4(bvid: String, cid: Int, qn: Int = 64) async throws -> PlayURLData {
        try await APIClient.shared.get(
            "/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": "\(cid)",
                "qn": "\(qn)",
                "fnval": "1",
                "fourk": "1",
                "high_quality": "1",
                "platform": "html5",
            ],
            wbi: true
        )
    }

    /// DASH 流（需要本地代理补 Referer/Cookie），返回清晰度列表。
    func playURLDASH(bvid: String, cid: Int, qn: Int = 80) async throws -> PlayURLData {
        try await APIClient.shared.get(
            "/x/player/wbi/playurl",
            query: [
                "bvid": bvid,
                "cid": "\(cid)",
                "qn": "\(qn)",
                "fnval": "16",
                "fourk": "1",
                "platform": "pc",
            ],
            wbi: true
        )
    }
}
