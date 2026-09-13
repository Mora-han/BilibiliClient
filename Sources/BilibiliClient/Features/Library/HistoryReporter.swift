import Foundation

/// 观看进度上报：把播放进度写入账号历史记录。
enum HistoryReporter {
    static func report(aid: Int, cid: Int, progress: Int) async {
        let cookies = APIClient.shared.cookies
        guard let csrf = cookies.biliJct, !csrf.isEmpty else { return }
        guard progress > 0 else { return }
        try? await APIClient.shared.postForm(path: "/x/v2/history/report", form: [
            "aid": "\(aid)",
            "cid": "\(cid)",
            "progress": "\(progress)",
            "platform": "web",
            "csrf": csrf,
        ])
    }
}
