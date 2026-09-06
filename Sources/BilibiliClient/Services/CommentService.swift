import Foundation

struct CommentService {
    func videoComments(aid: Int, page: Int = 1, pageSize: Int = 20) async throws -> CommentData {
        try await APIClient.shared.get("/x/v2/reply", query: [
            "type": "1",
            "oid": "\(aid)",
            "sort": "1",
            "ps": "\(pageSize)",
            "pn": "\(page)",
            "nohot": "1",
        ])
    }

    func videoCommentReplies(aid: Int, root: Int, page: Int = 1, pageSize: Int = 20) async throws -> CommentRepliesData {
        try await APIClient.shared.get("/x/v2/reply/reply", query: [
            "type": "1",
            "oid": "\(aid)",
            "root": "\(root)",
            "ps": "\(pageSize)",
            "pn": "\(page)",
        ])
    }

    /// 点赞 / 取消点赞评论（type=1 视频评论）。
    func like(aid: Int, rpid: Int, liked: Bool) async throws {
        await APIClient.shared.ensureBuvid()
        try await APIClient.shared.postForm(path: "/x/v2/reply/like", form: [
            "type": "1",
            "oid": "\(aid)",
            "rpid": "\(rpid)",
            "action": liked ? "1" : "2",
            "csrf": APIClient.shared.cookies.biliJct ?? "",
        ])
    }
}
