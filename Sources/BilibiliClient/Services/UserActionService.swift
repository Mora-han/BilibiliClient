import Foundation

/// 点赞 / 投币 / 收藏 / 分享
struct UserActionService {
    private static var cachedDefaultFolderId: Int?

    func like(aid: Int, bvid: String? = nil, liked: Bool) async throws {
        await APIClient.shared.ensureBuvid()
        var form: [String: String] = [
            "aid": "\(aid)",
            "like": liked ? "1" : "2",
            "csrf": csrf(),
        ]
        if let bvid, !bvid.isEmpty { form["bvid"] = bvid }
        try await APIClient.shared.postForm(path: "/x/web-interface/archive/like", form: form)
    }

    func coin(aid: Int, multiply: Int) async throws {
        await APIClient.shared.ensureBuvid()
        try await APIClient.shared.postForm(path: "/x/web-interface/coin/add", form: [
            "aid": "\(aid)",
            "multiply": "\(multiply)",
            "select_like": "0",
            "csrf": csrf(),
        ])
    }

    func favorite(aid: Int, faved: Bool) async throws {
        let folderId = try await defaultFolderId()
        var form: [String: String] = [
            "rid": "\(aid)",
            "type": "2",
            "csrf": csrf(),
            "platform": "web",
        ]
        if faved {
            form["add_media_ids"] = "\(folderId)"
        } else {
            form["del_media_ids"] = "\(folderId)"
        }
        try await APIClient.shared.postForm(path: "/x/v3/fav/resource/deal", form: form)
    }

    func favorite(aid: Int, folderId: Int) async throws {
        try await APIClient.shared.postForm(path: "/x/v3/fav/resource/deal", form: ["rid": "\(aid)", "type": "2", "add_media_ids": "\(folderId)", "del_media_ids": "", "platform": "web", "csrf": csrf()])
    }

    func favoriteFolders() async throws -> [FavFolder] {
        guard let mid = APIClient.shared.cookies.dedeUserID.flatMap({ Int($0) }) else { throw APIError.biz(code: -101, message: "账号未登录") }
        return try await LibraryService().favoriteFolders(mid: mid).list ?? []
    }

    func hasLiked(aid: Int) async throws -> Bool {
        struct Payload: Decodable {
            let liked: Int?
        }
        let value: Int = try await APIClient.shared.get("/x/web-interface/archive/has/like", query: ["aid": "\(aid)"])
        return value == 1
    }

    func coinCount(aid: Int) async throws -> Int {
        struct Payload: Decodable {
            let multiply: Int?
        }
        let payload: Payload = try await APIClient.shared.get("/x/web-interface/archive/coins", query: ["aid": "\(aid)"])
        return payload.multiply ?? 0
    }

    private func csrf() -> String {
        APIClient.shared.cookies.biliJct ?? ""
    }

    private func defaultFolderId() async throws -> Int {
        if let cached = Self.cachedDefaultFolderId {
            return cached
        }
        guard let mid = APIClient.shared.cookies.dedeUserID.flatMap({ Int($0) }) else {
            throw APIError.biz(code: -101, message: "账号未登录")
        }
        let data = try await LibraryService().favoriteFolders(mid: mid)
        guard let first = data.list?.first else {
            throw APIError.biz(code: -1, message: "没有可用收藏夹")
        }
        Self.cachedDefaultFolderId = first.id
        return first.id
    }
}
