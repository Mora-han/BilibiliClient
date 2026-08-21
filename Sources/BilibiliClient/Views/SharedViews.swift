import SwiftUI

/// 列表底部加载指示：只在真正请求时显示“加载中”，
/// 空闲时保持透明占位（配合 autoLoadMore 接近底部自动预载，实现无感连续加载）。
struct LoadMoreFooter: View {
    var isBusy: Bool
    var onLoad: () async -> Void

    var body: some View {
        Group {
            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else {
                // 透明占位：保持 onAppear 兜底触发，视觉上无任何提示
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
        }
        .onAppear {
            Task { await onLoad() }
        }
    }
}

extension View {
    /// 滚动接近底部时自动加载下一页：剩余可滚动距离不足 threshold（默认约一屏）
    /// 即触发，内容始终在滚动前就绪，实现“拉不到底”的连续加载体验。
    func autoLoadMore(threshold: CGFloat = 600, load: @escaping () async -> Void) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
        } action: { _, remaining in
            if remaining < threshold {
                Task { await load() }
            }
        }
    }
}

/// 统一的“需要登录”占位视图。
struct LoginRequiredView: View {
    let title: String
    let systemImage: String
    let message: String
    @Binding var showLogin: Bool

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("扫码登录") { showLogin = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 统一的列表加载失败占位视图（带重试）。
struct LoadErrorView: View {
    let message: String
    var retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                Task { await retry() }
            }
        }
    }
}
