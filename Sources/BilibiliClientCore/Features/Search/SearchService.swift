import CryptoKit
import Foundation

/// 视频搜索。
///
/// 网页搜索接口的风控时紧时松：`/x/web-interface/wbi/search/type` 会回
/// `v_voucher`（HTTP 200、code 0，但只有凭证没有结果），
/// `/x/web-interface/search/type` 会直接 412/402。所以这里按顺序试两条线：
///
/// 1. 网页 `search/all/v2`——字段最全（bvid、收藏数、发布时间都有），分组结构，
///    取 `result_type == "video"` 那一组；
/// 2. App 端 `app.bilibili.com/x/v2/search`——另一个主机 + android appkey 签名，
///    网页被风控时这条通常还通（条目只有 aid，本地用 `BVid` 换成 bvid）。
///
/// 两条都失败时抛出可读错误，界面会显示"加载失败"并给重试按钮。
struct SearchService {
    func videos(keyword: String, page: Int = 1, order: String = "totalrank") async throws -> SearchData {
        await APIClient.shared.ensureBuvid()
        var firstError: Error?
        do {
            let data = try await webVideos(keyword: keyword, page: page, order: order)
            if !data.result.isEmpty || data.voucher == nil {
                return data
            }
            firstError = APIError.biz(code: -412, message: "搜索请求被风控拦截")
        } catch {
            firstError = error
        }
        do {
            return try await appVideos(keyword: keyword, page: page, order: order)
        } catch {
            throw firstError ?? error
        }
    }

    // MARK: - 网页端点

    private func webVideos(keyword: String, page: Int, order: String) async throws -> SearchData {
        let all: SearchAllData = try await APIClient.shared.get("/x/web-interface/search/all/v2", query: [
            "search_type": "video",
            "keyword": keyword,
            "order": order,
            "page": "\(page)",
            "page_size": "20",
        ])
        return SearchData(
            numResults: all.numResults,
            numPages: all.numPages,
            result: all.videos,
            voucher: all.voucher
        )
    }

    // MARK: - App 端点

    private func appVideos(keyword: String, page: Int, order: String) async throws -> SearchData {
        var query: [String: String] = [
            "appkey": APIConstants.androidAppKey,
            "build": "7780300",
            "keyword": keyword,
            "mobi_app": "android",
            "order": order,
            "platform": "android",
            "pn": "\(page)",
            "ps": "20",
            "ts": "\(Int(Date().timeIntervalSince1970))",
        ]
        query["sign"] = Self.appSign(query)

        let data: AppSearchData = try await APIClient.shared.get(
            "/x/v2/search",
            base: APIConstants.appBase,
            query: query,
            headers: [
                "User-Agent": APIConstants.appUserAgent,
                "Referer": APIConstants.appReferer,
            ]
        )
        return data.searchData
    }

    /// App 签名：`md5(按 key 排序的查询串 + appsec)`；
    /// 查询串按 `quote_plus` 规则编码（空格 `+`、其余 UTF-8 百分号编码），
    /// 和官方客户端一致，否则服务端校验不过。
    private static func appSign(_ params: [String: String]) -> String {
        let query = params.sorted { $0.key < $1.key }
            .map { "\(escaped($0.key))=\(escaped($0.value))" }
            .joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + APIConstants.androidAppSec).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func escaped(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}
