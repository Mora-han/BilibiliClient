import Foundation

struct RelationService {
    /// 用户关注列表
    func followings(mid: Int, page: Int = 1, pageSize: Int = 50) async throws -> FollowingsData {
        try await APIClient.shared.get("/x/relation/followings", query: [
            "vmid": "\(mid)",
            "pn": "\(page)",
            "ps": "\(pageSize)",
        ])
    }
}
