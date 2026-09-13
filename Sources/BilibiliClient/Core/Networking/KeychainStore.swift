import Foundation
import Security

/// 登录 cookie 的钥匙串存储。
///
/// 这里的取舍都由一个坑决定：钥匙串条目的访问权限绑在 App 的**代码签名**上，而早期
/// 构建用的是 ad-hoc 签名 —— ad-hoc 的「设计要求」就是 cdhash，每次编译都会变，
/// macOS 于是把每个新构建都当成另一个 App，每编译运行一次就弹一次
/// 「请输入"登录"钥匙串的密码」，而且点「始终允许」也没用（下次编译 cdhash 又变了）。
///
/// 对策两条：
/// 1. 签名固定（见 scripts/build_app.sh）—— 新条目由固定证书创建，之后读取不再需要授权。
/// 2. 存储换到新的服务名 `…v2`。历史上那个由旧签名创建的旧条目，我们既读不到
///    （errSecAuthFailed）也没权限删（errSecInvalidOwnerEdit），所以干脆不再碰它：
///    读不到就当「未登录」，绝不弹框打断用户；重新登录一次即写入新条目，此后全程静默。
enum KeychainStore {
    private static let service = "com.codex.bilibili-client.v2"
    private static let account = "cookies"

    /// `SecKeychainSetUserInteractionAllowed` 是唯一能抑制「老式钥匙串条目 ACL 授权框」
    /// 的接口（kSecUseAuthenticationUI 与 LAContext.interactionNotAllowed 实测对老式
    /// 钥匙串无效，照样弹框）。它自 10.10 起被标记废弃，但没有替代品，所以用 dlsym
    /// 取符号调用，免得为一个无可替代的 API 引入编译告警。取不到就退化为不抑制。
    private typealias SetUIAllowedFn = @convention(c) (UInt8) -> OSStatus
    private static let setUIAllowed: SetUIAllowedFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return nil }
        return unsafeBitCast(symbol, to: SetUIAllowedFn.self)
    }()

    /// 权限不足时直接拿到错误码，而不是弹系统授权框
    private static func disableKeychainUI() {
        _ = setUIAllowed?(0)
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ cookies: BiliCookies) {
        disableKeychainUI()
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        let base = query()
        let update: [String: Any] = [kSecValueData as String: data]
        // 更新失败（条目不存在 / 无权访问）一律退回「新增」：新条目由当前固定签名
        // 创建，之后读取就再也用不着任何授权。
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) != errSecSuccess {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load() -> BiliCookies? {
        disableKeychainUI()
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(BiliCookies.self, from: data)
    }

    static func delete() {
        disableKeychainUI()
        SecItemDelete(query() as CFDictionary)
    }
}
