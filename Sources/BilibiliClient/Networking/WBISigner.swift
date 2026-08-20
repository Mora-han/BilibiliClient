import CryptoKit
import Foundation

/// WBI 签名（web 端风控鉴权），算法与 bilibili-API-collect 文档一致。
final class WBISigner {
    static let shared = WBISigner()

    private static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]

    private var cachedKeys: (img: String, sub: String)?
    private var cachedAt: Date?

    func sign(_ params: [String: String]) async throws -> [String: String] {
        let keys = try await fetchKeys()
        let mixinKey = Self.mixinKey(from: keys.img + keys.sub)

        // 官方 web 端实现：先把值里的 !'()* 字符去掉
        var filtered = params.mapValues { value in
            value.filter { !"!'()*".contains($0) }
        }
        filtered["wts"] = String(Int(Date().timeIntervalSince1970))

        let query = filtered.sorted { $0.key < $1.key }
            .map { "\(Self.encodeURIComponent($0.key))=\(Self.encodeURIComponent($0.value))" }
            .joined(separator: "&")

        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
        let wRid = digest.map { byte -> String in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()

        var signed = filtered
        signed["w_rid"] = wRid
        return signed
    }

    private func fetchKeys() async throws -> (img: String, sub: String) {
        if let cachedKeys, let cachedAt, Date().timeIntervalSince(cachedAt) < 3600 {
            return cachedKeys
        }

        // nav 未登录时外层 code 为 -101，但 data.wbi_img 仍然存在，所以用裸请求解析
        let (data, _) = try await APIClient.shared.rawGet(path: "/x/web-interface/nav")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        struct Envelope: Decodable {
            let data: NavData?
        }

        let envelope = try decoder.decode(Envelope.self, from: data)
        guard let wbi = envelope.data?.wbiImg,
              let img = URL(string: wbi.imgUrl)?.lastPathComponent,
              let sub = URL(string: wbi.subUrl)?.lastPathComponent,
              !img.isEmpty, !sub.isEmpty else {
            throw APIError.invalidResponse
        }

        cachedKeys = (img, sub)
        cachedAt = Date()
        return (img, sub)
    }

    private static func mixinKey(from raw: String) -> String {
        let chars = Array(raw)
        guard chars.count >= 64 else { return "" }
        return mixinKeyEncTab.prefix(32).map { String(chars[$0]) }.joined()
    }

    /// 与 JS encodeURIComponent 语义一致：字母数字与 `-_.!~*'()` 保留，其余按大写十六进制转义。
    private static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
