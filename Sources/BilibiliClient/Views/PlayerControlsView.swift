import SwiftUI

/// 自研播放器控制条：替换 AVKit 系统控制条。
/// 鼠标活动时显示，静止数秒后淡出；所有交互都走 PlayerController。
struct PlayerControlsView: View {
    @ObservedObject var player: PlayerController
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    /// 当前是否在全屏窗口内（决定全屏按钮图标与动作方向）
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var controlsVisible = true
    @State private var hideTimer: Timer?
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var volume: Double = 1
    /// 鼠标活动时间戳（普通引用，不触发 SwiftUI 更新，避免高频 hover 重绘）
    @State private var monitor = InteractionMonitor()

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
        .onAppear {
            volume = Double(player.player?.volume ?? 1)
            startHideTimer()
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
        }
    }

    // MARK: - 控制条

    private var controlBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                playbackButton
                skipButton(-15)
                skipButton(15)

                Text(Formatters.duration(Int(player.currentTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Text(Formatters.duration(Int(max(player.duration, 0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))

                progressSlider

                volumeControl
                qualityMenu
                DanmakuToggleButton(isOn: $danmakuEnabled)
                fullscreenButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { bumpActivity() }
            .background {
                LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.2)],
                               startPoint: .bottom, endPoint: .top)
            }
        }
    }

    private var playbackButton: some View {
        Button {
            bumpActivity()
            player.togglePlay()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "暂停" : "播放")
    }

    private func skipButton(_ seconds: Double) -> some View {
        Button {
            bumpActivity()
            player.skip(by: seconds)
        } label: {
            Image(systemName: seconds < 0 ? "gobackward.15" : "goforward.15")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(seconds < 0 ? "后退 15 秒" : "前进 15 秒")
    }

    private var progressSlider: some View {
        Slider(
            value: Binding(
                get: { isScrubbing ? scrubValue : player.currentTime },
                set: { scrubValue = $0 }
            ),
            in: 0...max(player.duration, 1),
            onEditingChanged: { editing in
                if editing {
                    isScrubbing = true
                    scrubValue = player.currentTime
                } else {
                    isScrubbing = false
                    player.seek(to: scrubValue)
                }
                bumpActivity()
            }
        )
        .controlSize(.small)
        .tint(.white)
        .frame(maxWidth: .infinity)
    }

    private var volumeControl: some View {
        HStack(spacing: 4) {
            Image(systemName: volume == 0
                  ? "speaker.slash.fill"
                  : (volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                .font(.system(size: 11))
                .foregroundStyle(.white)
            Slider(value: $volume, in: 0...1, onEditingChanged: { editing in
                if !editing { bumpActivity() }
            })
            .onChange(of: volume) { _, newValue in
                player.setVolume(newValue)
            }
            .controlSize(.small)
            .tint(.white)
            .frame(width: 70)
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
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.18)))
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
                .foregroundStyle(.white)
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
