import AppKit
import SwiftUI

/// 菜单栏图标控制器：点击图标弹出用户信息 + 动态卡片。
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hostingController: NSViewController?

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

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 540)
        self.popover = popover
    }

    private func makePanelController() -> NSViewController {
        let rootView = MenuBarPanelView(
            session: SessionStore.shared,
            router: AppRouter.shared,
            onOpenVideo: { [weak self] bvid in
                self?.popover?.performClose(nil)
                AppRouter.shared.openVideo(bvid)
            },
            onOpenApp: { [weak self] in
                self?.popover?.performClose(nil)
                AppRouter.shared.openMain()
            }
        )
        .environmentObject(SessionStore.shared)
        return NSHostingController(rootView: rootView)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let statusItem, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            if popover.contentViewController == nil {
                let controller = makePanelController()
                hostingController = controller
                popover.contentViewController = controller
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        // 菜单栏图标继续常驻，但关闭面板后释放 SwiftUI 视图树、动态数据和图片引用。
        popover?.contentViewController = nil
        hostingController = nil
        URLCache.shared.removeAllCachedResponses()
    }
}
