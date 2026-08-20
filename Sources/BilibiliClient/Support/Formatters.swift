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

    private static func two(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
