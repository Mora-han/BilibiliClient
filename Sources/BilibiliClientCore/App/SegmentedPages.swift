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
        VStack(spacing: 0) {
            TopSegmentBar(titles: titles, selection: $selection)

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
        // 标题跟分段走。子页面各自也声明了同名 navigationTitle（标题文本一致），
        // 这里在外层再钉一次，保证标题只由当前选中项决定。
        .navigationTitle(titles[selection])
    }
}

/// 「首页」：顶部分段栏切 推荐 / 热门 / 直播。
struct HomeView: View {
    @State private var selection = LaunchArgs.initialSegment() ?? 0

    var body: some View {
        SegmentedPages(titles: ["推荐", "热门", "直播"],
                       selection: $selection,
                       pages: [AnyView(RecommendView()), AnyView(PopularView()), AnyView(LiveFeedView())])
    }
}
#endif
