import AVFoundation
import SwiftUI

/// 直播播放组件：系统 AVPlayerView（画面 + 原生全屏）+ 自绘液态玻璃控制栏 + 在线人数徽标。
/// 全屏（含全屏动画）由 AVKit 负责；控制栏是直播变体：没有时间轴（换成"直播"徽标），
/// 也没有弹幕开关与画质入口，只保留播放/倍速/画中画/全屏。
///
/// 连接中 / 未开播 / 加载失败三种占位**不在这里画**：宿主 `LiveDetailView.playerSection`
/// 只在 `state == .ready && player != nil` 时才创建本组件，那三种状态由宿主那一侧的
/// switch 负责（那里有同文案的占位与重试入口）。原先这里也抄了一份，实际永远走不到。
struct LivePlayerSurface: View {
    @ObservedObject var model: LivePlayerModel

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                #if os(macOS)
                PlayerSurfaceView(player: player,
                                  engine: nil,
                                  danmakuEnabled: false,
                                  danmakuSettings: .current,
                                  controls: controls)
                    .id(player)
                #else
                IOSPlayerSurface(player: player,
                                 engine: nil,
                                 danmakuEnabled: false,
                                 danmakuSettings: .current,
                                 // 直播没有「空降」概念，不挂提示卡片
                                 sponsorNotice: nil,
                                 onSponsorUndo: {},
                                 onSponsorDismiss: {})
                    .id(player)
                #endif
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

    #if os(macOS)
    /// 自绘控制栏的直播变体输入：没有时间轴/弹幕/画质，只接播放开关。
    /// iOS 用 AVPlayerViewController 自带控件，不需要这条配置。
    private var controls: PlayerBarConfig {
        var config = PlayerBarConfig()
        config.isLive = true
        config.onTogglePlay = { model.togglePlay() }
        return config
    }
    #endif
}
