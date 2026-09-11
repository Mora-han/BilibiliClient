import AppKit
import AVFoundation
import CoreText
import QuartzCore
import SwiftUI

/// 弹幕渲染层：完全脱离 SwiftUI 渲染管线。
/// 每条弹幕 = 一个 CALayer（文字预渲染成带外侧描边的位图，由 GPU 缓存）。
/// 滚动弹幕的运动交给 Core Animation 在渲染进程按播放时间推进（不依赖回调帧率），
/// CADisplayLink 只做轻量的生成/回收；暂停、seek、倍速时直接修正模型值，
/// 不触发任何 SwiftUI 视图更新或 Canvas 重绘，对视频渲染几乎零干扰。
struct DanmakuOverlayView: NSViewRepresentable {
    let engine: DanmakuEngine
    let player: AVPlayer
    let enabled: Bool

    func makeNSView(context: Context) -> DanmakuOverlayNSView {
        let view = DanmakuOverlayNSView(engine: engine, player: player)
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: DanmakuOverlayNSView, context: Context) {
        view.player = player
        view.enabled = enabled
    }
}

/// 弹幕承载视图：透明、不拦截鼠标、生命周期与窗口绑定（窗口消失即停表）。
final class DanmakuOverlayNSView: NSView {
    let engine: DanmakuEngine
    weak var player: AVPlayer? {
        didSet {
            if player !== oldValue { updateLink() }
        }
    }
    var enabled = false {
        didSet {
            if enabled != oldValue {
                if !enabled { removeAllLayers() }
                updateLink()
            }
        }
    }

    private var link: CADisplayLink?
    private var windowCloseObserver: NSObjectProtocol?
    private var layers: [Int: CALayer] = [:]
    /// 弹幕统一挂在 stageLayer 下；连续尺寸变化（全屏缩放/拖窗）期间
    /// 只缩放该层，避免每帧销毁并重新栅格化全部文字造成动画卡顿。
    private let stageLayer = CALayer()
    private var lastSize: CGSize = .zero
    private var lastScale: CGFloat = 0
    /// 弹幕是否处于“随播放头行进”的状态（播放中）。暂停/缓冲时置为静态。
    private var drivePlaying = false
    /// 尺寸连续变化中：舞台按 freezeBaseSize -> 当前 bounds 等比缩放，引擎暂停推进。
    private var layerFreezeActive = false
    private var freezeBaseSize: CGSize = .zero
    /// AVKit 全屏过渡中（由 delegate 精确开合，比轮询尺寸更准）
    private var transitionActive = false
    /// 进入过渡时的容器尺寸：整层缩放的基准
    private var transitionBaseSize: CGSize = .zero
    /// 退出全屏时用于预热的"进全屏前尺寸"
    private var preFullscreenSize: CGSize?
    /// 待预热的文字位图（过渡期间每帧只栅格化少量，避免单帧峰值）
    private var prewarmQueue: [PrewarmJob] = []
    private static let prewarmPerTick = 6
    /// 最后一次尺寸变化时间：用于判断缩放是否已结束（0.12s 无变化即重建）
    private var lastResizeTime: TimeInterval = 0
    /// 突发批量重建时每帧新增上限：把单帧栅格化峰值拆散到连续几帧
    private static let maxAddPerTick = 14
    /// 文字位图缓存：同文案/字号/颜色/scale 直接复用 GPU 图，省去重复栅格化
    private static let textureCache = NSCache<NSString, CGImage>()

    init(engine: DanmakuEngine, player: AVPlayer?) {
        self.engine = engine
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        stageLayer.anchorPoint = .zero
        stageLayer.position = .zero
        layer?.addSublayer(stageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 点击穿透到下层播放器
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        if let window {
            // 窗口被关闭（无论由谁触发）时立即停帧：CADisplayLink 强引用 target，
            // 不能依赖 deinit 收尾，避免关闭后仍有空转的帧驱动占用 CPU。
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.stopLink()
                }
            }
        }
        updateLink()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 换屏/缩放比例变化：强制重建层，保证文字清晰
        lastScale = 0
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        link?.invalidate()
    }

    // MARK: - 驱动

    private func updateLink() {
        let shouldRun = enabled && window != nil && player != nil
        if shouldRun {
            guard link == nil else { return }
            let newLink = displayLink(target: self, selector: #selector(frameTick))
            // 跟随显示器原生刷新率（60/120/160Hz）：弹幕只是图层位移，
            // 高刷下每帧开销依然极低，不影响视频渲染
            newLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 160)
            newLink.add(to: .main, forMode: .common)
            link = newLink
        } else {
            stopLink()
        }
    }

    /// 立即停止帧驱动（窗口关闭/离开/停用弹幕/播放器销毁时调用）。
    private func stopLink() {
        link?.invalidate()
        link = nil
        removeAllLayers()
    }

    @objc private func frameTick() {
        guard enabled, let player, let window else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = window.backingScaleFactor
        if scale != lastScale {
            lastScale = scale
            lastSize = .zero
            endFreeze()
        }
        // AVKit 全屏过渡：现有弹幕原样保留，整层绕画面中心缩放跟随视频，
        // 引擎不推进（过渡结束由 rebuildAllLayers 一次性补齐并原子重建）。
        // 这样全程没有逐帧重建、没有文字重新栅格化，也不会斜向漂移。
        if transitionActive {
            // 兜底：万一副屏/异常路径下 AVKit 没回调 didEnter/didExit，
            // 尺寸稳定超过 1.2s 就自行收尾，避免弹幕永久冻结在过渡态。
            if abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 {
                lastResizeTime = CACurrentMediaTime()
            } else if CACurrentMediaTime() - lastResizeTime > 1.2 {
                endSizeTransition()
                return
            }
            applyStageScale(from: transitionBaseSize, to: size)
            drainPrewarmQueue()
            lastSize = size
            return
        }

        let sizeChanged = abs(size.width - lastSize.width) > 0.5
            || abs(size.height - lastSize.height) > 0.5
        if sizeChanged {
            if !layerFreezeActive, !layers.isEmpty, lastSize.width > 0 {
                // 进入连续尺寸变化（全屏缩放/拖拽窗口）：保留现有弹幕层，
                // 舞台按比例缩放跟随画面；文字位图不重建，GPU 直接合成，
                // 动画期间零栅格化开销。尺寸稳定后再按最终尺寸一次性重建。
                layerFreezeActive = true
                freezeBaseSize = lastSize
            }
            lastResizeTime = CACurrentMediaTime()
            if layerFreezeActive {
                applyStageScale(from: freezeBaseSize, to: size)
                lastSize = size
                // 冻结推进：等尺寸稳定后统一补帧，避免动画期间引擎与层不同步
                return
            }
            lastSize = size
            removeAllLayers()
        } else {
            lastSize = size
            // 缩放结束（连续 0.12s 无尺寸变化）→ 解除舞台缩放并按新尺寸重建
            if layerFreezeActive,
               CACurrentMediaTime() - lastResizeTime > 0.12 {
                endFreeze()
                removeAllLayers()
            }
        }

        let raw = player.currentTime().seconds
        // seek 瞬间可能返回非有限值：跳过本帧，由引擎的 seek 检测接管
        guard raw.isFinite else { return }
        engine.tick(playerTime: raw, size: size)
        syncLayers(size: size, scale: scale, time: raw)
    }

    /// 尺寸稳定：解除舞台缩放并复位，等待下一帧按新尺寸重建全部弹幕层。
    private func endFreeze() {
        guard layerFreezeActive else { return }
        layerFreezeActive = false
        freezeBaseSize = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.transform = CATransform3DIdentity
        stageLayer.frame = bounds
        CATransaction.commit()
    }

    /// 把舞台从 base 尺寸缩放到当前容器尺寸，缩放中心取画面中心。
    ///
    /// 视频在全屏动画里是绕画面中心放大的，弹幕层必须绕同一点缩放才"贴着画面走"；
    /// 之前绕左下角缩放，弹幕会相对视频斜向漂移，看起来就是抖。
    private func applyStageScale(from base: CGSize, to size: CGSize) {
        guard base.width > 0.5, base.height > 0.5 else { return }
        let sx = size.width / base.width
        let sy = size.height / base.height
        guard abs(sx - 1) > 0.0005 || abs(sy - 1) > 0.0005 else { return }
        let cx = base.width / 2
        let cy = base.height / 2
        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, cx, cy, 0)
        transform = CATransform3DScale(transform, sx, sy, 1)
        transform = CATransform3DTranslate(transform, -cx, -cy, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.transform = transform
        CATransaction.commit()
    }

    // MARK: - 进出全屏过渡

    /// AVKit 全屏动画开始：冻结推进，只做整层缩放跟随，并准备预热目标尺寸的文字位图。
    /// - Parameter target: 过渡结束时的预期尺寸（未知传 nil，例如退出全屏时按进全屏前的尺寸推算）。
    func beginSizeTransition(target: CGSize?) {
        guard enabled, window != nil else { return }
        if preFullscreenSize == nil { preFullscreenSize = bounds.size }
        transitionActive = true
        transitionBaseSize = bounds.size
        layerFreezeActive = false
        freezeBaseSize = .zero
        lastResizeTime = CACurrentMediaTime()
        preparePrewarm(target: target ?? preFullscreenSize)
    }

    /// AVKit 全屏动画结束：复位缩放，并按最终尺寸在同一帧内原子重建全部弹幕层。
    /// 位图已在过渡期间预热完（命中缓存），因此不会出现逐帧栅格化的卡顿与闪断。
    func endSizeTransition() {
        guard transitionActive else { return }
        transitionActive = false
        preFullscreenSize = nil
        prewarmQueue.removeAll()
        rebuildAllLayers()
    }

    /// 过渡结束后的一次性重建：清空旧层 -> 按新尺寸补齐引擎 -> 单帧建好全部新层。
    private func rebuildAllLayers() {
        guard enabled, let player, window != nil else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.transform = CATransform3DIdentity
        stageLayer.frame = CGRect(origin: .zero, size: size)
        for layer in layers.values {
            layer.removeFromSuperlayer()
        }
        layers.removeAll()
        CATransaction.commit()
        lastSize = size
        lastScale = scale

        let raw = player.currentTime().seconds
        guard raw.isFinite else { return }
        engine.tick(playerTime: raw, size: size)
        drivePlaying = player.timeControlStatus == .playing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in engine.active {
            addLayer(for: item, size: size, scale: scale, time: raw)
        }
        CATransaction.commit()
    }

    /// 收集过渡结束尺寸下需要重新栅格化的文字，攒成待预热队列。
    private func preparePrewarm(target: CGSize?) {
        prewarmQueue.removeAll()
        guard let target, target.width > 1, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        prewarmQueue = engine.active.prefix(140).map {
            PrewarmJob(text: $0.text,
                       color: $0.color,
                       fontSize: $0.fontSize(for: target.width),
                       scale: scale)
        }
    }

    /// 过渡期间每帧只栅格化少量文字：把一个可能几十毫秒的峰值摊到整段动画里，
    /// 过渡结束时缓存已经就绪，重建因此是"零成本"的。
    private func drainPrewarmQueue() {
        guard !prewarmQueue.isEmpty else { return }
        var remaining = prewarmQueue.count
        var budget = Self.prewarmPerTick
        while budget > 0, remaining > 0 {
            let job = prewarmQueue[prewarmQueue.count - remaining]
            _ = Self.cachedOutlineImage(text: job.text,
                                        color: job.color,
                                        fontSize: job.fontSize,
                                        scale: job.scale)
            remaining -= 1
            budget -= 1
        }
        prewarmQueue.removeFirst(prewarmQueue.count - remaining)
    }

    /// 预热任务：文字位图的输入参数（纯值，可安全在缓存里流转）。
    private struct PrewarmJob {
        let text: String
        let color: CGColor
        let fontSize: CGFloat
        let scale: CGFloat
    }

    // MARK: - 层同步

    /// 滚动弹幕的运动由 Core Animation 在渲染侧按时间推进：
    /// 只在“生成/回收/暂停/变速”时改模型值，常规播放中不提交事务，
    /// 视觉帧率与系统是否节流 CADisplayLink 回调完全解耦。
    private func syncLayers(size: CGSize, scale: CGFloat, time: Double) {
        let playing = player?.timeControlStatus == .playing
        let rate = playing ? max(player?.rate ?? 1, 0.1) : 1

        if playing != drivePlaying {
            if playing {
                // 恢复播放：给暂停/缓冲期间静态放置的滚动层补上续走动画
                for (id, layer) in layers {
                    if let item = engine.active.first(where: { $0.id == id }) {
                        startScrollAnimation(for: item, layer: layer, in: size, time: time)
                    }
                }
            } else {
                // 暂停/缓冲：取消动画，钉在播放头当前时间对应的位置
                for (id, layer) in layers {
                    if let item = engine.active.first(where: { $0.id == id }) {
                        freeze(layer, for: item, in: size, time: time)
                    } else {
                        layer.removeAnimation(forKey: Self.moveKey)
                    }
                }
            }
            drivePlaying = playing
        }
        // 倍速（如长按右方向键 2 倍速）时按倍速推进动画，与播放头保持一致
        if abs((self.layer?.speed ?? 1) - rate) > 0.01 {
            self.layer?.speed = rate
        }

        guard !engine.active.isEmpty else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeAllLayers()
            CATransaction.commit()
            return
        }

        // 非冻结态下确保舞台尺寸与视图一致（首次挂载/解除冻结后的重建）
        if !layerFreezeActive, stageLayer.frame != CGRect(origin: .zero, size: size) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stageLayer.frame = CGRect(origin: .zero, size: size)
            CATransaction.commit()
        }

        // 只在实际有层加入/回收时才开事务提交；空转帧零 CA 提交
        var ids = Set<Int>()
        ids.reserveCapacity(engine.active.count)
        var needsMutation = false
        for item in engine.active {
            ids.insert(item.id)
            if layers[item.id] == nil { needsMutation = true }
        }
        if !needsMutation {
            for id in layers.keys where !ids.contains(id) {
                needsMutation = true
                break
            }
        }
        guard needsMutation else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 单帧新增数设上限：全屏切换结束后的一次性重建 / 弹幕高峰不会让
        // 某一帧承担全部栅格化，未补完的下一帧继续，观感更平滑。
        var added = 0
        for item in engine.active where layers[item.id] == nil {
            guard added < Self.maxAddPerTick else { break }
            addLayer(for: item, size: size, scale: scale, time: time)
            added += 1
        }
        for (id, layer) in layers where !ids.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        CATransaction.commit()
    }

    private func addLayer(for item: DanmakuEngine.Active, size: CGSize, scale: CGFloat, time: Double) {
        let fontSize = item.fontSize(for: size.width)
        // 文字预渲染成带外侧描边的位图：黑色字 8 方向偏移 + 中心前景色字，
        // 描边只出现在字形最外侧，笔画交叉处不会被描边切断填充。
        // 位图按“文案+颜色+字号+scale”缓存，重复弹幕与重建直接复用，免栅格化。
        let image = Self.cachedOutlineImage(text: item.text,
                                            color: item.color,
                                            fontSize: fontSize,
                                            scale: scale)
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        if let image {
            layer.bounds = CGRect(x: 0, y: 0,
                                  width: CGFloat(image.width) / scale,
                                  height: CGFloat(image.height) / scale)
        } else {
            layer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        layer.actions = [
            "position": NSNull(),
            "contents": NSNull(),
        ]
        stageLayer.addSublayer(layer)
        layers[item.id] = layer
        if drivePlaying, item.mode == 1 {
            startScrollAnimation(for: item, layer: layer, in: size, time: time)
        } else {
            layer.position = Self.layerPosition(for: item, in: size, time: time)
        }
    }

    /// 滚动弹幕：从当前播放头位置线性动画到终点（终点即离开画面）。
    /// 模型值直接设为终点，动画结束后不会回跳；层在引擎回收时移除。
    private func startScrollAnimation(for item: DanmakuEngine.Active,
                                      layer: CALayer,
                                      in size: CGSize,
                                      time: Double) {
        guard item.mode == 1 else {
            layer.position = Self.layerPosition(for: item, in: size, time: time)
            return
        }
        let end = item.startTime + item.duration
        let remaining = max(0, end - time)
        guard remaining > 0.02 else {
            layer.position = Self.layerPosition(for: item, in: size, time: end)
            return
        }
        let endPosition = Self.layerPosition(for: item, in: size, time: end)
        layer.removeAnimation(forKey: Self.moveKey)
        layer.position = endPosition
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: Self.layerPosition(for: item, in: size, time: time))
        animation.toValue = NSValue(point: endPosition)
        animation.duration = remaining
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(animation, forKey: Self.moveKey)
    }

    /// 暂停/缓冲：取消动画，把层钉在当前播放头时间对应的静止位置。
    private func freeze(_ layer: CALayer,
                        for item: DanmakuEngine.Active,
                        in size: CGSize,
                        time: Double) {
        layer.removeAnimation(forKey: Self.moveKey)
        layer.position = Self.layerPosition(for: item, in: size, time: time)
    }

    /// 带缓存的文字位图获取：命中直接返回 GPU 图，未命中才栅格化。
    private static func cachedOutlineImage(text: String, color: CGColor,
                                           fontSize: CGFloat, scale: CGFloat) -> CGImage? {
        let key = cacheKey(text: text, color: color,
                           fontSize: fontSize, scale: scale)
        if let hit = textureCache.object(forKey: key as NSString) {
            return hit
        }
        guard let image = makeOutlineImage(text: text, color: color,
                                           fontSize: fontSize, scale: scale) else {
            return nil
        }
        textureCache.setObject(image, forKey: key as NSString)
        return image
    }

    private static func cacheKey(text: String, color: CGColor,
                                 fontSize: CGFloat, scale: CGFloat) -> String {
        let colorParts = (color.components ?? [])
            .map { String(Int(round($0 * 255))) }
            .joined(separator: ",")
        return "\(text)\u{1F}|\(Int(round(fontSize * 10)))|\(Int(round(scale * 10)))|\(colorParts)"
    }

    /// 预渲染文字位图：8 方向偏移的黑色描边 + 中心填充，返回已按 scale 放大的图。
    private static func makeOutlineImage(text: String, color: CGColor,
                                         fontSize: CGFloat, scale: CGFloat) -> CGImage? {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let fillColor = NSColor(cgColor: color) ?? .white
        let fill = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: fillColor
        ]))
        let outline = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.black
        ]))
        let bounds = CTLineGetBoundsWithOptions(fill, [])
        // 描边尽可能细：8 方向偏移距离即描边厚度
        let offset = max(0.6, fontSize * 0.035)
        let w = Int(ceil((bounds.width + offset * 2) * scale))
        let h = Int(ceil((bounds.height + offset * 2) * scale))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        let origin = CGPoint(x: offset - bounds.origin.x, y: offset - bounds.origin.y)
        for dx in [-1.0, 0.0, 1.0] {
            for dy in [-1.0, 0.0, 1.0] {
                if dx == 0 && dy == 0 { continue }
                ctx.textPosition = CGPoint(x: origin.x + offset * dx,
                                           y: origin.y + offset * dy)
                CTLineDraw(outline, ctx)
            }
        }
        ctx.textPosition = origin
        CTLineDraw(fill, ctx)
        return ctx.makeImage()
    }

    private func removeAllLayers() {
        endFreeze()
        guard !layers.isEmpty else { return }
        for layer in layers.values {
            layer.removeFromSuperlayer()
        }
        layers.removeAll()
    }

    /// 引擎坐标是左上角原点，AppKit 层坐标是左下角原点，翻转 Y
    private static func layerPosition(for item: DanmakuEngine.Active,
                                      in size: CGSize,
                                      time: Double) -> CGPoint {
        let p = item.position(in: size, at: time)
        return CGPoint(x: p.x, y: size.height - p.y)
    }

    private static let moveKey = "dmMove"
}
