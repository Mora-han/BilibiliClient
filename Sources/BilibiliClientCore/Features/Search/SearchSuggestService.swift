import Foundation

/// 搜索推荐词（边打边出，App Store 搜索框那种体验）。
///
/// 走 `s.search.bilibili.com/main/suggest`——它是网页端搜索框的推荐词接口，
/// 返回 `result.tag[].term`。注意两点：
/// - 它不在 `api.bilibili.com` 的 `code/data` envelope 结构里（是 `code/result`），
///   所以用 `rawGet` 拿原始数据自行解码；
/// - 推荐词只是锦上添花，任何失败都静默返回空数组，绝不打断输入。
struct SearchSuggestService {
    private struct Response: Decodable {
        let code: Int?
        let result: Result?

        struct Result: Decodable {
            let tag: [Tag]?
        }

        struct Tag: Decodable {
            let term: String?
        }
    }

    func suggest(term: String) async -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let (data, _) = try await APIClient.shared.rawGet(
                path: "/main/suggest",
                base: URL(string: "https://s.search.bilibili.com")!,
                query: [
                    "func": "suggest",
                    "term": trimmed,
                    "main.ver": "1",
                    "psid": "",
                    "soc_tag": "0",
                    "spid": "0",
                ]
            )
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.code == 0 else { return [] }
            var seen = Set<String>()
            let words = (decoded.result?.tag ?? [])
                .compactMap(\.term)
                .filter { seen.insert($0).inserted }
            return Array(words.prefix(10))
        } catch {
            return []
        }
    }
}
