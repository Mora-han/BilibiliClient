import NukeUI
import SwiftUI

/// 远程图片视图（Nuke 驱动）。
///
/// `AsyncImage` 不保留解码结果、视图一重建就重新请求；这里交给 Nuke 的管线：
/// 后台解码、两级缓存（内存 + 磁盘）、同 URL 并发合并、离开视野自动取消。
/// 传进来的地址会按 `variant` 拼上图床尺寸后缀，服务端直接下发显示尺寸的图。
///
/// 真正走网络下载的图，解码完成后淡入（0.25s，easeOut），不会「啪」地闪现在卡片上；
/// 命中内存 / 磁盘缓存的图直接显示 —— 滚动回看时不再为已缓存的封面白等一帧。
struct RemoteImage: View {
    let url: URL?
    /// 采用途决定请求尺寸（头像 / 封面 / 大图 / 保持比例）
    var variant: Formatters.ImageVariant = .card

    var body: some View {
        LazyImage(url: Formatters.sized(url, variant)) { state in
            if let image = state.image {
                FadeInImage(image: image, animated: Self.loadedFromNetwork(state))
                    // 淡入过程中露出与占位一致的底色，避免闪一下卡片背景
                    .background { placeholder }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.55))
    }

    /// 这次请求是不是实打实走网络拿的。
    ///
    /// `cacheType` 为 nil 表示没命中内存 / 磁盘缓存（含 HTTP 缓存），也就是网络加载 ——
    /// 只有这种情况才值得淡入；缓存命中的图直接显示，滚动回看不会白等一帧动画。
    private static func loadedFromNetwork(_ state: LazyImageState) -> Bool {
        guard case .success(let response)? = state.result else { return false }
        return response.cacheType == nil
    }
}

/// 图片解码完成后淡入。
private struct FadeInImage: View {
    let image: Image
    /// 只有网络加载的图才做淡入；缓存命中时首帧就直接显示
    let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible: Bool

    init(image: Image, animated: Bool) {
        self.image = image
        self.animated = animated
        _visible = State(initialValue: !animated)
    }

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .opacity(visible ? 1 : 0)
            .onAppear {
                guard animated, !reduceMotion else {
                    visible = true
                    return
                }
                withAnimation(.easeOut(duration: 0.25)) { visible = true }
            }
    }
}
