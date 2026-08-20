import Foundation

struct LibraryService {
    /// 用户创建的收藏夹列表
    func favoriteFolders(mid: Int) async throws -> FavFolderData {
        try await APIClient.shared.get("/x/v3/fav/folder/created/list-all", query: [
            "up_mid": "\(mid)",
            "type": "2",
        ])
    }

    /// 收藏夹内容明细
    func favoriteResources(mediaId: Int, page: Int = 1, pageSize: Int = 20) async throws -> FavResourceData {
        try await APIClient.shared.get("/x/v3/fav/resource/list", query: [
            "media_id": "\(mediaId)",
            "pn": "\(page)",
            "ps": "\(pageSize)",
            "platform": "web",
        ])
    }

    /// 历史记录（IFS 翻页）
    func history(max: Int = 0, business: String = "", viewAt: Int = 0, pageSize: Int = 20) async throws -> HistoryData {
        try await APIClient.shared.get("/x/web-interface/history/cursor", query: [
            "type": "archive",
            "ps": "\(pageSize)",
            "max": "\(max)",
            "business": business,
            "view_at": "\(viewAt)",
        ])
    }

    /// 稍后再看列表
    func watchLater() async throws -> ToViewData {
        try await APIClient.shared.get("/x/v2/history/toview")
    }
}
