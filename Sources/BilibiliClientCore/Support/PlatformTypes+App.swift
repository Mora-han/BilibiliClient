import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// DanmakuKit 的 PlatformTypes.swift 已经提供 PlatformView / PlatformScreen /
// PlatformColor / PlatformPoint / PlatformViewRepresentable（同一 target 内可直接用）。
// 这里补上 App 层还缺的几个，命名风格保持一致。

#if os(macOS)
public typealias PlatformImage = NSImage
#else
public typealias PlatformImage = UIImage
#endif

extension Image {
    /// 平台无关的图片构造：macOS 用 `nsImage:`，iOS 用 `uiImage:`。
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension Color {
    /// 设置里「实色卡片」的背景色。
    ///
    /// macOS 一直用 `controlBackgroundColor`；iOS 没有这个系统色，取语义最接近的
    /// `secondarySystemBackground`（同样是「比窗口背景略深一档的可滚动内容底色」）。
    static var cardSolidBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

/// 平台能力差异的统一判定点，业务代码只问这里，不直接散落 `#if os(...)`。
public enum AppPlatform {
    /// 是否存在「窗口 / 菜单栏 / Dock」这套窗口管理概念。
    /// macOS 有，因此「关闭窗口后行为（完全退出 / 菜单栏模式 / 每次询问）」
    /// 「菜单栏常驻」「分离为独立窗口」都只在 macOS 出现；iOS 全部隐藏。
    public static var hasWindowManagement: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// 是否是 iPhone（iPad 上的二维码可以直接用 iPhone 扫，iPhone 上只能借别的设备）。
    public static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// 悬停时把鼠标光标换成手型。iOS 没有光标概念（iPad 接触控板时也不换），直接无操作。
    public static func setPointingHandCursor(_ hovering: Bool) {
        #if os(macOS)
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
        #endif
    }

    /// 用系统默认浏览器 / 外部应用打开链接。
    @MainActor
    public static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - 字体 / 屏幕 / 颜色构造

#if os(macOS)
public typealias PlatformFont = NSFont
#else
public typealias PlatformFont = UIFont
#endif

extension PlatformColor {
    /// sRGB 分量构造：macOS 是 `NSColor(srgbRed:…)`，iOS 是 `UIColor(red:…)`（同为 sRGB）。
    static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> PlatformColor {
        #if os(macOS)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}

extension PlatformScreen {
    /// 主屏缩放倍率（弹幕位图的栅格化密度）。
    /// macOS 的 `NSScreen.main` 可选、iOS 的 `UIScreen.main` 不可选，封一层免得各处分叉。
    /// 主屏缩放倍率。`fallback` 是拿不到主屏时的兜底值 —— 各调用点保留自己原本的兜底，
    /// 这样 macOS 的行为与改造前逐位一致（`DanmakuEngine` 用 2，`DanmakuAsyncLayer` 用 1）。
    static func mainScale(fallback: CGFloat) -> CGFloat {
        #if os(macOS)
        NSScreen.main?.backingScaleFactor ?? fallback
        #else
        // iOS 26 起 `UIScreen.main` 废弃，改从 trait 取；拿不到（=0）时用调用点兜底值
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : fallback
        #endif
    }
}

extension PlatformView {
    /// 清空自身背景，只保留子层内容。
    /// macOS 的 `NSView` 要先 `wantsLayer` 才有 layer；iOS 的 `UIView` 一直有。
    func applyClearLayerBackground() {
        #if os(macOS)
        wantsLayer = true
        layer?.backgroundColor = PlatformColor.clear.cgColor
        #else
        backgroundColor = .clear
        #endif
    }

    /// 同上，但同时裁掉超出 bounds 的子层。
    func applyClearClippingLayerBackground() {
        #if os(macOS)
        wantsLayer = true
        layer?.backgroundColor = PlatformColor.clear.cgColor
        layer?.masksToBounds = true
        #else
        backgroundColor = .clear
        layer.masksToBounds = true
        #endif
    }
}

extension PlatformView {
    /// 与平台无关地取 backing layer。
    /// macOS 的 `NSView.layer` 是可选（要先 `wantsLayer`），iOS 的 `UIView.layer` 不可选。
    var backingLayer: CALayer? {
        #if os(macOS)
        layer
        #else
        layer
        #endif
    }

    /// 所在窗口的缩放倍率（弹幕位图的栅格化密度）。
    /// macOS 是 `NSWindow.backingScaleFactor`，iOS 取 `UITraitCollection.displayScale`。
    var windowScale: CGFloat? {
        #if os(macOS)
        window?.backingScaleFactor
        #else
        window?.traitCollection.displayScale
        #endif
    }
}

extension PlatformView {
    /// 视图透明度：macOS 是 `alphaValue`，iOS 是 `alpha`。
    var viewAlpha: CGFloat {
        get {
            #if os(macOS)
            alphaValue
            #else
            alpha
            #endif
        }
        set {
            #if os(macOS)
            alphaValue = newValue
            #else
            alpha = newValue
            #endif
        }
    }
}
