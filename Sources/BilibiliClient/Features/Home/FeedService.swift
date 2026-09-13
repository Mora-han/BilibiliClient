import Foundation

struct FeedService {
    func recommend(page: Int = 1, pageSize: Int = 24) async throws -> [RecommendItem] {
        struct Payload: Decodable {
            let item: [RecommendItem]
        }

        let payload: Payload = try await APIClient.shared.get(
            "/x/web-interface/wbi/index/top/feed/rcmd",
            query: [
                "ps": "\(pageSize)",
                "fresh_idx": "\(page)",
                "fresh_idx_1h": "\(page)",
                "fresh_type": "4",
                "brush": "\(page)",
                "feed_version": "V8",
                "homepage_ver": "1",
                "web_location": "1430650",
                "y_num": "5",
            ],
            wbi: true
        )
        return payload.item.filter { !$0.bvid.isEmpty }
    }
}
