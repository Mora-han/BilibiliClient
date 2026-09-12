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
    /// 弹幕分挂在两个容器下。容器尺寸变化（进出全屏、拖拽窗口）时只缩放这两层
    /// 跟随画面，不逐帧重建文字位图；尺寸稳定后再原子重建一次，让文字恢复清晰。
    /// 缩放发生在视图布局的同一拍里（见 syncStageScale），因此弹幕与视频画面
    /// 天然同帧——不存在"另起一个动画去追画面"的错位与抖动。
    ///
    /// 之所以要两个容器：引擎里滚动/顶部弹幕的 y 是从**顶边**量出来的、底部弹幕
    /// 是从**底边**量的，而全屏和窗口画面的宽高比通常并不相同（差值是
    /// `newH - newW/baseW*baseH`）。一个缩放容器只能锚住一条边，锚底则顶部弹幕
    /// 在过渡结束时必然要"瞬移"这一段差值——这就是之前那一下跳变的来源。
    private let stageLayer = CALayer()
    /// 底部固定弹幕（mode 4）专用：绕画面底边等比缩放
    private let bottomStageLayer = CALayer()
    private var lastScale: CGFloat = 0
    /// 弹幕是否处于“随播放头行进”的状态（播放中）。暂停/缓冲时置为静态。
    private var drivePlaying = false
    /// 当前这批弹幕层是按哪个容器尺寸搭出来的：坐标、字号、动画起点都基于它。
    /// 与当前 bounds 宽度不一致即表示舞台处于缩放跟随态（按宽度比等比缩放）。
    private var stageBaseSize: CGSize = .zero
    /// 最近一次容器宽度变化的时刻（同步于视图布局）；尺寸稳定后据此重建
    private var lastStageChangeTime: CFTimeInterval = 0
    /// 最近一次见到的容器尺寸：用来识别“这一拍确实变了”
    private var lastStageSize: CGSize = .zero
    /// 文字位图需要按新的 backingScale 重新栅格化（换屏 / 改分辨率）
    private var backingScaleChanged = false
    /// 进入全屏前的窗口内尺寸：退出全屏时按它预热文字位图
    private var windowedSize: CGSize?
    /// 目标尺寸的文字位图是否已在后台预热完（预热完才能无卡顿地原子重建）
    private var prewarmGeneration = 0
    private var prewarmFinished = true
    /// 尺寸变化已结束、只等预热完成的那次重建
    private var rebuildAwaitingPrewarm = false
    /// 离开窗口后的宽限收尾任务：AVKit 全屏过渡只是把内容覆盖层从旧窗口挪到新窗口，
    /// 中途会有几毫秒 `window == nil`，不能据此立刻销毁弹幕层。
    private var detachedTeardown: DispatchWorkItem?
    /// 突发批量重建时每帧新增上限：把单帧栅格化峰值拆散到连续几帧
    private static let maxAddPerTick = 14
    /// 尺寸稳定多久后按新尺寸重建文字位图（只影响清晰度，不影响位置）
    private static let rebuildQuietPeriod: CFTimeInterval = 0.10
    /// 文字位图缓存：同文案/字号/颜色/scale 直接复用 GPU 图，省去重复栅格化
    private static let textureCache = NSCache<NSString, CGImage>()

    init(engine: DanmakuEngine, player: AVPlayer?) {
        self.engine = engine
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        // 顶部/滚动弹幕：锚在画面顶边（anchorPoint.y = 1），position 每帧跟到当前顶边
        stageLayer.anchorPoint = CGPoint(x: 0, y: 1)
        stageLayer.position = .zero
        layer?.addSublayer(stageLayer)
        // 底部弹幕：锚在画面左下角
        bottomStageLayer.anchorPoint = .zero
        bottomStageLayer.position = .zero
        layer?.addSublayer(bottomStageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 容器尺寸变化的入口之一（另一个是 layout()）。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncStageScale()
    }

    override func layout() {
        super.layout()
        syncStageScale()
    }

    /// 让弹幕舞台在视图布局的同一拍里跟随容器宽度等比缩放。
    ///
    /// 这是整套“全屏过渡不抖”的关键：AVKit 进出全屏时，系统是在主线程逐帧重新
    /// 布局播放器的（实测 `setFrameSize` 从 620pt 一路平滑走到 1920pt），视频画面
    /// 和这里设置的 `stageLayer.transform` 因此落在同一次 CA 事务里，天然同帧、
    /// 零延迟。任何“另起一个动画去追画面”的做法（不管怎么拟合延迟、时长和曲线）
    /// 都只能近似，而且会把主线程的掉帧放大成弹幕抖动。
    private func syncStageScale() {
        let size = bounds.size
        guard size.width > 0.5, size.height > 0.5 else { return }
        guard abs(size.width - lastStageSize.width) > 0.01
            || abs(size.height - lastStageSize.height) > 0.01 else { return }
        lastStageSize = size
        lastStageChangeTime = CACurrentMediaTime()
        guard stageBaseSize.width > 0.5 else { return }
        applyStageScale(width: size.width, height: size.height)
    }

    /// 绕原点（左上角）等比缩放：引擎里所有几何量都只按“容器宽度 / baseWidth”推导，
    /// 所以这样缩放出来的画面与按新尺寸重建的结果逐像素一致，过渡结束不会跳。
    private func applyStageScale(width: CGFloat, height: CGFloat) {
        let factor = width / stageBaseSize.width
        let transform = abs(factor - 1) < 0.0005
            ? CATransform3DIdentity
            : CATransform3DMakeScale(factor, factor, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.transform = transform
        stageLayer.bounds = CGRect(origin: .zero, size: stageBaseSize)
        // 锚点始终落在当前画面的顶边
        stageLayer.position = CGPoint(x: 0, y: height)
        bottomStageLayer.transform = transform
        CATransaction.commit()
    }

    /// 以给定尺寸作为舞台基准（重建弹幕层之前调用）。
    private func beginStage(size: CGSize) {
        stageBaseSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.transform = CATransform3DIdentity
        stageLayer.bounds = CGRect(origin: .zero, size: size)
        stageLayer.position = CGPoint(x: 0, y: size.height)
        bottomStageLayer.transform = CATransform3DIdentity
        bottomStageLayer.bounds = CGRect(origin: .zero, size: size)
        bottomStageLayer.position = .zero
        CATransaction.commit()
    }

    /// 点击穿透到下层播放器
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detachedTeardown?.cancel()
        detachedTeardown = nil
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        guard let window else {
            scheduleDetachedTeardown()
            return
        }
        // 窗口被关闭（无论由谁触发）时立即停帧：CADisplayLink 强引用 target，
        // 不能依赖 deinit 收尾，避免关闭后仍有空转的帧驱动占用 CPU。
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopLink()
            }
        }
        updateLink()
    }

    /// 视图暂时离开窗口：先宽限一小段时间再收尾。
    ///
    /// AVKit 进出全屏会把 `contentOverlayView` 从旧窗口摘下、再挂进新窗口，
    /// 中间只有几毫秒没有窗口。如果这一刻就停表并清空弹幕层，整段全屏动画里
    /// 弹幕都会凭空消失（只在动画结束重建时才回来）。真正被移出视图树时，
    /// 宽限期一过仍会正常收尾，不会留下空转的帧驱动。
    private func scheduleDetachedTeardown() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.window == nil else { return }
            self.detachedTeardown = nil
            self.stopLink()
        }
        detachedTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // 换屏/缩放比例变化：文字位图要按新的 scale 重新栅格化
        backingScaleChanged = true
        lastStageChangeTime = CACurrentMediaTime()
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
        rebuildAwaitingPrewarm = false
        removeAllLayers()
    }

    @objc private func frameTick() {
        guard enabled, let player, let window else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = window.backingScaleFactor
        if scale != lastScale {
            lastScale = scale
            backingScaleChanged = true
            lastStageChangeTime = CACurrentMediaTime()
        }

        let stageOutdated = abs(size.width - stageBaseSize.width) > 0.5
            || abs(size.height - stageBaseSize.height) > 0.5
        if layers.isEmpty {
            // 没有弹幕可缩放：舞台基准直接跟随当前尺寸
            backingScaleChanged = false
            if stageOutdated { beginStage(size: size) }
        } else if stageOutdated || backingScaleChanged {
            // 舞台处于缩放跟随态（容器宽度与建层时不同）：不推进引擎也不加层——
            // 新层会按新宽度算坐标，再被舞台缩放一次就重复了。已有弹幕继续由
            // Core Animation 按各自动画推进（位置天然随之缩放），等尺寸稳定后
            // 按最终尺寸一次性原子重建，文字位图恢复清晰。
            if CACurrentMediaTime() - lastStageChangeTime > Self.rebuildQuietPeriod {
                scheduleRebuild()
            }
            return
        }

        let raw = player.currentTime().seconds
        // seek 瞬间可能返回非有限值：跳过本帧，由引擎的 seek 检测接管
        guard raw.isFinite else { return }
        engine.tick(playerTime: raw, size: size)
        syncLayers(size: size, scale: scale, time: raw)
    }

    // MARK: - 进出全屏过渡

    /// AVKit 全屏过渡开始（delegate 精确开合）：只需按目标尺寸预热文字位图。
    /// 缩放跟随本身不在这里做——那由视图布局驱动（见 syncStageScale），
    /// 与视频画面落在同一次 CA 事务里，天生对齐。
    /// - Parameter target: 过渡结束时的预期尺寸（未知传 nil，例如退出全屏时按进全屏前的尺寸推算）。
    func beginSizeTransition(target: CGSize?) {
        guard enabled, window != nil else { return }
        // 进入全屏时记住窗口内尺寸，退出时按它预热（进入时总会覆盖，不会用到过期值）
        if target != nil { windowedSize = bounds.size }
        preparePrewarm(target: target ?? windowedSize)
    }

    /// AVKit 全屏过渡结束：容器尺寸已定型，按新尺寸原子重建全部弹幕层。
    /// 位图已在过渡期间预热完（命中缓存），收尾这帧几乎零成本。
    func endSizeTransition() {
        guard enabled, window != nil else { return }
        scheduleRebuild()
    }

    /// 请求按当前尺寸重建弹幕层；目标尺寸的位图若还在后台预热就先挂起，
    /// 等预热回调里再重建——避免把几十毫秒的栅格化卡顿砸在动画收尾处。
    private func scheduleRebuild() {
        if prewarmFinished {
            rebuildAllLayers()
        } else {
            rebuildAwaitingPrewarm = true
        }
    }

    /// 按当前尺寸重建全部弹幕层：撤掉缩放跟随 -> 补齐引擎 -> 一帧建好全部新层。
    /// 整段放在同一个 CATransaction 里，不会出现“旧层已删、新层未加”的空帧闪断。
    private func rebuildAllLayers() {
        guard enabled, let player, window != nil else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let raw = player.currentTime().seconds
        // seek 瞬间可能返回非有限值：等下一帧再重建
        guard raw.isFinite else { return }
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.values {
            layer.removeFromSuperlayer()
        }
        layers.removeAll(keepingCapacity: true)
        beginStage(size: size)
        engine.tick(playerTime: raw, size: size)
        drivePlaying = player.timeControlStatus == .playing
        for item in engine.active {
            addLayer(for: item, size: size, scale: scale, time: raw)
        }
        CATransaction.commit()

        lastScale = scale
        backingScaleChanged = false
        lastStageChangeTime = CACurrentMediaTime()
    }

    /// 提前在后台把过渡结束尺寸下要用的文字位图栅格化好，等过渡末尾做一次性重建时
    /// 全部命中缓存，于是重建本身"零成本"。
    ///
    /// 必须放后台：全屏过渡的缩放由主线程做布局驱动，若在这个线程逐帧栅格化
    /// （每张位图 1~3ms），一帧几张就吃满帧预算，画面与弹幕都会掉帧抖动。
    private func preparePrewarm(target: CGSize?) {
        guard let target, target.width > 1, let window else {
            prewarmFinished = true
            return
        }
        let scale = window.backingScaleFactor
        let jobs = engine.active.prefix(140).map {
            PrewarmJob(text: $0.text,
                       color: $0.color,
                       fontSize: $0.fontSize(for: target.width),
                       scale: scale)
        }
        prewarmGeneration += 1
        let generation = prewarmGeneration
        prewarmFinished = jobs.isEmpty
        guard !jobs.isEmpty else { return }
        // 目标比当前宽：整段过渡都在把弹幕放大，按基准尺寸栅格化的文字会被拉伸。
        let enlarging = target.width > bounds.width + 1
        let targetWidth = target.width
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for job in jobs {
                _ = Self.cachedOutlineImage(text: job.text,
                                            color: job.color,
                                            fontSize: job.fontSize,
                                            scale: job.scale)
            }
            DispatchQueue.main.async {
                guard let self, self.prewarmGeneration == generation else { return }
                self.prewarmFinished = true
                // 预热一好就把在位弹幕的位图换成目标尺寸的版本：层的 bounds 不变，
                // 屏幕上的字号仍由舞台缩放决定，于是"跟着画面放大"的同时文字全程清晰，
                // 不会等到过渡结束才突然变清楚。
                if enlarging, self.stageBaseSize.width > 0.5,
                   self.bounds.width > self.stageBaseSize.width + 0.5 {
                    self.upgradeContents(jobs: jobs, targetWidth: targetWidth)
                }
                if self.rebuildAwaitingPrewarm {
                    self.rebuildAwaitingPrewarm = false
                    self.rebuildAllLayers()
                }
            }
        }
    }

    /// 把在位弹幕层的 contents 换成目标尺寸的位图（尺寸/位置一律不动）。
    private func upgradeContents(jobs: [PrewarmJob], targetWidth: CGFloat) {
        guard !layers.isEmpty, let window else { return }
        let scale = window.backingScaleFactor
        var ready: [String: CGImage] = [:]
        ready.reserveCapacity(jobs.count)
        for job in jobs {
            let key = Self.cacheKey(text: job.text, color: job.color,
                                    fontSize: job.fontSize, scale: job.scale)
            if let image = Self.textureCache.object(forKey: key as NSString) {
                ready[key] = image
            }
        }
        guard !ready.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in engine.active {
            guard let layer = layers[item.id] else { continue }
            let key = Self.cacheKey(text: item.text, color: item.color,
                                    fontSize: item.fontSize(for: targetWidth),
                                    scale: scale)
            if let image = ready[key] { layer.contents = image }
        }
        CATransaction.commit()
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
        // 底部固定弹幕走另一个容器：它的 y 是从画面底边量的
        (item.mode == 4 ? bottomStageLayer : stageLayer).addSublayer(layer)
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
        guard !layers.isEmpty else { return }
        for layer in layers.values {
            layer.removeFromSuperlayer()
        }
        layers.removeAll()
        // 舞台基准一起清掉：下一批弹幕直接按当时的容器尺寸搭建
        stageBaseSize = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.transform = CATransform3DIdentity
        bottomStageLayer.transform = CATransform3DIdentity
        CATransaction.commit()
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
