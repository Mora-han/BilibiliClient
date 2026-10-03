import SwiftUI

/// `"#RRGGBB"` 十六进制颜色解析。
///
/// 空降助手的片段色与提示卡片都要按服务端下发的十六进制值着色，
/// 这份实现原先在 `PlayerControlBar` 与 `SponsorNoticeCard` 里各抄了一份
/// （逐行相同），提出来共用。
extension Color {
    /// 解析不出来返回 nil，由调用方兜底。
    init?(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }
}
