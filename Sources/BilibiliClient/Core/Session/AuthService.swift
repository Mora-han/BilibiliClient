import Foundation

enum QRStatus {
    case waiting
    case scanned
    case expired
    case success(BiliCookies)
}

enum AuthService {
    /// 申请二维码，返回扫码 key 与二维码内容 URL。
    static func generateQR() async throws -> (key: String, url: URL) {
        struct Payload: Decodable {
            let url: String
            let qrcodeKey: String
        }

        let payload: Payload = try await APIClient.shared.get(
            "/x/passport-login/web/qrcode/generate",
            base: APIConstants.passportBase
        )
        guard let url = URL(string: payload.url) else { throw APIError.invalidResponse }
        return (payload.qrcodeKey, url)
    }

    /// 轮询扫码状态。登录成功后 cookie 在响应头里，需要从 HTTPURLResponse 提取。
    static func poll(key: String) async throws -> QRStatus {
        struct Payload: Decodable {
            let url: String?
            let refreshToken: String?
            let code: Int
        }

        let (data, response) = try await APIClient.shared.rawGet(
            path: "/x/passport-login/web/qrcode/poll",
            base: APIConstants.passportBase,
            query: ["qrcode_key": key]
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Envelope: Decodable {
            let data: Payload?
        }

        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              let payload = envelope.data else {
            throw APIError.decoding("二维码响应解析失败")
        }

        switch payload.code {
        case 0:
            let cookies = BiliCookies.parse(from: response, refreshToken: payload.refreshToken)
            return .success(cookies)
        case 86090:
            return .scanned
        case 86038:
            return .expired
        default:
            return .waiting
        }
    }
}
