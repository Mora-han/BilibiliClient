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

    /// UP 主投稿视频（关键词接口，空关键词=全部投稿，无风控）
    /// order: pubdate=最新发布 / views=最多播放
    func videos(mid: Int, page: Int = 1, pageSize: Int = 30, order: String = "pubdate") async throws -> RecArchivesData {
        await APIClient.shared.ensureBuvid()
        return try await APIClient.shared.get("/x/series/recArchivesByKeywords", query: [
            "mid": "\(mid)",
            "keywords": "",
            "ps": "\(pageSize)",
            "pn": "\(page)",
            "orderby": order,
        ])
    }
}
