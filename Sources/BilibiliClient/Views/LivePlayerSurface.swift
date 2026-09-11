import SwiftUI

/// 直播播放组件：黑底 + AVPlayerLayer 直播画面 + 简化控制条 + 在线人数徽标。
/// 与 `VideoPlayerSurface` 一样，它只是普通视图：默认放在直播间页面里，
/// 需要时（分离窗口/全屏）才被放进按需创建的窗口。
struct LivePlayerSurface: View {
    @ObservedObject var model: LivePlayerModel
    @State private var controlsVisible = true
    /// 是否处于系统全屏：决定控制条样式与全屏按钮方向。
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                CustomPlayerView(player: player,
                                 autofocus: true,
                                 onSpace: { model.togglePlay() },
                                 onSingleClick: { controlsVisible.toggle() },
                                 onDoubleClick: onToggleFullscreen)
            } else if model.state == .loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在连接直播间…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if model.state == .offline {
                VStack(spacing: 10) {
                    Image(systemName: "moon.zzz")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("主播还未开播").font(.headline)
                }
            } else if model.state == .failed {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("直播加载失败").font(.headline)
                    Text(model.errorMessage ?? "未知错误")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await model.retryCurrent() }
                    }
                }
                .padding()
            }
            LiveControlsView(model: model,
                             controlsVisible: $controlsVisible,
                             isFullscreen: isFullscreen,
                             onToggleFullscreen: onToggleFullscreen)
        }
        .overlay(alignment: .topLeading) {
            // 在线人数：随控制条唤起显示在播放区域左上角
            if controlsVisible, let text = model.onlineText {
                PlayerOnlineBadge(text: text)
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .clipped()
    }
}

/// 直播简化控制条：播放/暂停 + 直播状态 + 全屏，静止后自动淡出。
private struct LiveControlsView: View {
    @ObservedObject var model: LivePlayerModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var controlsVisible: Bool
    /// 当前是否在全屏窗口内
    let isFullscreen: Bool
    let onToggleFullscreen: () -> Void

    @State private var hideTask: Task<Void, Never>?
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        ZStack {
            Color.clear.allowsHitTesting(false)
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
        .onAppear { scheduleHide() }
        .onChange(of: controlsVisible) { _, visible in
            if visible { scheduleHide() }
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    private var controlBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button {
                    bumpActivity()
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "暂停" : "播放")

                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("直播中")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.primary.opacity(0.12)))
                .allowsHitTesting(false)

                Spacer()

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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { bumpActivity() }
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isDark ? .black.opacity(0.35) : .white.opacity(0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.primary.opacity(0.12), lineWidth: 1)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }
            }
            .frame(maxWidth: 420)
            .padding(.bottom, 18)
        }
    }

    private func bumpActivity() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                controlsVisible = true
            }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, controlsVisible else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                controlsVisible = false
            }
        }
    }
}
