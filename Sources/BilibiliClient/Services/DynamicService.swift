import Foundation

struct DynamicService {
    func feed(offset: String? = nil) async throws -> DynamicFeedData {
        var query = ["timezone_offset": "-480"]
        if let offset {
            query["offset"] = offset
        }
        return try await APIClient.shared.get(
            "/x/polymer/web-dynamic/v1/feed/all",
            query: query
        )
    }
}
