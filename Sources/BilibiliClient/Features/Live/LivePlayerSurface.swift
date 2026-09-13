import AVFoundation
import SwiftUI

/// 直播播放组件：系统 AVPlayerView（画面 + 原生播放控件 + 原生全屏）+ 在线人数徽标。
/// 播放与全屏（含全屏动画）全部由 AVKit 负责，这里不再自绘任何播放控件。
struct LivePlayerSurface: View {
    @ObservedObject var model: LivePlayerModel

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                PlayerSurfaceView(player: player,
                                  engine: nil,
                                  danmakuEnabled: false,
                                  isLive: true,
                                  onSpace: { model.togglePlay() },
                                  onSkip: { _ in })
                    .id(player)
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
        }
        .overlay(alignment: .topLeading) {
            // 在线人数
            if let text = model.onlineText {
                PlayerOnlineBadge(text: text)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }
}
