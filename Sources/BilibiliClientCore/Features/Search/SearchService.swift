import CryptoKit
import Foundation

/// 视频搜索。
///
/// B 站搜索的风控是**按 IP / 设备指纹**下手的，而且时紧时松：单一端点今天通、
/// 明天 412，甚至同一天里时通时不通。所以这里做两件事：
///
/// 1. 请求前先备好**稳定的设备指纹**（见 `DeviceFingerprint`）——这是网页搜索
///    能不能过的前提，也是「刚启动能搜、过一会儿就失败」的根因；
/// 2. 依次尝试四个端点，记住**上次成功**的那个下次先用，失败的那个进 2 分钟冷却
///    （只是别在它身上反复白等，不是永久拉黑；冷却到期自动恢复重试）。
///
/// 四个端点（字段最全 → 最兜底）：
/// - `.webType`    `/x/web-interface/search/type`     扁平结构，字段最全
/// - `.webWbiType` `/x/web-interface/wbi/search/type` 官方 web 用的签名版
/// - `.webAll`     `/x/web-interface/search/all/v2`   分组结构，取 video 组
/// - `.app`        `app.bilibili.com/x/v2/search`     App 端，另一个主机
struct SearchService {
    enum Endpoint: CaseIterable {
        case webType
        case webWbiType
        case webAll
        case app
    }

    /// 上次成功的端点：下次先试它。
    private static var lastGood: Endpoint?
    /// 各端点最近失败的时间，冷却期内不再先试。
    private static var failedAt: [Endpoint: Date] = [:]
    private static let cooldown: TimeInterval = 120

    func videos(keyword: String, page: Int = 1, order: String = "totalrank") async throws -> SearchData {
        await APIClient.shared.ensureFingerprint()
        var lastError: Error?
        var attempted = false
        for endpoint in chain() {
            if let failed = Self.failedAt[endpoint], Date().timeIntervalSince(failed) < Self.cooldown {
                continue
            }
            attempted = true
            do {
                return try await run(endpoint, keyword: keyword, page: page, sort: order)
            } catch {
                lastError = error
            }
        }
        // 全都在冷却期：硬试一条最可能通的，绝不出现「怎么点都是失败」
        if !attempted, let endpoint = Self.lastGood ?? Endpoint.allCases.first {
            do {
                return try await run(endpoint, keyword: keyword, page: page, sort: order)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError.biz(code: -412, message: "搜索暂时不可用，请稍后再试")
    }

    /// 尝试顺序：上次成功的排最前，其余按「字段最全 → 最兜底」。
    private func chain() -> [Endpoint] {
        var order = Endpoint.allCases
        if let lastGood = Self.lastGood, let index = order.firstIndex(of: lastGood) {
            order.remove(at: index)
            order.insert(lastGood, at: 0)
        }
        return order
    }

    private func run(_ endpoint: Endpoint,
                     keyword: String,
                     page: Int,
                     sort: String) async throws -> SearchData {
        do {
            let data: SearchData
            switch endpoint {
            case .webType:
                data = try await webType(keyword: keyword, page: page, sort: sort)
            case .webWbiType:
                data = try await webWbiType(keyword: keyword, page: page, sort: sort)
            case .webAll:
                data = try await webAll(keyword: keyword, page: page, sort: sort)
            case .app:
                data = try await appSearch(keyword: keyword, page: page, sort: sort)
            }
            // 只回了风控凭证（HTTP 200 / code 0，但没有 result）：当成这一条不通
            if data.result.isEmpty, data.voucher != nil {
                throw APIError.biz(code: -412, message: "搜索请求被风控拦截")
            }
            Self.lastGood = endpoint
            Self.failedAt[endpoint] = nil
            return data
        } catch {
            Self.failedAt[endpoint] = Date()
            throw error
        }
    }

    // MARK: - 网页端点

    private func webType(keyword: String, page: Int, sort: String) async throws -> SearchData {
        try await APIClient.shared.get("/x/web-interface/search/type", query: [
            "search_type": "video",
            "keyword": keyword,
            "order": sort,
            "page": "\(page)",
            "page_size": "20",
        ])
    }

    private func webWbiType(keyword: String, page: Int, sort: String) async throws -> SearchData {
        try await APIClient.shared.get("/x/web-interface/wbi/search/type", query: [
            "search_type": "video",
            "keyword": keyword,
            "order": sort,
            "page": "\(page)",
            "page_size": "20",
        ], wbi: true)
    }

    private func webAll(keyword: String, page: Int, sort: String) async throws -> SearchData {
        let all: SearchAllData = try await APIClient.shared.get("/x/web-interface/search/all/v2", query: [
            "search_type": "video",
            "keyword": keyword,
            "order": sort,
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

    private func appSearch(keyword: String, page: Int, sort: String) async throws -> SearchData {
        var query: [String: String] = [
            "appkey": APIConstants.androidAppKey,
            "build": "7780300",
            "keyword": keyword,
            "mobi_app": "android",
            "order": sort,
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
