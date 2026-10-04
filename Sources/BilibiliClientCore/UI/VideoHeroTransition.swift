import SwiftUI

/// 视频卡片 → 详情页的「App Store 式」zoom 转场（仅 iOS）。
///
/// 现象与动机：点视频卡片时，系统 `NavigationStack` 的默认 push 是「详情页从右侧滑入」，
/// 与 App Store「封面从卡片原地放大铺满、退出时缩回卡片」的观感不同。
/// 用 iOS 18 的 `matchedTransitionSource`（源端：卡片）+ `navigationTransition(.zoom)`
/// （目的端：详情页）即可让进入与退出共用同一个缩放动画 —— 返回按钮与侧滑都自动反播。
///
/// 关键约束：
/// - **命名空间按导航栈一份**（`RootView.TabNavStack` 注入）：keep-alive 下多个标签栈同时
///   存活，同一个视频可能同时出现在「推荐」与「热门」里，共用一个 namespace 会产生
///   重复的源 id，动画会认错源。
/// - 源端拿不到 namespace（理论上不会发生）就退回原样 push，绝不因此崩或静默吃掉跳转。
/// - macOS 不参与：侧边栏 + 分栏是另一套交互，这里全部是空实现。
struct VideoHeroID: Hashable {
    let bvid: String
}

#if os(iOS)
private struct VideoHeroNSKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// 本导航栈专属的 hero 命名空间；由 `RootView.TabNavStack` 注入。
    var videoHeroNS: Namespace.ID? {
        get { self[VideoHeroNSKey.self] }
        set { self[VideoHeroNSKey.self] = newValue }
    }
}

extension View {
    /// 源端：挂在承载 bvid 的 `NavigationLink` 上，声明「zoom 从这张卡片出发」。
    func videoHeroSource(_ bvid: String) -> some View {
        modifier(VideoHeroSource(bvid: bvid))
    }

    /// 目的端：挂在 `navigationDestination` 里的详情页上，声明「zoom 落到这里」。
    func videoHeroDestination(_ bvid: String, in ns: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: VideoHeroID(bvid: bvid), in: ns))
    }
}

private struct VideoHeroSource: ViewModifier {
    let bvid: String
    @Environment(\.videoHeroNS) private var ns

    func body(content: Content) -> some View {
        // 空 bvid（部分列表项 bvid 可能缺）与无 namespace 都退回原样 push。
        if let ns, !bvid.isEmpty {
            content.matchedTransitionSource(id: VideoHeroID(bvid: bvid), in: ns)
        } else {
            content
        }
    }
}
#else
extension EnvironmentValues {
    /// macOS 上无意义，但 `TabNavStack` 两端共用注入语句，给个可写的空壳。
    var videoHeroNS: Namespace.ID? {
        get { nil }
        set {}
    }
}

extension View {
    func videoHeroSource(_ bvid: String) -> some View { self }
    func videoHeroDestination(_ bvid: String, in ns: Namespace.ID) -> some View { self }
}
#endif
