import Foundation

/// 最近搜索：`UserDefaults` 里存一个字符串数组（最新在前），只增删查，
/// 没有发布订阅——搜索页自己持有 `@State`，每次改动后回读一遍即可。
///
/// 目前只有 iOS 搜索页用（macOS 走侧边栏搜索框，没有「空词进搜索页」这个状态），
/// 放在共享层只为不额外开一棵平台分支的源码树。
enum RecentSearchStore {
    private static let key = "recentSearches"
    /// 最多留 20 条：再多就翻不到底了
    private static let limit = 20

    /// 全部最近搜索（最新在前）。
    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// 记一次搜索：去重后插到最前，并截断到上限。空词忽略。
    static func add(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = all.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > limit {
            list = Array(list.prefix(limit))
        }
        write(list)
    }

    /// 删掉单条（搜索页每行右侧的删除按钮）。
    static func remove(_ term: String) {
        write(all.filter { $0 != term })
    }

    /// 清空（搜索页「清空」按钮）。
    static func clear() {
        write([])
    }

    private static func write(_ list: [String]) {
        UserDefaults.standard.set(list, forKey: key)
    }
}
