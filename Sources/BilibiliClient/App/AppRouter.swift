import AppKit
import SwiftUI

/// 全局导航路由：供菜单栏卡片等“主界面之外”的位置触发主窗口跳转。
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// 主窗口详情区的导航路径
    @Published var path = NavigationPath()

    /// 跳转到指定视频详情：激活主窗口并推入对应页面。
    func openVideo(_ bvid: String) {
        path.append(bvid)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
