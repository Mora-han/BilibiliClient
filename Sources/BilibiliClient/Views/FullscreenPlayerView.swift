import AppKit
import AVFoundation
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

/// 全屏播放窗口管理：负责创建、进入/退出系统全屏、清理。
final class FullscreenPlayerWindow {
    private var window: NSWindow?

    var isOpen: Bool { window != nil }

    /// 打开全屏窗口。
    func open(player: AVPlayer,
              engine: DanmakuEngine,
              danmakuEnabled: Binding<Bool>,
              onClosed: @escaping () -> Void) {
        guard window == nil else { return }

        let closeAction: () -> Void = { [weak self] in
            self?.exitFullscreen()
        }
        let hosting = NSHostingView(rootView: FullscreenPlayerView(player: player,
                                                                   engine: engine,
                                                                   danmakuEnabled: danmakuEnabled,
                                                                   onClose: closeAction))
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = hosting
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        self.window = window

        // 退出全屏动画结束后统一清理
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                               object: window,
                                               queue: .main) { [weak self] _ in
            self?.finishClose()
            onClosed()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window,
                                               queue: .main) { [weak self] _ in
            guard self?.window != nil else { return }
            self?.window = nil
            onClosed()
        }

        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // 等窗口先完成布局再进入全屏，避免动画不触发
        DispatchQueue.main.async {
            window.toggleFullScreen(nil)
        }
    }

    /// 退出全屏（按钮/Esc 触发）。
    func exitFullscreen() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            finishClose()
        }
    }

    /// 立即关闭并清空（详情页离开时兜底）。
    func forceClose() {
        finishClose()
    }

    private func finishClose() {
        guard let window else { return }
        self.window = nil
        window.contentView = nil
        window.close()
    }
}
