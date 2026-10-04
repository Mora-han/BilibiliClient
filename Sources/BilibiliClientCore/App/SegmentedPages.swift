#if os(iOS)
import SwiftUI

/// 分段页面容器：顶栏左上角的液态玻璃分段切换 + 板块内容。
///
/// **懒加载 + keep-alive**：选中的板块首次才实例化（不一上来三个信息流全打请求），
/// 之后切走只藏不删（opacity），滚动位置与已加载内容都保留——与 macOS 侧边栏
/// 「访问过就常驻」同一策略。
///
/// 左上角不再放页面标题（产品要求：去掉「推荐 / 热门 / 直播」这类页面名，
/// 内容直接呈现），那一格改放分段切换控件（`TopGlassSegmentBar`）。
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
                TopGlassSegmentBar(titles: titles, selection: $selection)
            }
            // 顶栏条目默认自带一层「共享玻璃」，会和这条控件自绘的玻璃叠成两层。
            // 关掉它，玻璃完全由 `TopGlassSegmentBar` 自己给（见 `RootTopBar` 同处说明）。
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// 顶栏左上角的液态玻璃分段切换（首页 推荐/热门/直播、「我的」收藏/历史/稍后再看）。
///
/// 形态按顶栏那套原生玻璃来做：
/// - `GlassEffectContainer` 是 iOS 26 的玻璃容器，容器内的玻璃形状能相互**融合/变形**；
/// - 整条胶囊托底一颗 `.regular` 玻璃；
/// - 选中项自己再叠一颗 `.regular` 玻璃药丸，未选中用 `.clear`（占位但透明），
///   两者共用同一个 `glassEffectID`，于是**切换时玻璃药丸是「挪过去」的**（系统做的
///   形变 + 高光过渡），而不是原地淡入淡出——这就是顶栏那种液态玻璃切换手感；
/// - `.interactive()` 让玻璃跟手指有弹性反馈。
///
/// **`fixedSize()` 不能少**：实测顶栏会把这条控件横向压扁（文字被压成 0 宽、只剩两坨
/// 没字的胶囊），每个按钮和整条胶囊都定死尺寸才按内容宽摆放。
struct TopGlassSegmentBar: View {
    let titles: [String]
    @Binding var selection: Int
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(titles.indices, id: \.self) { index in
                    Button {
                        guard selection != index else { return }
                        withAnimation(.snappy(duration: 0.28)) { selection = index }
                    } label: {
                        Text(titles[index])
                            .font(.subheadline.weight(selection == index ? .semibold : .regular))
                            .foregroundStyle(selection == index ? Color.primary : Color.secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .glassEffect(selection == index
                                 ? .regular.interactive()
                                 : .clear,
                                 in: .capsule)
                    .glassEffectID("segmentSelection", in: namespace)
                }
            }
            .fixedSize()
            .padding(3)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("segmentBar", in: namespace)
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
                       pages: [AnyView(RecommendView()), AnyView(PopularView()), AnyView(LiveFeedView())])
    }
}
#endif
