import Foundation

enum APIConstants {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let referer = "https://www.bilibili.com/"
    static let apiBase = URL(string: "https://api.bilibili.com")!
    static let passportBase = URL(string: "https://passport.bilibili.com")!
}

private struct BiliEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: T?
}

final class APIClient {
    static let shared = APIClient()

    /// 登录后注入到每个请求的 Cookie 头。
    var cookieHeader = ""
    /// 结构化 Cookie，供播放器等场景使用。
    var cookies = BiliCookies()

    /// buvid3/buvid4（搜索等接口风控要求），首次搜索时获取。
    private var buvidHeader = ""
    private var buvidFetched = false

    private var effectiveCookieHeader: String {
        if buvidHeader.isEmpty { return cookieHeader }
        if cookieHeader.isEmpty { return buvidHeader }
        return buvidHeader + "; " + cookieHeader
    }

    /// 从 finger/spi 获取 buvid3/buvid4 并加入 Cookie。
    func ensureBuvid() async {
        guard !buvidFetched else { return }
        buvidFetched = true
        struct Spi: Decodable {
            let b3: String?
            let b4: String?
        }
        struct Envelope: Decodable {
            let data: Spi?
        }
        do {
            var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!)
            let (data, _) = try await session.data(for: request)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(Envelope.self, from: data)
            var parts: [String] = []
            if let b3 = envelope.data?.b3, !b3.isEmpty { parts.append("buvid3=\(b3)") }
            if let b4 = envelope.data?.b4, !b4.isEmpty { parts.append("buvid4=\(b4)") }
            buvidHeader = parts.joined(separator: "; ")
        } catch {
            buvidFetched = false
        }
    }

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.httpAdditionalHeaders = [
            "User-Agent": APIConstants.userAgent,
            "Referer": APIConstants.referer,
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
        session = URLSession(configuration: configuration)
    }

    /// 标准 B 站 JSON 接口：自动处理外层 `code/data` 包装。
    func get<T: Decodable>(_ path: String,
                           base: URL = APIConstants.apiBase,
                           query: [String: String] = [:],
                           wbi: Bool = false) async throws -> T {
        var finalQuery = query
        if wbi {
            finalQuery = try await WBISigner.shared.sign(query)
        }

        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = finalQuery.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            let envelope = try decoder.decode(BiliEnvelope<T>.self, from: data)
            guard envelope.code == 0 else {
                throw APIError.biz(code: envelope.code, message: envelope.message)
            }
            guard let payload = envelope.data else { throw APIError.invalidResponse }
            return payload
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.decoding("\\(error)")
        }
    }

    /// 裸请求（不做 envelope 包装解析），用于二维码轮询、WBI 取 key 等特殊场景。
    func rawGet(path: String,
                base: URL = APIConstants.apiBase,
                query: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return (data, http)
    }

    /// POST 表单请求（用于观看进度上报等），只校验 code/message。
    func postForm(path: String,
                  base: URL = APIConstants.apiBase,
                  form: [String: String]) async throws {
        struct EmptyEnvelope: Decodable {
            let code: Int
            let message: String
        }

        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = form
            .sorted { $0.key < $1.key }
            .map { "\(Self.encodeFormValue($0.key))=\(Self.encodeFormValue($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(EmptyEnvelope.self, from: data)
        guard envelope.code == 0 else {
            throw APIError.biz(code: envelope.code, message: envelope.message)
        }
    }

    private static func encodeFormValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// 拉取 CDN 媒体分片（自动带上 Referer / Cookie / Range），供本地播放代理使用。
    func streamData(from url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let range {
            request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (data, http)
    }
}
