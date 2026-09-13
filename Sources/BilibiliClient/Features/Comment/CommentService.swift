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

    /// 非视频评论（动态等）：type/oid 由动态的 basic 信息指定。
    func comments(type: Int, oid: String, page: Int = 1, pageSize: Int = 20) async throws -> CommentData {
        try await APIClient.shared.get("/x/v2/reply", query: [
            "type": "\(type)",
            "oid": oid,
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

    /// 点赞 / 取消点赞评论（type=1 视频评论；action：1=点赞，0=取消点赞）。
    func like(aid: Int, rpid: Int, liked: Bool) async throws {
        await APIClient.shared.ensureBuvid()
        try await APIClient.shared.postForm(path: "/x/v2/reply/action", form: [
            "type": "1",
            "oid": "\(aid)",
            "rpid": "\(rpid)",
            "action": liked ? "1" : "0",
            "csrf": APIClient.shared.cookies.biliJct ?? "",
        ])
    }
}
