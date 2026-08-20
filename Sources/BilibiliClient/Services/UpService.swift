import Foundation

struct UpService {
    /// UP 主个人信息（用户名片接口，无需 WBI）
    func info(mid: Int) async throws -> UpCardData {
        await APIClient.shared.ensureBuvid()
        return try await APIClient.shared.get("/x/web-interface/card", query: [
            "mid": "\(mid)",
            "photo": "false",
        ])
    }

    /// UP 主投稿视频
    func videos(mid: Int, page: Int = 1, pageSize: Int = 30) async throws -> UpVideosData {
        await APIClient.shared.ensureBuvid()
        return try await APIClient.shared.get("/x/space/wbi/arc/search", query: [
            "mid": "\(mid)",
            "pn": "\(page)",
            "ps": "\(pageSize)",
            "order": "pubdate",
        ], wbi: true)
    }
}
