import Foundation

/// aid ↔ bvid 互转（BV 号就是 av 号做位重排 + 异或得到的，算法公开）。
///
/// App 端搜索接口只给 aid（`param` 字段），而 app 内跳转一律用 bvid，
/// 本地换算一下，省一次网络查询。
enum BVid {
    private static let table = Array("fZodR9XQDSUm21yCkr6zBqiveYah8bt4xsWpHnJE7jL5VG3guMTKNPAwcF")
    private static let positions = [11, 10, 3, 8, 4, 6]
    private static let xor = 177_451_812
    private static let add = 8_728_348_608

    /// av 号 → BV 号；非法输入返回 nil。
    static func from(aid: Int) -> String? {
        guard aid > 0 else { return nil }
        var chars = Array("BV1  4 1 7  ")
        let value = (aid ^ xor) &+ add
        for (index, position) in positions.enumerated() {
            var quotient = value
            for _ in 0..<index { quotient /= 58 }
            chars[position] = table[quotient % 58]
        }
        let bvid = String(chars)
        return bvid.hasPrefix("BV1") ? bvid : nil
    }
}
