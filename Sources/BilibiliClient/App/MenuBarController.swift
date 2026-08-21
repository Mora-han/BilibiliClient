import AppKit
import SwiftUI

/// 菜单栏图标控制器：点击图标弹出用户信息 + 动态卡片。
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.fill",
                                   accessibilityDescription: "Bilibili Client")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item

        let rootView = MenuBarPanelView(
            session: SessionStore.shared,
            router: AppRouter.shared,
            onOpenVideo: { [weak self] bvid in
                self?.popover?.performClose(nil)
                AppRouter.shared.openVideo(bvid)
            }
        )
        .environmentObject(SessionStore.shared)
        let controller = NSHostingController(rootView: AnyView(rootView))
        hostingController = controller

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 380, height: 540)
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let statusItem, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
