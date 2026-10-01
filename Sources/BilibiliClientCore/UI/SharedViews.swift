import SwiftUI

enum FavoriteBehavior: String, CaseIterable, Identifiable {
    case defaultFolder, ask
    var id: String { rawValue }
    var label: String { self == .defaultFolder ? "默认收藏夹" : "每次选择" }
}

struct FavoritePickerView: View {
    let folders: [FavFolder]
    let onSelect: (FavFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择收藏夹").font(.headline)
            // 收藏夹可以有几十个，必须能滚动，否则靠后的收藏夹和「取消」会被裁掉够不到
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(folders) { folder in
                        Button {
                            onSelect(folder)
                        } label: {
                            HStack {
                                Text(folder.title ?? "未命名")
                                Spacer()
                                if let count = folder.mediaCount {
                                    Text("\(count)").foregroundStyle(.secondary)
                                }
                            }
                            // 44pt 行高，手机上更好点
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 380)
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        // 375pt 宽的机型上固定 360pt 会横向溢出
        .frame(maxWidth: 360)
    }
}

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder var cardContent: CardContent
    @ViewBuilder var rowContent: RowContent

    init(mode: VideoDisplayMode,
         @ViewBuilder cardContent: () -> CardContent,
         @ViewBuilder rowContent: () -> RowContent) {
        self.mode = mode
        self.cardContent = cardContent()
        self.rowContent = rowContent()
    }

    /// 双列列表在 iPhone 宽度下放不下：`MediaListRow` 的封面本身固定 132pt，
    /// 加间距与内边距后每列需要 ~170pt，而 iPhone 竖屏减去页面 `padding(20)` 后
    /// 单列只剩 ~170pt、两列各 ~85pt —— 标题/UP 主/播放量会被压成一条竖线。
    /// 所以紧凑宽度下把 `.list2` 降级成单列，而不是照常渲染。
    private var effectiveMode: VideoDisplayMode {
        if mode == .list2, horizontalSizeClass == .compact { return .list }
        return mode
    }

    var body: some View {
        switch effectiveMode {
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
/// 没有更多内容时显示“没有更多内容了”作为到达末尾的反馈；
/// 翻页失败时显示可点的一行“加载失败，点按重试”。
///
/// `failed` 由调用方显式传入（各页在 catch 里置位、开始下一次请求时清掉）：
/// 之前这里对失败完全静默，只有一块透明占位，移动网络下用户只能靠反复下拉
/// 才发现「底部加载没反应了」。
struct LoadMoreFooter: View {
    var isBusy: Bool
    var hasMore: Bool
    var failed = false
    var onLoad: () async -> Void
    var onRetry: (() async -> Void)?

    var body: some View {
        if hasMore {
            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } else if failed {
                Button {
                    guard let onRetry else { return }
                    Task { await onRetry() }
                } label: {
                    Label("加载失败，点按重试", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        // 一行也要有 44pt 的点击高度
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // 透明占位：保持 onAppear 兜底触发，视觉上无任何提示
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .onAppear {
                        Task { await onLoad() }
                    }
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

/// 流式换行布局：子视图自左向右排布，超出可用宽度自动换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : 0, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
