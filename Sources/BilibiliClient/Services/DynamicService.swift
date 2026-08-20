import Foundation

struct DynamicService {
    func feed(offset: String? = nil) async throws -> DynamicFeedData {
        var query: [String: String] = [
            "platform": "web",
            "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete",
        ]
        if let offset {
            query["offset"] = offset
        }
        return try await APIClient.shared.get(
            "/x/polymer/web-dynamic/v1/feed/all",
            query: query
        )
    }
}
