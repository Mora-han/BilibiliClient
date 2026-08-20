import Foundation

enum Formatters {
    static func count(_ value: Int) -> String {
        if value >= 100_000_000 {
            return decimal(Double(value) / 100_000_000) + "亿"
        }
        if value >= 10_000 {
            return decimal(Double(value) / 10_000) + "万"
        }
        return "\(value)"
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return "\(h):\(two(m)):\(two(s))"
        }
        return "\(two(m)):\(two(s))"
    }

    static func https(_ url: String) -> URL? {
        URL(string: url.replacingOccurrences(of: "http://", with: "https://"))
    }

    /// 定点小数格式化（规避部分环境下 String(format:) 失效的问题）。
    static func decimal(_ value: Double, fractionDigits: Int = 1) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 相对时间："刚刚 / x 分钟前 / x 小时前 / x 天前 / yyyy-MM-dd"
    static func timeAgo(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 86_400 * 30 { return "\(Int(interval / 86_400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func two(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
