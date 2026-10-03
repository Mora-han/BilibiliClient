import SwiftUI

/// 播放区占位态（16:9 黑底 + 图标/文案 + 可选重试）。
///
/// 视频播放页与直播间详情页原本各抄一份「加载中 / 未开播 / 加载失败」的黑底占位，
/// 图标、文案、重试按钮的样式全靠人工对齐（`LivePlayerSurface` 里还曾有第三份，
/// 那份永远走不到，已删）。这里收口成一份，两页共用。
struct PlayerPlaceholderView: View {
    enum Content {
        /// 连接中：转圈 + 一行说明
        case loading(String)
        /// 未开播：图标 + 标题 + 副文案
        case offline(icon: String, title: String, subtitle: String?)
        /// 加载失败：图标 + 标题 + 错误详情 + 重试
        case failed(icon: String, title: String, detail: String?, retry: () async -> Void)
    }

    let content: Content

    var body: some View {
        switch content {
        case .loading(let title):
            VStack(spacing: 10) {
                ProgressView()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .offline(icon, title, subtitle):
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(icon, title, detail, retry):
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("重试") {
                    Task { await retry() }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
