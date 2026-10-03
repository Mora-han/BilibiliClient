import CryptoKit
import Foundation

/// 设备指纹 cookie。
///
/// B 站的风控主要看这套 cookie，而且**必须稳定**：
///
/// - 只有 `buvid3` / `buvid4` 时网页搜索接口时通时不通（412/402 或只回 `v_voucher`），
///   补齐 web 端的 `b_nut` / `_uuid` / `b_lsid` / `buvid_fp` 并带上 `bili_ticket`
///   之后才稳定（实测：只带 buvid 时 3 次里挂 2 次，补齐后 3/3 正常）；
/// - 每次冷启动都换一套指纹（旧实现就是这样）在风控看来等于「每次都是新设备」，
///   于是「刚启动能搜，过一会儿/重开就失败」。
///
/// 所以这里生成一次就持久化到 UserDefaults，之后一直复用：
/// `buvid3/4`、`b_nut`、`_uuid`、`buvid_fp` 落盘；`b_lsid` 每次进程启动重建
/// （真实 web 客户端也这么做）；`bili_ticket` 有 3 天有效期，到期前自动续——
/// 它是纯本地算法算出来的，不需要用户登录。
enum DeviceFingerprint {
    private static let lock = NSLock()
    private static var cachedHeader: String?
    private static var cachedTicket: Ticket?

    private enum Key {
        static let buvid3 = "device.buvid3"
        static let buvid4 = "device.buvid4"
        static let bNut = "device.bnut"
        static let uuid = "device.uuid"
        static let fp = "device.fp"
        static let ticket = "device.ticket"
        static let ticketExpires = "device.ticket.expires"
    }

    private struct Ticket {
        let value: String
        let expiresAt: Int
    }

    /// 组装好的 Cookie 片段（只在首次或需要刷新时重新计算）。
    static func cookieHeader() async -> String {
        if let cached = lock.withLock({ cachedHeader }) { return cached }
        let header = await buildHeader()
        lock.withLock { cachedHeader = header }
        return header
    }

    /// 把缓存清掉，下次重新组装（登录态变化等场景可用）。
    static func reset() {
        lock.withLock {
            cachedHeader = nil
            cachedTicket = nil
        }
    }

    // MARK: - 组装

    private static func buildHeader() async -> String {
        let defaults = UserDefaults.standard
        var parts: [String] = []

        // 1) buvid3 / buvid4：优先用存下来的，缺失才去领一套新的
        var b3 = defaults.string(forKey: Key.buvid3) ?? ""
        var b4 = defaults.string(forKey: Key.buvid4) ?? ""
        if b3.isEmpty || b4.isEmpty {
            if let pair = await fetchBuvid() {
                b3 = pair.0
                b4 = pair.1
                defaults.set(b3, forKey: Key.buvid3)
                defaults.set(b4, forKey: Key.buvid4)
            }
        }
        if !b3.isEmpty { parts.append("buvid3=\(b3)") }
        if !b4.isEmpty { parts.append("buvid4=\(b4)") }

        // 2) 首次使用时间：一次定下就不再变
        var nut = defaults.integer(forKey: Key.bNut)
        if nut == 0 {
            nut = Int(Date().timeIntervalSince1970)
            defaults.set(nut, forKey: Key.bNut)
        }
        parts.append("b_nut=\(nut)")

        // 3) _uuid：一次生成，长期复用
        var uuid = defaults.string(forKey: Key.uuid) ?? ""
        if uuid.isEmpty {
            uuid = makeUUID()
            defaults.set(uuid, forKey: Key.uuid)
        }
        parts.append("_uuid=\(uuid)")

        // 4) b_lsid：每次进程启动换一个（真实 web 客户端行为）
        parts.append("b_lsid=\(makeLsid())")

        // 5) buvid_fp：稳定指纹值
        var fp = defaults.string(forKey: Key.fp) ?? ""
        if fp.isEmpty {
            fp = md5Hex(UUID().uuidString + (b3.isEmpty ? "bili" : b3))
            defaults.set(fp, forKey: Key.fp)
        }
        parts.append("buvid_fp=\(fp)")

        // 6) bili_ticket：3 天有效，快到期就续
        if let ticket = await validTicket(buvid3: b3) {
            parts.append("bili_ticket=\(ticket.value)")
            parts.append("bili_ticket_expires=\(ticket.expiresAt)")
        }

        return parts.joined(separator: "; ")
    }

    /// 取一张还有效的 bili_ticket（内存 → 磁盘 → 重新申请）。
    private static func validTicket(buvid3: String) async -> Ticket? {
        let now = Int(Date().timeIntervalSince1970)
        if let cached = lock.withLock({ cachedTicket }), cached.expiresAt - 3600 > now {
            return cached
        }
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Key.ticket) ?? ""
        let storedExpires = defaults.integer(forKey: Key.ticketExpires)
        if !stored.isEmpty, storedExpires - 3600 > now {
            let ticket = Ticket(value: stored, expiresAt: storedExpires)
            lock.withLock { cachedTicket = ticket }
            return ticket
        }
        guard let fresh = await fetchTicket() else { return nil }
        defaults.set(fresh.value, forKey: Key.ticket)
        defaults.set(fresh.expiresAt, forKey: Key.ticketExpires)
        lock.withLock { cachedTicket = fresh }
        return fresh
    }

    // MARK: - 网络

    /// 领一套新的 buvid3 / buvid4。
    private static func fetchBuvid() async -> (String, String)? {
        struct Spi: Decodable {
            let b3: String?
            let b4: String?
        }
        struct Envelope: Decodable {
            let data: Spi?
        }
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard let b3 = envelope.data?.b3, let b4 = envelope.data?.b4,
                  !b3.isEmpty, !b4.isEmpty else { return nil }
            return (b3, b4)
        } catch {
            return nil
        }
    }

    /// 申请 bili_ticket：`hexsign = HMAC-SHA256(key: "XgwSnGZ1p", "ts<时间戳>")`，
    /// POST 一个空 body 即可，返回的 `ttl` 是有效期（秒）。
    private static func fetchTicket() async -> Ticket? {
        struct TicketData: Decodable {
            let ticket: String?
            let createdAt: Int?
            let ttl: Int?
        }
        struct Envelope: Decodable {
            let code: Int?
            let data: TicketData?
        }
        let ts = Int(Date().timeIntervalSince1970)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("ts\(ts)".utf8),
            using: SymmetricKey(data: Data("XgwSnGZ1p".utf8))
        )
        let hexsign = mac.map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string:
            "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket")!
        components.queryItems = [
            URLQueryItem(name: "key_id", value: "ec02"),
            URLQueryItem(name: "hexsign", value: hexsign),
            URLQueryItem(name: "context[ts]", value: "\(ts)"),
            URLQueryItem(name: "csrf", value: ""),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(APIConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(APIConstants.referer, forHTTPHeaderField: "Referer")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard let ticket = envelope.data?.ticket, !ticket.isEmpty else { return nil }
            let ttl = envelope.data?.ttl ?? 259_200
            let createdAt = envelope.data?.createdAt ?? ts
            return Ticket(value: ticket, expiresAt: createdAt + ttl)
        } catch {
            return nil
        }
    }

    // MARK: - 小工具

    private static func makeUUID() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let parts = [raw.prefix(8), raw.dropFirst(8).prefix(4), raw.dropFirst(12).prefix(4),
                     raw.dropFirst(16).prefix(4), raw.dropFirst(20).prefix(12)]
        return parts.map(String.init).joined(separator: "-") + "infoc"
    }

    private static func makeLsid() -> String {
        let hex = "0123456789ABCDEF"
        let first = String((0..<8).map { _ in hex.randomElement()! })
        let second = String((0..<15).map { _ in hex.randomElement()! })
        return "\(first)_\(second)"
    }

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
