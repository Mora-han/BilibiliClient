import SwiftUI

/// 视频展示模式（设置项）：卡片 / 单列列表 / 两列列表，全局统一生效。
enum VideoDisplayMode: String, CaseIterable, Identifiable {
    case card
    case list
    case list2

    var id: String { rawValue }

    var label: String {
        switch self {
        case .card: return "卡片"
        case .list: return "列表"
        case .list2: return "两列列表"
        }
    }

    static var current: VideoDisplayMode {
        VideoDisplayMode(rawValue: UserDefaults.standard.string(forKey: "videoDisplayMode") ?? "") ?? .card
    }
}

/// 按全局显示模式统一布局：卡片网格 / 单列列表 / 两列列表。
/// 各页面只需提供卡片与行两种内容，容器与切换逻辑统一由这里处理。
struct VideoFeedLayout<CardContent: View, RowContent: View>: View {
    var mode: VideoDisplayMode
    @ViewBuilder var cardContent: CardContent
    @ViewBuilder var rowContent: RowContent

    init(mode: VideoDisplayMode,
         @ViewBuilder cardContent: () -> CardContent,
         @ViewBuilder rowContent: () -> RowContent) {
        self.mode = mode
        self.cardContent = cardContent()
        self.rowContent = rowContent()
    }

    var body: some View {
        switch mode {
        case .card:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 16)],
                      spacing: 16) {
                cardContent
            }
        case .list:
            LazyVStack(spacing: 12) {
                rowContent
            }
        case .list2:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                rowContent
            }
        }
    }
}

/// 列表底部加载指示：只在真正请求时显示“加载中”，空闲时保持透明占位；
/// 没有更多内容时显示“没有更多内容了”作为到达末尾的反馈。
struct LoadMoreFooter: View {
    var isBusy: Bool
    var hasMore: Bool
    var onLoad: () async -> Void

    var body: some View {
        if hasMore {
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
        } else {
            Text("没有更多内容了")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }
}

extension View {
    /// 滚动接近底部时自动加载下一页：剩余可滚动距离不足 threshold（默认约两屏半）
    /// 即触发，并在加载完成后由内容高度变化自动接续下一页，
    /// 让内容始终领先滚动位置，实现快速下拉也“拉不到底”的连续加载体验。
    func autoLoadMore(threshold: CGFloat = 2000, load: @escaping () async -> Void) -> some View {
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
