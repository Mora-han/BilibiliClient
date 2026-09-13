import Foundation

struct BiliCookies: Codable, Equatable {
    var sessdata: String?
    var biliJct: String?
    var dedeUserID: String?
    var dedeUserIDCkMd5: String?
    var refreshToken: String?

    var isEmpty: Bool {
        sessdata?.isEmpty ?? true
    }

    var headerValue: String {
        var parts: [String] = []
        if let v = sessdata, !v.isEmpty { parts.append("SESSDATA=\(v)") }
        if let v = biliJct, !v.isEmpty { parts.append("bili_jct=\(v)") }
        if let v = dedeUserID, !v.isEmpty { parts.append("DedeUserID=\(v)") }
        if let v = dedeUserIDCkMd5, !v.isEmpty { parts.append("DedeUserID__ckMd5=\(v)") }
        return parts.joined(separator: "; ")
    }

    static func parse(from response: HTTPURLResponse, refreshToken: String?) -> BiliCookies {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { partial, kv in
            partial[(kv.key as? String) ?? String(describing: kv.key)] = String(describing: kv.value)
        }
        let domain = response.url ?? URL(string: "https://passport.bilibili.com")!
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: domain)

        var result = BiliCookies()
        for cookie in cookies {
            switch cookie.name {
            case "SESSDATA": result.sessdata = cookie.value
            case "bili_jct": result.biliJct = cookie.value
            case "DedeUserID": result.dedeUserID = cookie.value
            case "DedeUserID__ckMd5": result.dedeUserIDCkMd5 = cookie.value
            default: break
            }
        }
        result.refreshToken = refreshToken
        return result
    }
}
