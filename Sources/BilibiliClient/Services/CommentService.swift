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
}
