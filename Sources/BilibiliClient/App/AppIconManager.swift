import AppKit

/// 让 Dock 图标跟随 App 自身的外观设置（跟随系统 / 浅色 / 深色）。
///
/// 打包的 AppIcon.icns 内含系统级深色变体（Finder 与未运行时的 Dock 随系统外观切换），
/// 但 App 内部可以独立选择外观，这里在运行时显式覆盖 Dock 图标，
/// 使图标与 App 当前主题保持一致。
final class AppIconManager {
    private let light: NSImage?
    private let dark: NSImage?
    private var appearanceObserver: NSKeyValueObservation?

    init() {
        light = AppIconManager.loadImage(named: "AppIcon")
        dark = AppIconManager.loadImage(named: "AppIcon-dark")
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.update()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(update),
            name: UserDefaults.didChangeNotification, object: nil
        )
        update()
    }

    @objc private func update() {
        let mode = UserDefaults.standard.string(forKey: "appearance") ?? AppearanceMode.system.rawValue
        switch mode {
        case AppearanceMode.light.rawValue:
            NSApp.applicationIconImage = light
        case AppearanceMode.dark.rawValue:
            NSApp.applicationIconImage = dark
        default:
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSApp.applicationIconImage = isDark ? dark : light
        }
    }

    private static func loadImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
}
