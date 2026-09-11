import AppKit
import SwiftUI

/// 顶部菜单栏“播放”菜单的状态中枢。
///
/// 菜单属于 App 级（`Commands`），拿不到播放页内部的状态，所以播放页在出现时把
/// 三个开关的读写挂到这里；菜单项据此决定标题、勾选与可用性。播放页离开时解除绑定。
@MainActor
final class PlaybackMenuState: ObservableObject {
    static let shared = PlaybackMenuState()

    /// 当前是否停在视频播放页
    @Published private(set) var isActive = false
    /// 弹幕开关状态
    @Published private(set) var danmakuEnabled = true
    /// 画面是否已分离到独立窗口
    @Published private(set) var isDetached = false
    /// 播放器是否处于原生全屏
    @Published private(set) var isFullscreen = false
    /// 是否已经挂上可操作的播放器（全屏开关需要它）
    @Published private(set) var hasPlayer = false

    private var toggleDanmakuAction: (() -> Void)?
    private var toggleDetachAction: (() -> Void)?
    private weak var playerView: DanmakuPlayerView?

    private init() {}

    // MARK: - 播放页绑定

    /// 播放页出现：交出三个开关的读写入口。
    func bind(danmakuEnabled: Bool,
              isDetached: Bool,
              toggleDanmaku: @escaping () -> Void,
              toggleDetach: @escaping () -> Void) {
        self.danmakuEnabled = danmakuEnabled
        self.isDetached = isDetached
        toggleDanmakuAction = toggleDanmaku
        toggleDetachAction = toggleDetach
        isActive = true
    }

    /// 播放页离开：解除绑定，菜单项随即不可用。
    func unbind() {
        toggleDanmakuAction = nil
        toggleDetachAction = nil
        isActive = false
        isDetached = false
        isFullscreen = false
    }

    func setDanmakuEnabled(_ enabled: Bool) { danmakuEnabled = enabled }
    func setDetached(_ detached: Bool) { isDetached = detached }
    func setFullscreen(_ fullscreen: Bool) { isFullscreen = fullscreen }

    // MARK: - 播放器绑定（全屏开关要直接操作 AVPlayerView）

    /// 画面挂到窗口上时登记：页内与分离窗口共用同一套菜单。
    func attachPlayerView(_ view: DanmakuPlayerView) {
        playerView = view
        hasPlayer = true
    }

    /// 画面离开窗口（切换成另一个 / 被销毁）时注销，只清除仍是自己的那次登记。
    func detachPlayerView(_ view: DanmakuPlayerView) {
        guard playerView === view else { return }
        playerView = nil
        hasPlayer = false
        isFullscreen = false
    }

    // MARK: - 菜单动作

    func performToggleDanmaku() { toggleDanmakuAction?() }
    func performToggleDetach() { toggleDetachAction?() }

    /// 切换视频全屏：优先走 AVKit 自己的全屏入口（与控件条上的全屏按钮同一条路径，
    /// 动画、弹幕跟随完全一致）；系统不再提供该入口时退回窗口全屏。
    func performToggleFullscreen() {
        guard let view = playerView else { return }
        guard view.toggleNativeFullscreen() else {
            view.window?.toggleFullScreen(nil)
            return
        }
    }
}
