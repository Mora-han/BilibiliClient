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

    /// 当前用户与指定 UP 的关注关系
    func relation(fid: Int) async throws -> RelationStateData {
        try await APIClient.shared.get("/x/relation", query: ["fid": "\(fid)"])
    }

    /// 关注 / 取关 UP（act: 1=关注，2=取关）
    func modify(fid: Int, follow: Bool) async throws {
        try await APIClient.shared.postForm(path: "/x/relation/modify", form: [
            "fid": "\(fid)",
            "act": follow ? "1" : "2",
            "re_src": "11",
            "csrf": APIClient.shared.cookies.biliJct ?? "",
        ])
    }
}
