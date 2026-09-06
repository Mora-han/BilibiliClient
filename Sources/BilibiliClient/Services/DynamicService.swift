import Foundation

struct DynamicService {
    private static let features = "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete"

    func feed(offset: String? = nil, hostMid: Int? = nil) async throws -> DynamicFeedData {
        var query: [String: String] = [
            "platform": "web",
            "features": Self.features,
        ]
        if let offset {
            query["offset"] = offset
        }
        if let hostMid {
            query["host_mid"] = "\(hostMid)"
        }
        return try await APIClient.shared.get(
            "/x/polymer/web-dynamic/v1/feed/all",
            query: query
        )
    }

    /// 动态详情：返回与动态流相同结构的 item。
    func detail(id: String) async throws -> DynamicDetailData {
        try await APIClient.shared.get("/x/polymer/web-dynamic/v1/detail", query: [
            "id": id,
            "timezone_offset": "-480",
            "platform": "web",
            "features": Self.features,
        ])
    }
}
