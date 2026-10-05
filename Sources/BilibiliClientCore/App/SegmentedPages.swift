#if os(iOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 分段页面容器：顶栏左上角的分段切换 + 板块内容。
///
/// **懒加载 + keep-alive**：选中的板块首次才实例化（不一上来三个信息流全打请求），
/// 之后切走只藏不删（opacity），滚动位置与已加载内容都保留——与 macOS 侧边栏
/// 「访问过就常驻」同一策略。
///
/// 左上角不再放页面标题（产品要求：去掉「推荐 / 热门 / 直播」这类页面名，
/// 内容直接呈现），那一格改放分段切换控件（`TopSegmentBar`）。
/// 首页与「我的」共用这一套，于是两页的形态完全一致。
struct SegmentedPages: View {
    let titles: [String]
    @Binding var selection: Int
    /// 各板块页面（用 AnyView 擦除类型：三个子页是不同类型，数组要一个统一元素类型）
    let pages: [AnyView]
    /// 已访问过的板块（keep-alive 名单）。初始值必须包含 `selection`：
    /// 启动参数可能直接指定某个板块，而 `onChange` 不会为初始值触发，
    /// 只写 `[0]` 会让初始板块根本没有实例（内容全空）。
    @State private var visited: Set<Int>

    init(titles: [String], selection: Binding<Int>, pages: [AnyView]) {
        self.titles = titles
        self._selection = selection
        self.pages = pages
        _visited = State(initialValue: [0, selection.wrappedValue])
    }

    var body: some View {
        ZStack {
            ForEach(visited.sorted(), id: \.self) { index in
                pages[index]
                    .opacity(selection == index ? 1 : 0)
                    .allowsHitTesting(selection == index)
                    .zIndex(selection == index ? 1 : 0)
            }
        }
        .onChange(of: selection) { _, newValue in
            visited.insert(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopSegmentBar(titles: titles, selection: $selection)
            }
            // 顶栏条目默认自带一层「共享玻璃」，会和这条控件自绘的玻璃叠成两层。
            // 关掉它，玻璃完全由 `TopSegmentBar` 自己给（见 `RootTopBar` 同处说明）。
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// 顶栏左上角的分段切换（首页 推荐/热门/直播、「我的」收藏/历史/稍后再看）。
///
/// 形态按参考图（B 站官方 App 顶栏）复刻，不再是玻璃融合：
/// - 整条托底一颗**浅色玻璃胶囊**（`.regular`，亮色页面近白、暗色自适应）；
/// - 选中项是一块**纯灰圆底**（`Color(.systemGray5)` 量级），文字一律深色——
///   参考图里选中态就是灰底黑字，不是玻璃高光；
/// - 灰底用 `matchedGeometryEffect` 在各段之间**滑动**（切换/拖动都是位移过渡），
///   不是原地淡入淡出。
///
/// **按住可以拖着走**（产品要求）：整条都是滑轨——按住横移超过 6pt 进入拖动，
/// 灰底跟手吸附到手指附近的段，每跨过一段震一下（`UISelectionFeedbackGenerator`）
/// 并立即改 `selection`；松手弹到最近的一段。纵向手势让给父级（列表滚动）不抢。
/// 段宽不等也能正确吸附：由 `NSString.size` 纯算术求宽，吸附判据是「灰底中心
/// 离哪段中心最近」。
///
/// **量宽不能用 `onGeometryChange` / `GeometryReader` 回写 `@State`**：在顶栏
/// `ToolbarItem` 里那样做会触发「测量 → 写 state → 重新布局 → 再测量」的循环，
/// 整条控件被横向撑到顶栏槽位宽度（实测背景一路糊到 x=899，三段文字被拉变形；
/// 基线应止于 x≈526）。`NSString.size(withAttributes:)` 不参与布局、没有副作用。
///
/// **`fixedSize()` 不能少**：实测顶栏会把这条控件横向压扁（文字被压成 0 宽、只剩
/// 两坨没字的胶囊），每个按钮和整条胶囊都定死尺寸才按内容宽摆放。
struct TopSegmentBar: View {
    let titles: [String]
    @Binding var selection: Int
    /// 选中灰底的几何：只挂在一个「占位」视图上，靠 id 在各段位置间滑动。
    @Namespace private var pillNamespace

    @State private var dragStartSelection = 0
    @State private var isDragging = false

    private let segmentSpacing: CGFloat = 2
    private let pillHeight: CGFloat = 30
    private let innerPadding: CGFloat = 3
    /// 每段文字左右各留的内边距（与 label 上的 `.padding(.horizontal, …)` 保持一致）
    private let labelPadding: CGFloat = 14

    /// 各段宽度（点）。文字用与 label 相同的字号/字重量，再加左右内边距。
    private var segmentWidths: [CGFloat] {
        titles.indices.map { index in
            let font = UIFont.systemFont(
               ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: selection == index ? .semibold : .regular)
            let width = (titles[index] as NSString).size(withAttributes: [.font: font]).width
            return ceil(width) + labelPadding * 2
        }
    }

    // MARK: - 几何

    /// 第 index 段在内容坐标系里的起始 x
    private func originX(_ index: Int) -> CGFloat {
        let widths = segmentWidths
        guard index > 0, widths.indices.contains(index - 1) else { return 0 }
        return widths.prefix(index).reduce(0, +) + segmentSpacing * CGFloat(index)
    }

    /// 灰底静止时第 index 段的中心 x
    private func centerX(_ index: Int) -> CGFloat {
        let widths = segmentWidths
        guard widths.indices.contains(index) else { return 0 }
        return originX(index) + widths[index] / 2
    }

    /// 把连续的 x 映射到「灰底中心离哪段中心最近」——段宽不等也能正确吸附。
    private func nearestSegment(center x: CGFloat) -> Int {
        let widths = segmentWidths
        guard !widths.isEmpty else { return selection }
        return titles.indices.min {
            abs(originX($0) + widths[$0] / 2 - x) < abs(originX($1) + widths[$1] / 2 - x)
        } ?? selection
    }

    // MARK: - 交互

    private func select(_ index: Int) {
        guard index != selection, titles.indices.contains(index) else { return }
        selectionHaptic()
        withAnimation(.snappy(duration: 0.28)) { selection = index }
    }

    /// 切段时那下轻震（系统分段控件的手感）。拖动中每跨过一段只震一次。
    private func selectionHaptic() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    /// 按住可以拖着走：整条胶囊都是滑轨。横移超过阈值即进入拖动，灰底跟手吸附
    /// 到手指附近的段，每跨过一段震一下并立即改 `selection`——灰底是**连续滑过去**
    /// 的，而不是等松手才跳；松手弹到最近一段。纵向为主时让给父级（列表滚动）。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard titles.count > 1 else { return }
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                guard horizontal > vertical else { return }
                if !isDragging {
                    isDragging = true
                    dragStartSelection = selection
                }
                let widths = segmentWidths
                let center = originX(dragStartSelection) + widths[dragStartSelection] / 2
                    + value.translation.width
                let target = nearestSegment(center: center)
                if target != selection {
                    selectionHaptic()
                    // 拖动中用短动画，灰底紧跟手指；松手再用一次回弹
                    withAnimation(.snappy(duration: 0.18)) { selection = target }
                }
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                withAnimation(.snappy(duration: 0.3)) {
                    selection = nearestSegment(center: centerX(selection))
                }
            }
    }

    // MARK: - 视图

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: segmentSpacing) {
                ForEach(titles.indices, id: \.self) { index in
                    Button { select(index) } label: {
                        Text(titles[index])
                            .font(.subheadline.weight(selection == index ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, labelPadding)
                            .frame(height: pillHeight)
                            .fixedSize()
                            // 选中灰底：占位放在文字**下面**，靠 matchedGeometryEffect
                            // 在各段间滑动（切换与拖动都是位移过渡）。
                            .background {
                                if selection == index {
                                    Capsule(style: .continuous)
                                        .fill(Color(.systemGray5).opacity(0.9))
                                        .matchedGeometryEffect(id: "segmentPill",
                                                               in: pillNamespace)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .fixedSize()
            .padding(innerPadding)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("segmentBar", in: pillNamespace)
        }
        .fixedSize()
        // 手势挂在 GlassEffectContainer 外层。挂在托底玻璃那一层会把它的命中区
        // 扩到顶栏槽位整幅宽度，连带把这层玻璃背景糊到 x=899、三段文字被拉变形。
        .gesture(dragGesture)
    }
}

/// 「首页」：顶栏左上角分段切 推荐 / 热门 / 直播。
struct HomeView: View {
    @State private var selection = LaunchArgs.initialSegment() ?? 0

    private static let segmentTitles = ["推荐", "热门", "直播"]

    var body: some View {
        SegmentedPages(titles: Self.segmentTitles,
                       selection: $selection,
                       pages: [AnyView(RecommendView()), AnyView(PopularView()), AnyView(LiveFeedView())])
    }
}
#endif
