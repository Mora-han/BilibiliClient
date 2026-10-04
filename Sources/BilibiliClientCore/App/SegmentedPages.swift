#if os(iOS)
import SwiftUI

/// Apple Music 式的顶部分段胶囊栏：页面内二级板块切换。
/// 首页用它切「推荐 / 热门 / 直播」，「我的」用它切「收藏 / 历史 / 稍后再看」。
///
/// 固定在导航栏下方、**不随内容滚动**；选中项是实心胶囊 + 半透明底，未选中只留文字。
struct TopSegmentBar: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    guard selection != index else { return }
                    withAnimation(.snappy(duration: 0.22)) { selection = index }
                } label: {
                    Text(titles[index])
                        .font(.callout.weight(selection == index ? .semibold : .regular))
                        .foregroundStyle(selection == index ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background {
                            if selection == index {
                                Capsule().fill(Color.primary.opacity(0.08))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// 分段页面容器：顶部分段栏 + 板块内容。
///
/// **懒加载 + keep-alive**：选中的板块首次才实例化（不一上来三个信息流全打请求），
/// 之后切走只藏不删（opacity），滚动位置与已加载内容都保留——与 macOS 侧边栏
/// 「访问过就常驻」同一策略。
struct SegmentedPages: View {
    let titles: [String]
    @Binding var selection: Int
    /// 各板块页面（用 AnyView 擦除类型：三个子页是不同类型，数组要一个统一元素类型）
    let pages: [AnyView]
    /// 是否在导航栏下方摆这条分段栏。
    ///
    /// 首页把它搬进了**顶栏左上角**（`HomeView` + `TopGlassSegmentBar`，液态玻璃胶囊），
    /// 置 false；「我的」保持原样，仍贴在导航栏下方。
    let showsInlineBar: Bool
    /// 已访问过的板块（keep-alive 名单）。初始值必须包含 `selection`：
    /// 启动参数可能直接指定某个板块，而 `onChange` 不会为初始值触发，
    /// 只写 `[0]` 会让初始板块根本没有实例（内容全空）。
    @State private var visited: Set<Int>

    init(titles: [String], selection: Binding<Int>, pages: [AnyView],
         showsInlineBar: Bool = true) {
        self.titles = titles
        self._selection = selection
        self.pages = pages
        self.showsInlineBar = showsInlineBar
        _visited = State(initialValue: [0, selection.wrappedValue])
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsInlineBar {
                TopSegmentBar(titles: titles, selection: $selection)
            }

            ZStack {
                ForEach(visited.sorted(), id: \.self) { index in
                    pages[index]
                        .opacity(selection == index ? 1 : 0)
                        .allowsHitTesting(selection == index)
                        .zIndex(selection == index ? 1 : 0)
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            visited.insert(newValue)
        }
        // 左上角不放页面标题（产品要求：去掉「推荐 / 热门 / 直播」这类页面名，
        // 内容直接呈现）。原先这里 .navigationTitle(titles[selection]) 已删除，
        // 分段切换改由顶栏左上角的玻璃控件承担（见 HomeView）。
    }
}

/// 首页顶栏**左上角**的液态玻璃分段切换：推荐 / 热门 / 直播。
///
/// 形态按 iOS 26 的玻璃分段控件：外层一颗液态玻璃胶囊托底，选中项在自己那格再叠一层
/// 玻璃浮起，切换用 `withAnimation(.snappy)` 过渡。
/// 只挂在首页根页的 `.topBarLeading` 上（见 `HomeView.body`），推入详情页后自然收起。
///
/// **`fixedSize()` 不能少**：实测顶栏会把这条控件横向压扁（文字被压成 0 宽、只剩两坨
/// 没字的胶囊），每个按钮和整条胶囊都定死尺寸才按内容宽摆放。
struct TopGlassSegmentBar: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    guard selection != index else { return }
                    withAnimation(.snappy(duration: 0.25)) { selection = index }
                } label: {
                    Text(titles[index])
                        .font(.subheadline.weight(selection == index ? .semibold : .regular))
                        .foregroundStyle(selection == index ? Color.primary : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .fixedSize()
                        .background {
                            if selection == index {
                                Capsule()
                                    .fill(Color.primary.opacity(0.10))
                                    .glassEffect(.regular, in: .capsule)
                            }
                        }
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .fixedSize()
        .padding(3)
        .background {
            Capsule()
                .fill(.white.opacity(0.05))
                .glassEffect(.regular, in: .capsule)
        }
    }
}

/// 「首页」：顶栏左上角玻璃分段切 推荐 / 热门 / 直播。
struct HomeView: View {
    @State private var selection = LaunchArgs.initialSegment() ?? 0

    private static let segmentTitles = ["推荐", "热门", "直播"]

    var body: some View {
        SegmentedPages(titles: Self.segmentTitles,
                       selection: $selection,
                       pages: [AnyView(RecommendView()), AnyView(PopularView()), AnyView(LiveFeedView())],
                       showsInlineBar: false)
            // 分段搬到顶栏左上角（替代原来的页面大标题）
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopGlassSegmentBar(titles: Self.segmentTitles, selection: $selection)
                }
            }
    }
}
#endif
