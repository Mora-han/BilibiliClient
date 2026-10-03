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

    /// 412 是 **IP 级**限流，四条端点共享同一个窗口：撞上就整体退避——
    /// 窗口内再发请求只会白白再挨一刀、把封禁越拖越长（实测一次窗口约数分钟）。
    private static var rateLimitedUntil: Date?
    private static var rateLimitStreak = 0

    /// 界面用：退避窗口未到点时返回到期时间（nil = 没有限流，可正常搜）。
    static var rateLimitRetryAt: Date? {
        guard let until = rateLimitedUntil, Date() < until else { return nil }
        return until
    }

    private static func enterRateLimit() {
        rateLimitStreak = min(rateLimitStreak + 1, 4)
        let seconds: TimeInterval = [60, 120, 240, 480, 600][rateLimitStreak]
        let until = Date().addingTimeInterval(seconds)
        if let existing = rateLimitedUntil, existing > until { return }
        rateLimitedUntil = until
    }

    private static func clearRateLimit() {
        rateLimitStreak = 0
        rateLimitedUntil = nil
    }

    func videos(keyword: String, page: Int = 1, order: String = "totalrank") async throws -> SearchData {
        await APIClient.shared.ensureFingerprint()
        // 退避窗口内不发任何请求：秒失败 + 明确文案，等窗口结束自动重试
        if Self.rateLimitRetryAt != nil {
            throw APIError.biz(code: -412, message: "搜索请求过于频繁，已暂停自动重试")
        }
        var empty: SearchData?
        var sawPositiveTotal = false
        var saw412 = false
        var lastError: Error?
        var attempted = false
        for endpoint in chain() {
            if let failed = Self.failedAt[endpoint], Date().timeIntervalSince(failed) < Self.cooldown {
                continue
            }
            attempted = true
            do {
                let data = try await run(endpoint, keyword: keyword, page: page, sort: order)
                if !data.result.isEmpty {
                    Self.clearRateLimit()
                    return data
                }
                // **空结果不等于没有结果**：B 站连乱码关键词都会回一堆「相关」结果，
                // 真正的空几乎只出现在被风控的时候。所以这里先记下来、继续试下一条
                // 端点——「第一次能搜、第二次就没有找到相关视频」就是这么来的。
                if (data.numResults ?? 0) > 0 { sawPositiveTotal = true }
                if empty == nil { empty = data }
                Self.failedAt[endpoint] = Date()
            } catch {
                if case APIError.http(412) = error { saw412 = true }
                lastError = error
            }
        }
        // 所有端点都试过了：只有「每条都明确说总数就是 0」才敢当真的没有结果
        if let empty, !sawPositiveTotal {
            return empty
        }
        if !attempted, let endpoint = Self.lastGood ?? Endpoint.allCases.first {
            // 全都在冷却期：硬试一条最可能通的，绝不出现「怎么点都是失败」
            do {
                return try await run(endpoint, keyword: keyword, page: page, sort: order)
            } catch {
                if case APIError.http(412) = error { saw412 = true }
                lastError = error
            }
        }
        // 整次搜索都没拿到结果、且期间撞过 412 → 进入退避窗口
        if saw412 { Self.enterRateLimit() }
        throw lastError ?? APIError.biz(code: -412, message: "搜索被限制，请稍后再试")
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
            if !data.result.isEmpty {
                Self.lastGood = endpoint
                Self.failedAt[endpoint] = nil
            }
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
        let mapped = data.searchData
        // 有原始条目却一个视频都没解析出来：说明返回结构变了（不是「没有结果」），
        // 抛出去让外层换下一条端点，别把这种情况显示成「没有找到相关视频」
        if mapped.result.isEmpty, data.rawItemCount > 0 {
            throw APIError.decoding("App 搜索返回的条目里没有视频")
        }
        return mapped
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
