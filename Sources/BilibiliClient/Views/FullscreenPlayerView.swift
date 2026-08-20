import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// 全屏播放窗口的内容：播放器 + 弹幕层 + 弹幕开关 + 退出全屏按钮。
/// 复用同一个 AVPlayer 与 DanmakuEngine，进入/退出全屏时播放不中断。
struct FullscreenPlayerView: View {
    let player: AVPlayer
    @ObservedObject var engine: DanmakuEngine
    @Binding var danmakuEnabled: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
            PlayerView(player: player)
                .overlay {
                    DanmakuOverlayView(engine: engine,
                                       player: player,
                                       enabled: danmakuEnabled,
                                       suspended: false)
                }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                DanmakuToggleButton(isOn: $danmakuEnabled)
                FullscreenExitButton {
                    onClose()
                }
            }
            .padding(14)
        }
        .onExitCommand {
            onClose()
        }
    }
}

/// 内嵌播放器上的“进入全屏”按钮（与弹幕开关同款液态玻璃胶囊）。
struct FullscreenEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(.black.opacity(0.35))
                        .overlay {
                            if #available(macOS 26.0, *) {
                                Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                                    .glassEffect(.regular, in: .capsule)
                            } else {
                                Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                            }
                        }
                }
        }
        .buttonStyle(.plain)
        .help("进入全屏")
    }
}

/// 退出全屏按钮（与弹幕开关同款液态玻璃胶囊）。
struct FullscreenExitButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text("退出全屏")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.black.opacity(0.35))
                    .overlay {
                        if #available(macOS 26.0, *) {
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                                .glassEffect(.regular, in: .capsule)
                        } else {
                            Capsule().stroke(.white.opacity(0.25), lineWidth: 1)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .help("退出全屏（Esc）")
    }
}

/// 全屏播放窗口管理：模仿 Safari 视频全屏——
/// 窗口从内嵌播放器的屏幕位置平滑放大到整屏，退出时再缩回原位。
/// 全程使用同一个 AVPlayer 与 DanmakuEngine，播放不中断。
final class FullscreenPlayerWindow {
    private var window: NSWindow?
    private var sourceRect: CGRect = .zero
    private var onClosed: (() -> Void)?
    private var lifecycleObservers: [NSObjectProtocol] = []

    var isOpen: Bool { window != nil }

    /// 打开全屏窗口。
    func open(player: AVPlayer,
              engine: DanmakuEngine,
              danmakuEnabled: Binding<Bool>,
              sourceRect: CGRect,
              onClosed: @escaping () -> Void) {
        guard window == nil else { return }
        self.sourceRect = sourceRect
        self.onClosed = onClosed

        let targetScreen = NSScreen.screens.first { $0.frame.intersects(sourceRect) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let startRect = sourceRect.isEmpty ? (targetScreen?.frame ?? .zero) : sourceRect
        guard !startRect.isEmpty, let targetScreen else {
            onClosed()
            self.onClosed = nil
            return
        }

        let hosting = NSHostingView(rootView: FullscreenPlayerView(player: player,
                                                                   engine: engine,
                                                                   danmakuEnabled: danmakuEnabled,
                                                                   onClose: { [weak self] in
                                                                       self?.exit()
                                                                   }))
        let window = NSWindow(contentRect: startRect,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = hosting
        self.window = window

        // 模拟真全屏：隐藏菜单栏与 Dock
        NSApp.presentationOptions = [.hideMenuBar, .hideDock]

        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        // 平滑放大到整屏（Safari 式视频跟随放大）
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetScreen.frame, display: true)
        }

        registerLifecycleObservers()
    }

    /// 退出全屏：缩回内嵌播放器原位后关闭。
    func exit() {
        guard let window else { return }
        NSApp.presentationOptions = []
        let backRect = sourceRect.isEmpty ? window.frame : sourceRect
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(backRect, display: true)
        }, completionHandler: { [weak self] in
            self?.finishClose()
        })
    }

    /// 立即关闭（页面离开等兜底场景）。
    func forceClose() {
        NSApp.presentationOptions = []
        finishClose()
    }

    private func finishClose() {
        guard let window else { return }
        self.window = nil
        window.contentView = nil
        window.close()
        removeLifecycleObservers()
        onClosed?()
        onClosed = nil
    }

    // MARK: - 菜单栏 / Dock 随应用激活状态恢复

    private func registerLifecycleObservers() {
        let resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            guard self?.window != nil else { return }
            NSApp.presentationOptions = []
        }
        let become = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            guard self?.window != nil else { return }
            NSApp.presentationOptions = [.hideMenuBar, .hideDock]
        }
        lifecycleObservers = [resign, become]
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []
    }
}

