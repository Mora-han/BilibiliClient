import Foundation

enum APIConstants {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    static let referer = "https://www.bilibili.com/"
    static let apiBase = URL(string: "https://api.bilibili.com")!
    static let passportBase = URL(string: "https://passport.bilibili.com")!

    // MARK: App 端（app.bilibili.com）

    /// 官方 App 的接口主机。网页端搜索被风控拦下时，App 端这条线通常还通。
    static let appBase = URL(string: "https://app.bilibili.com")!
    /// Android 端公开的 appkey / appsec（社区文档里长期使用的固定值）。
    static let androidAppKey = "1d8b6e7d45233436"
    static let androidAppSec = "560c52ccd288fed045859ed18bffd973"
    static let appUserAgent = "Mozilla/5.0 BiliDroid/7.78.0 (bbcallen@gmail.com) os/android model/Phone mobi_app/android build/7780300 channel/bili innerVer/7780300 osVer/13"
    static let appReferer = "https://app.bilibili.com/"
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

    /// 设备指纹（buvid3/buvid4 + web 端 b_nut/_uuid/b_lsid/buvid_fp + bili_ticket），
    /// 搜索、评论等接口的风控要求。见 `DeviceFingerprint`：一次生成后持久化复用，
    /// 冷启动不会变——指纹飘忽正是「刚启动能搜、过一会儿就 412」的根因。
    private var fingerprintHeader = ""
    /// 组装中的指纹任务：多个请求同时要时只算一次。
    private var fingerprintTask: Task<String, Never>?

    private var effectiveCookieHeader: String {
        if fingerprintHeader.isEmpty { return cookieHeader }
        if cookieHeader.isEmpty { return fingerprintHeader }
        return fingerprintHeader + "; " + cookieHeader
    }

    /// 准备好设备指纹并加入后续请求的 Cookie（幂等，重复调用只算一次）。
    func ensureFingerprint() async {
        if !fingerprintHeader.isEmpty { return }
        if let task = fingerprintTask {
            fingerprintHeader = await task.value
            return
        }
        let task = Task { await DeviceFingerprint.cookieHeader() }
        fingerprintTask = task
        fingerprintHeader = await task.value
        fingerprintTask = nil
    }

    /// 兼容旧名字：取设备指纹。
    func ensureBuvid() async {
        await ensureFingerprint()
    }

    // MARK: - 请求合并与限流退避（全局兜底）

    /// 单飞：同一 URL（主机+路径+参数）的 GET 正在飞行时，后来的调用直接共享
    /// 这一个请求——页面重试连点、.task 与刷新手势撞车这类「重复并发」从源头消失，
    /// 不再产生成倍的请求风暴。
    private let inflightLock = NSLock()
    private var inflight: [String: Task<(Data, Int), Error>] = [:]

    /// 412 风控是按「主机 + 路径」来的（实测同主机的直播推荐 412、
    /// 房间信息却 200）：命中后该路径进入退避窗口，窗口内**快速失败**不再往枪口上撞
    /// ——越撞封得越久（此前一次窗口要数分钟才恢复）。
    private static let rateLock = NSLock()
    private static var rateUntil: [String: Date] = [:]
    private static var rateStreak: [String: Int] = [:]
    private static let rateSteps: [TimeInterval] = [60, 120, 240, 480, 600]

    private static func rateKey(_ request: URLRequest) -> String {
        let url = request.url
        return (url?.host ?? "?") + (url?.path ?? "/")
    }

    private static func rateGuard(_ request: URLRequest) throws {
        let key = rateKey(request)
        let until: Date? = rateLock.withLock { rateUntil[key] }
        if let until, Date() < until {
            throw APIError.biz(code: -412, message: "请求过于频繁，稍后自动恢复")
        }
    }

    private static func rateHit(_ request: URLRequest) {
        let key = rateKey(request)
        rateLock.withLock {
            let streak = min((rateStreak[key] ?? 0) + 1, rateSteps.count - 1)
            rateStreak[key] = streak
            let until = Date().addingTimeInterval(rateSteps[streak])
            if let existing = rateUntil[key], existing > until { return }
            rateUntil[key] = until
        }
    }

    private static func rateClear(_ request: URLRequest) {
        let key = rateKey(request)
        rateLock.withLock {
            rateUntil[key] = nil
            rateStreak[key] = nil
        }
    }

    /// 单飞 + 限流检查的公共取数：成功才清退避，412 记入退避窗口。
    /// 不在这里记日志，由调用方按各自语义记录。
    private func fetchShared(key: String, request: URLRequest) async throws -> (Data, Int) {
        try Self.rateGuard(request)
        let task: Task<(Data, Int), Error> = inflightLock.withLock {
            if let existing = inflight[key] { return existing }
            let session = self.session
            let created = Task<(Data, Int), Error> {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                return (data, http.statusCode)
            }
            inflight[key] = created
            return created
        }
        defer { inflightLock.withLock { inflight[key] = nil } }

        let result = try await task.value
        if result.1 == 412 {
            Self.rateHit(request)
            throw APIError.http(412)
        }
        Self.rateClear(request)
        return result
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
                           wbi: Bool = false,
                           headers: [String: String] = [:]) async throws -> T {
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
        // App 端接口要带自己的 UA / Referer，所以允许调用方覆盖默认头
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }

        let started = Date()
        do {
            let (data, status) = try await fetchShared(key: components.url!.absoluteString, request: request)
            guard (200..<300).contains(status) else { throw APIError.http(status) }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            let envelope: BiliEnvelope<T>
            do {
                envelope = try decoder.decode(BiliEnvelope<T>.self, from: data)
            } catch {
                throw APIError.decoding("\(error)")
            }
            guard envelope.code == 0 else {
                throw APIError.biz(code: envelope.code, message: envelope.message)
            }
            guard let payload = envelope.data else { throw APIError.invalidResponse }
            Self.logRequest(path, started: started, status: status)
            return payload
        } catch {
            Self.logRequest(path, started: started, error: error)
            throw error
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
        let started = Date()
        do {
            let (data, status) = try await fetchShared(key: components.url!.absoluteString, request: request)
            guard (200..<300).contains(status) else { throw APIError.http(status) }
            let http = HTTPURLResponse(url: components.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            Self.logRequest(path, started: started, status: status)
            return (data, http)
        } catch {
            Self.logRequest(path, started: started, error: error)
            throw error
        }
    }

    /// POST 表单请求（用于观看进度上报等），只校验 code/message。
    func postForm(path: String,
                  base: URL = APIConstants.apiBase,
                  form: [String: String]) async throws {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        let body = form
            .sorted { $0.key < $1.key }
            .map { "\(Self.encodeFormValue($0.key))=\(Self.encodeFormValue($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }

        let started = Date()
        do {
            let status = try await Self.expectSuccess(request, on: session)
            Self.logRequest(path, started: started, status: status)
        } catch {
            Self.logRequest(path, started: started, error: error)
            throw error
        }
    }

    /// POST JSON 请求（动态点赞等），只校验 code/message。
    func postJSON(path: String,
                  base: URL = APIConstants.apiBase,
                  json: [String: Any],
                  query: [String: String] = [:]) async throws {
        var components = URLComponents(url: base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        if let body = try? JSONSerialization.data(withJSONObject: json, options: []) {
            request.httpBody = body
        }
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }

        let started = Date()
        do {
            let status = try await Self.expectSuccess(request, on: session)
            Self.logRequest(path, started: started, status: status)
        } catch {
            Self.logRequest(path, started: started, error: error)
            throw error
        }
    }

    /// POST 类请求共用的收尾：校验 HTTP 状态与 envelope 里的 `code`，返回 HTTP 状态码供日志记录。
    private static func expectSuccess(_ request: URLRequest, on session: URLSession) async throws -> Int {
        struct EmptyEnvelope: Decodable {
            let code: Int
            let message: String
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }

        let decoder = JSONDecoder()
        let envelope = try decoder.decode(EmptyEnvelope.self, from: data)
        guard envelope.code == 0 else {
            throw APIError.biz(code: envelope.code, message: envelope.message)
        }
        return http.statusCode
    }

    /// 请求日志：成功走 `.debug`（release 下默认不落盘），失败走 `.error`。
    /// 只记路径，不记带 WBI 签名和 access_key 的完整 URL。
    private static func logRequest(_ path: String,
                                   started: Date,
                                   status: Int? = nil,
                                   error: Error? = nil) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        guard let error else {
            AppLog.network.debug("请求完成", metadata: ["path": "\(path)", "ms": "\(ms)", "status": "\(status ?? 0)"])
            return
        }
        // 取消是页面切换、任务作废的常规结果，不是故障；压到 debug 免得淹没真正的失败。
        if let urlError = error as? URLError, urlError.code == .cancelled {
            AppLog.network.debug("请求取消", metadata: ["path": "\(path)", "ms": "\(ms)"])
        } else {
            AppLog.network.error("请求失败", metadata: ["path": "\(path)", "ms": "\(ms)", "error": "\(describe(error))"])
        }
    }

    /// 错误的简短描述。不能直接用 `"\(error)"`——`URLError` 的 userInfo 里带着
    /// 完整 URL（含 WBI 签名与查询参数），那些不该进日志。
    private static func describe(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "APIError"
        }
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue)) \(urlError.localizedDescription)"
        }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    private static func encodeFormValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    /// 拉取 CDN 媒体分片（自动带上 Referer / Cookie / Range），供本地播放代理使用。
    func streamData(from url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await streamBytes(from: url, range: range)
        return (try await data.reduce(into: Data()) { $0.append($1) }, response)
    }

    /// 流式拉取 CDN 媒体分片：返回可逐块读取的字节流，供代理边下边转。
    func streamBytes(from url: URL, range: String? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        if !effectiveCookieHeader.isEmpty {
            request.setValue(effectiveCookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let range {
            request.setValue("bytes=\(range)", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (bytes, http)
    }

}


private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
