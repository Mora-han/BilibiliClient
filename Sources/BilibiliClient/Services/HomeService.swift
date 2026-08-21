import Foundation

struct HomeService {
    /// 当前热门视频
    func popular(page: Int = 1, pageSize: Int = 20) async throws -> PopularData {
        try await APIClient.shared.get("/x/web-interface/popular", query: [
            "pn": "\(page)",
            "ps": "\(pageSize)",
        ])
    }

    /// 分区排行榜（全站热门用 rid=0）
    func ranking(rid: Int = 0, type: String = "all") async throws -> RankingData {
        try await APIClient.shared.get("/x/web-interface/ranking/v2", query: [
            "rid": "\(rid)",
            "type": type,
        ])
    }

}
