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

    func addToWatchLater(aid: Int, bvid: String? = nil) async throws {
        var form = ["csrf": APIClient.shared.cookies.biliJct ?? ""]
        form["aid"] = "\(aid)"
        if let bvid { form["bvid"] = bvid }
        try await APIClient.shared.postForm(path: "/x/v2/history/toview/add", form: form)
    }

    func removeFromWatchLater(aid: Int) async throws {
        try await APIClient.shared.postForm(path: "/x/v2/history/toview/del", form: ["aid": "\(aid)", "csrf": APIClient.shared.cookies.biliJct ?? ""])
    }

    func removeHistory(aid: Int) async throws {
        try await APIClient.shared.postForm(path: "/x/v2/history/delete", form: ["kid": "archive_\(aid)", "csrf": APIClient.shared.cookies.biliJct ?? ""])
    }

    func removeFavorite(aid: Int, folderId: Int) async throws {
        try await APIClient.shared.postForm(path: "/x/v3/fav/resource/deal", form: ["rid": "\(aid)", "type": "2", "del_media_ids": "\(folderId)", "platform": "web", "csrf": APIClient.shared.cookies.biliJct ?? ""])
    }
}
