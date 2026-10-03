import SwiftUI

/// 供 macOS App 目标挂进系统 `Settings` 场景的入口。
///
/// `SettingsView` 及其依赖（SessionStore 等）都在共享层内部组装好再交出去，
/// App 目标只负责把系统托管的设置窗口指到这里（Finder / Safari 同款官方做法）。
public struct SystemSettingsRoot: View {
    public init() {}

    public var body: some View {
        SettingsView()
            .environmentObject(SessionStore.shared)
            // 系统默认给到 900 宽，对这份设置内容太宽了。收窄到 Finder/Safari
            // 设置窗一档（520pt），高度 560：首屏能看到大部分分组，剩下的在
            // SettingsView 自带的 ScrollView 里滚动，窗口本身仍由系统托管、不可拉伸。
            .frame(width: 520, height: 560)
    }
}
