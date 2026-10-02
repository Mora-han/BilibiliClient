import NukeUI
import SwiftUI

/// 远程图片视图（Nuke 驱动）。
///
/// `AsyncImage` 不保留解码结果、视图一重建就重新请求；这里交给 Nuke 的管线：
/// 后台解码、两级缓存（内存 + 磁盘）、同 URL 并发合并、离开视野自动取消。
/// 传进来的地址会按 `variant` 拼上图床尺寸后缀，服务端直接下发显示尺寸的图。
///
/// 图片解码完成后淡入（0.25s，easeOut），不会「啪」地闪现在卡片上。
/// 判据是「本会话里这张图第一次被展示」，而不是「这次请求有没有走网络」——
/// 列表一到数据就会 `BiliImages.prefetch` 预取封面，等视图真正渲染时常已命中缓存，
/// 按网络判据这些首屏图会被跳过渐显；滚动回看同一张图时直接显示，不重复动画。
struct RemoteImage: View {
    let url: URL?
    /// 采用途决定请求尺寸（头像 / 封面 / 大图 / 保持比例）
    var variant: Formatters.ImageVariant = .card
    /// 本图所在标签页的可见性（见 `\.isTabVisible`）
    @Environment(\.isTabVisible) private var isTabVisible
    /// 标签重新可见时自增，配合 `.id` 强制重建图片视图。
    ///
    /// keep-alive 的隐藏页只藏不删：实测切回后数据还在、封面却一直是占位灰，
    /// 说明懒加载视图在隐藏期间既没续上加载任务、重新可见时也不再收到出现事件。
    /// 可见性一恢复就换 id 重建，缓存命中立刻回图；渐显登记早已完成，不会重播淡入。
    @State private var revealGeneration = 0

    var body: some View {
        let requestURL = Formatters.sized(url, variant)
        LazyImage(url: requestURL) { state in
            if let image = state.image {
                FadeInImage(image: image, key: requestURL)
                    // 淡入过程中露出与占位一致的底色，避免闪一下卡片背景
                    .background { placeholder }
            } else {
                placeholder
            }
        }
        .id(revealGeneration)
        .onChange(of: isTabVisible) { _, visible in
            guard visible else { return }
            revealGeneration += 1
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.55))
    }
}

/// 本会话内已展示过的图片键（按请求地址，含尺寸后缀）。
///
/// 只记「展示过」这一件事：预取 / 缓存命中与否都与它无关。
/// 值得多占这点内存——它就是「首次展示才淡入、回看直接显示」的全部判据。
/// 读写只发生在视图 init / onAppear，也就是主线程上。
private enum ShownImages {
    static var keys: Set<String> = []

    /// 图片首次出现时登记并返回 true（值得淡入）；之后再问返回 false。
    static func claimFirstShow(_ key: String?) -> Bool {
        guard let key else { return false }
        return keys.insert(key).inserted
    }
}

/// 图片解码完成后淡入：首帧是否可见在 init 里就定好，避免缓存命中的图
/// 先按不可见挂上去、`onAppear` 才补救而闪一帧占位灰。
private struct FadeInImage: View {
    let image: Image
    /// 请求地址（含尺寸后缀）；nil 表示没有可展示的远程图
    let key: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 本会话首次展示 → 起始不可见，等 `onAppear` 淡入
    @State private var firstShow: Bool
    @State private var visible: Bool

    init(image: Image, key: URL?) {
        self.image = image
        self.key = key?.absoluteString
        // 只查不登记：登记放到 onAppear，保证「挂上屏幕」才计入首次展示，
        // 也保证同一次挂载里多次 init 得到同一个结论。
        let alreadyShown = key.map { ShownImages.keys.contains($0.absoluteString) } ?? true
        _firstShow = State(initialValue: !alreadyShown)
        _visible = State(initialValue: alreadyShown)
    }

    var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .opacity(visible ? 1 : 0)
            .onAppear {
                guard firstShow else {
                    visible = true
                    return
                }
                _ = ShownImages.claimFirstShow(key)
                guard !reduceMotion else {
                    visible = true
                    return
                }
                withAnimation(.easeOut(duration: 0.25)) { visible = true }
            }
    }
}
