import SwiftUI

/// 自研播放器控制条：替换 AVKit 系统控制条。
/// 鼠标活动时显示，静止数秒后淡出；所有交互都走 PlayerController。
struct PlayerControlsView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("playerBarStyle") private var barStyle = PlayerBarStyle.floating.rawValue
    /// 当前是否在全屏窗口内（决定全屏按钮图标与动作方向）
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var controlsVisible = true
    @State private var hideTimer: Timer?
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    /// 松开滑块后等待 seek 完成期间，滑块保持显示的目标位置
    @State private var pendingSeek: Double?
    @State private var seekTask: Task<Void, Never>?
    /// 鼠标活动时间戳（普通引用，不触发 SwiftUI 更新，避免高频 hover 重绘）
    @State private var monitor = InteractionMonitor()

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // 透明占位：点击穿透到视频层（PlayerLayerView 处理单击/双击），
            // 同时保持 hover 区域覆盖整个播放器
            Color.clear
                .allowsHitTesting(false)

            if controlsVisible {
                controlBar
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active, .ended:
                bumpActivity()
            }
        }
        .onAppear(perform: startHideTimer)
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
            seekTask?.cancel()
            seekTask = nil
        }
    }

    // MARK: - 控制条

    private var controlBar: some View {
        VStack {
            Spacer()
            barContent
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { bumpActivity() }
                .background {
                    if barStyle == PlayerBarStyle.floating.rawValue {
                        // 悬浮样式：圆角液态玻璃
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isDark ? .black.opacity(0.35) : .white.opacity(0.25))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(.primary.opacity(0.12), lineWidth: 1)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                            }
                    } else {
                        // 沉底样式：经典渐变贴边
                        LinearGradient(colors: isDark
                                       ? [.black.opacity(0.65), .black.opacity(0.2)]
                                       : [.white.opacity(0.8), .white.opacity(0.3)],
                                       startPoint: .bottom, endPoint: .top)
                    }
                }
                // 悬浮：收窄成居中胶囊并抬高；沉底：贴底通栏
                .frame(maxWidth: barStyle == PlayerBarStyle.floating.rawValue ? 580 : .infinity)
                .padding(.bottom, barStyle == PlayerBarStyle.floating.rawValue ? 18 : 0)
        }
    }

    private var barContent: some View {
        HStack(spacing: 10) {
            playbackButton

            Text(Formatters.duration(Int(player.currentTime)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
            Text("/")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Formatters.duration(Int(max(player.duration, 0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            progressSlider

            qualityMenu
            DanmakuToggleButton(isOn: $danmakuEnabled)
            fullscreenButton
        }
    }

    private var playbackButton: some View {
        Button {
            bumpActivity()
            player.togglePlay()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "暂停" : "播放")
    }

    private var progressSlider: some View {
        Slider(
            value: Binding(
                get: {
                    // 松开后目标位置未确认前保持显示拖到的位置，避免滑块回跳再瞬移
                    if isScrubbing { return scrubValue }
                    if let target = pendingSeek { return target }
                    return player.currentTime
                },
                set: { scrubValue = $0 }
            ),
            in: 0...max(player.duration, 1),
            onEditingChanged: { editing in
                if editing {
                    isScrubbing = true
                    seekTask?.cancel()
                    seekTask = nil
                    pendingSeek = nil
                    scrubValue = player.currentTime
                } else {
                    isScrubbing = false
                    player.seek(to: scrubValue)
                    waitForSeek(to: scrubValue)
                }
                bumpActivity()
            }
        )
        .controlSize(.small)
        .tint(.primary)
        .frame(maxWidth: .infinity)
    }

    /// 轮询播放时间直到到达目标位置后清除 pendingSeek，让滑块平滑停在目标处。
    private func waitForSeek(to target: Double) {
        seekTask?.cancel()
        pendingSeek = target
        seekTask = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                let t = player.player?.currentTime().seconds ?? 0
                if t.isFinite, abs(t - target) < 0.15 { break }
            }
            pendingSeek = nil
        }
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(player.qualities) { quality in
                Button {
                    Task { await player.selectQuality(quality) }
                } label: {
                    if quality.id == player.currentQualityId {
                        Label(quality.name, systemImage: "checkmark")
                    } else {
                        Text(quality.name)
                    }
                }
            }
        } label: {
            Text(player.currentQualityName ?? "清晰度")
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.primary.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("清晰度")
    }

    private var fullscreenButton: some View {
        Button {
            bumpActivity()
            onToggleFullscreen()
        } label: {
            Image(systemName: isFullscreen
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(isFullscreen ? "退出全屏" : "全屏")
    }

    // MARK: - 自动隐藏

    private func bumpActivity() {
        monitor.lastActivity = Date()
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                controlsVisible = true
            }
        }
    }

    private func startHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard controlsVisible, !isScrubbing else { return }
                if Date().timeIntervalSince(monitor.lastActivity) > 3 {
                    withAnimation(.easeOut(duration: 0.25)) {
                        controlsVisible = false
                    }
                }
            }
        }
    }

    /// 鼠标活动记录：普通类实例，修改属性不会触发视图更新。
    private final class InteractionMonitor {
        var lastActivity = Date()
    }
}
