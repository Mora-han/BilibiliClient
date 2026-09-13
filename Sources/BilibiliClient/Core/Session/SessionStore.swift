import Foundation

@MainActor
final class SessionStore: ObservableObject {
    /// 全局共享实例：主界面与菜单栏卡片共用同一登录状态。
    static let shared = SessionStore()

    @Published var loggedIn = false
    @Published var user: UserProfile?

    private(set) var cookies = BiliCookies()

    struct UserProfile {
        let mid: Int
        let name: String
        let face: String
        let level: Int
        let following: Int
        let follower: Int
        let coin: Double
    }

    init() {
        if let saved = KeychainStore.load() {
            cookies = saved
            loggedIn = !saved.isEmpty
            APIClient.shared.cookieHeader = saved.headerValue
            APIClient.shared.cookies = saved
        }
        if loggedIn {
            Task { await refreshUser() }
        }
    }

    func apply(cookies: BiliCookies) {
        self.cookies = cookies
        loggedIn = !cookies.isEmpty
        APIClient.shared.cookieHeader = cookies.headerValue
        APIClient.shared.cookies = cookies
        KeychainStore.save(cookies)
        Task { await refreshUser() }
    }

    func refreshUser() async {
        do {
            struct NavStat: Decodable {
                let following: Int
                let follower: Int
            }

            async let navResult: NavData = APIClient.shared.get("/x/web-interface/nav")
            async let statResult: NavStat = APIClient.shared.get("/x/web-interface/nav/stat")
            let (nav, stat) = try await (navResult, statResult)
            guard let mid = nav.mid, let name = nav.uname else { return }
            user = UserProfile(
                mid: mid,
                name: name,
                face: nav.face ?? "",
                level: nav.levelInfo?.currentLevel ?? 0,
                following: stat.following,
                follower: stat.follower,
                coin: nav.money ?? 0
            )
        } catch {
            // 保持已有用户信息，静默失败
        }
    }

    func logout() {
        KeychainStore.delete()
        cookies = BiliCookies()
        user = nil
        loggedIn = false
        APIClient.shared.cookieHeader = ""
        APIClient.shared.cookies = BiliCookies()
    }
}
