import AVFoundation
import SwiftUI

/// 叠在播放器上的弹幕层：30fps 定时驱动引擎，按播放时间渲染活跃弹幕。
struct DanmakuOverlayView: View {
    @ObservedObject var engine: DanmakuEngine
    let player: AVPlayer
    let enabled: Bool

    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(engine.active) { item in
                    Text(item.text)
                        .font(.system(size: 20 * item.scale, weight: .bold))
                        .foregroundStyle(item.color)
                        .shadow(color: .black.opacity(0.85), radius: 2, x: 0, y: 1)
                        .position(item.position(in: geo.size,
                                               at: player.currentTime().seconds))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { size = geo.size }
            .onChange(of: geo.size) { _, newSize in size = newSize }
        }
        .task(id: enabled) {
            guard enabled else { return }
            // 播放暂停时 playerTime 不变，弹幕自然冻结
            while !Task.isCancelled {
                engine.tick(playerTime: player.currentTime().seconds, size: size)
                try? await Task.sleep(for: .seconds(1.0 / 30.0))
            }
        }
        .allowsHitTesting(false)
        .clipped()
    }
}

/// 播放器右上角的弹幕开关（液态玻璃胶囊样式）。
struct DanmakuToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "text.bubble.fill" : "text.bubble")
                Text("弹幕")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.55))
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
        .help(isOn ? "关闭弹幕" : "开启弹幕")
    }
}
