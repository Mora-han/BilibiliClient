import Foundation

struct SearchService {
    /// 视频搜索。
    ///
    /// **走不带 WBI 签名的 `/x/web-interface/search/type`**：带签名的
    /// `/x/web-interface/wbi/search/type` 现在会被风控拦下——HTTP 200、`code` 也是 0，
    /// 但 `data` 里只有 `v_voucher`、没有 `result`，界面于是显示「找到 0 个视频」，
    /// 看起来像「搜什么都搜不到」。实测同一时刻旧端点能正常返回结果，
    /// 所以这里固定用旧端点，并在拿到 voucher 时显式报错（见 `videos` 的调用方）。
    func videos(keyword: String, page: Int = 1, order: String = "totalrank") async throws -> SearchData {
        await APIClient.shared.ensureBuvid()
        let data: SearchData = try await APIClient.shared.get("/x/web-interface/search/type", query: [
            "search_type": "video",
            "keyword": keyword,
            "order": order,
            "page": "\(page)",
            "page_size": "20",
        ])
        // 风控响应：code 0 但只有 v_voucher。当成错误抛出去，让界面提示重试，
        // 而不是把「被拦截」静默显示成「0 个视频」。
        if data.result.isEmpty, data.voucher != nil {
            throw APIError.biz(code: -412, message: "搜索请求被风控拦截，请稍后再试")
        }
        return data
    }
}
