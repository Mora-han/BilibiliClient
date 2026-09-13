import Foundation

struct SearchService {
    func videos(keyword: String, page: Int = 1, order: String = "totalrank") async throws -> SearchData {
        await APIClient.shared.ensureBuvid()
        return try await APIClient.shared.get("/x/web-interface/wbi/search/type", query: [
            "search_type": "video",
            "keyword": keyword,
            "order": order,
            "page": "\(page)",
            "page_size": "20",
        ], wbi: true)
    }
}
