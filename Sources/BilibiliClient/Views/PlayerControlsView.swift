import SwiftUI

/// 自研播放器控制条：替换 AVKit 系统控制条。
/// 显示后 3 秒自动落下隐藏；鼠标移动不唤起，仅点击画面可切换显隐。
struct PlayerControlsView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("playerBarStyle") private var barStyle = PlayerBarStyle.floating.rawValue
    /// 控制条可见性：由外部持有，单击视频画面可切换
    @Binding var controlsVisible: Bool
    /// 当前是否在全屏窗口内（决定全屏按钮图标与动作方向）
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    /// 松开滑块后等待 seek 完成期间，滑块保持显示的目标位置
    @State private var pendingSeek: Double?
    /// seek 序号：用于忽略被新 seek 打断的旧回调
    @State private var seekGeneration = 0
    @State private var seekTimeoutTask: Task<Void, Never>?

    /// 浮起/落下动画时长：集中定义，供点击切换调用点复用
    static let showAnimation = Animation.easeOut(duration: 0.15)
    static let hideAnimation = Animation.easeIn(duration: 0.2)

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            // 透明占位：点击穿透到视频层（PlayerLayerView 处理单击/双击）
            Color.clear
                .allowsHitTesting(false)

            controlBar
        }
        .onChange(of: controlsVisible) { _, newValue in
            if newValue { scheduleHide() }
        }
        .onAppear {
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
            seekTimeoutTask?.cancel()
            seekTimeoutTask = nil
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
                // 浮起动画：隐藏时下沉 14pt 并淡出，显示时滑回原位
                .offset(y: controlsVisible ? 0 : 14)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
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
                    seekTimeoutTask?.cancel()
                    seekTimeoutTask = nil
                    seekGeneration += 1
                    pendingSeek = nil
                    scrubValue = player.currentTime
                } else {
                    isScrubbing = false
                    waitForSeek(to: scrubValue)
                }
                bumpActivity()
            }
        )
        .controlSize(.small)
        .tint(.primary)
        .frame(maxWidth: .infinity)
    }

    /// 发起 seek，并在 seek 真正完成后释放滑块：首帧 seek 需要缓冲，
    /// 以完成回调为准，避免松开后滑块先回跳再瞬移。
    private func waitForSeek(to target: Double) {
        seekTimeoutTask?.cancel()
        seekGeneration += 1
        let gen = seekGeneration
        pendingSeek = target
        player.seek(to: target) { _ in
            Task { @MainActor in
                if gen == seekGeneration {
                    pendingSeek = nil
                }
            }
        }
        // 兜底：seek 无法完成（如目标不可达）时也释放滑块
        seekTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, gen == seekGeneration {
                pendingSeek = nil
            }
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
        // 交互（点按钮/拖进度条）后重新计时；鼠标悬停不再触发
        if !controlsVisible {
            withAnimation(Self.showAnimation) {
                controlsVisible = true
            }
        }
        scheduleHide()
    }

    /// 控制条显示 3 秒后自动落下隐藏（无视鼠标移动）
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, controlsVisible, !isScrubbing else { return }
            withAnimation(Self.hideAnimation) {
                controlsVisible = false
            }
        }
    }
}
