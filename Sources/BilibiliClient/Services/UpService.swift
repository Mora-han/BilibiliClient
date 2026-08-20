import Foundation

struct UpService {
    /// UP 主个人信息
    func info(mid: Int) async throws -> UpInfo {
        try await APIClient.shared.get("/x/space/wbi/acc/info", query: [
            "mid": "\(mid)",
        ], wbi: true)
    }

    /// UP 主投稿视频
    func videos(mid: Int, page: Int = 1, pageSize: Int = 30) async throws -> UpVideosData {
        try await APIClient.shared.get("/x/space/wbi/arc/search", query: [
            "mid": "\(mid)",
            "pn": "\(page)",
            "ps": "\(pageSize)",
            "order": "pubdate",
        ], wbi: true)
    }
}
