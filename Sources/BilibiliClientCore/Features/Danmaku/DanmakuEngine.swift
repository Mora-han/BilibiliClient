#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CoreText
import Foundation

/// 弹幕速度档位（设置页可选），映射为滚动弹幕横穿屏幕的总时长。
enum DanmakuSpeed: String, CaseIterable, Identifiable {
    case relaxed, normal, fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relaxed: return "舒缓"
        case .normal: return "标准"
        case .fast: return "快速"
        }
    }

    /// 滚动弹幕横穿屏幕的秒数，越大越慢
    var duration: Double {
        switch self {
        case .relaxed: return 10
        case .normal: return 8
        case .fast: return 6
        }
    }

    static var current: DanmakuSpeed {
        DanmakuSpeed(rawValue: UserDefaults.standard.string(forKey: "danmakuSpeed") ?? "") ?? .normal
    }
}

/// 一条弹幕的渲染单元（DanmakuKit 的 cellModel）。
///
/// 字号与轨道高度按 `stageScale = 播放器宽度 / 基准宽度` 等比缩放，且在**发射时**
/// 取当时的比例——内嵌播放器切到全屏后，新弹幕的字号随之放大，和 B 站网页端一致。
final class BilibiliDanmakuModel: DanmakuCellModel {
    /// 顶部/底部固定弹幕的停留时长（秒）
    static let fixedDuration: Double = 4.5

    let item: DanmakuItem
    let identifier: String
    let size: CGSize
    let displayTime: Double
    let type: DanmakuCellType
    var track: UInt?

    var cellClass: DanmakuCell.Type { BilibiliDanmakuCell.self }

    /// 预排版的文字行：外层黑色描边与中心填充共用同一份排版，绘制时只做平移。
    /// CTLine 不可变，`displaying` 在后台队列里并发读取是安全的。
    let fillLine: CTLine
    let outlineLine: CTLine
    /// 文字在位图坐标系（左下原点、未翻转）里的绘制原点
    let textOrigin: CGPoint
    /// 外描边厚度
    let stroke: CGFloat
    /// 本次排版用的字号与栅格化倍率：一起构成位图缓存的键
    let fontSize: CGFloat
    /// 文字位图的栅格化密度（屏幕 backing scale × 当前显示缩放）。
    /// 舞台坐标始终按基准尺寸算，显示时靠舞台层缩放；把密度提上去，
    /// 放大后的文字才不会糊。过渡收尾只改这个值重画位图，不动几何。
    var renderScale: CGFloat
    /// 滚动弹幕横穿时长（重建/预热时要按同一设置复现）
    let scrollDuration: Double

    init(item: DanmakuItem, stageScale: CGFloat, duration: Double, renderScale: CGFloat) {
        self.item = item
        self.identifier = "\(item.id)-\(item.time)"
        let type: DanmakuCellType = item.mode == 4 ? .bottom : (item.mode == 5 ? .top : .floating)
        self.type = type
        self.displayTime = type == .floating ? duration : Self.fixedDuration
        self.scrollDuration = duration
        self.renderScale = renderScale

        // 基准字号 18pt；B 站字号字段（12/18/25/36）按比例换算，再乘舞台缩放
        let relative = min(max(CGFloat(item.fontSize) / 18, 0.6), 1.8)
        let fontSize = 18 * relative * stageScale
        self.fontSize = fontSize
        let font = PlatformFont.systemFont(ofSize: fontSize, weight: .medium)
        let fillLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: item.text,
            attributes: [.font: font, .foregroundColor: Self.color(from: item.color)]
        ))
        self.fillLine = fillLine
        self.outlineLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: item.text,
            attributes: [.font: font, .foregroundColor: PlatformColor.black]
        ))

        let bounds = CTLineGetBoundsWithOptions(fillLine, [])
        // 描边尽可能细：8 方向偏移距离即描边厚度（与旧实现一致）
        let stroke = max(0.6, fontSize * 0.035)
        self.stroke = stroke
        self.textOrigin = CGPoint(x: stroke - bounds.origin.x, y: stroke - bounds.origin.y)
        self.size = CGSize(width: ceil(bounds.width + stroke * 2),
                           height: ceil(bounds.height + stroke * 2))
    }

    func isEqual(to other: DanmakuCellModel) -> Bool {
        identifier == other.identifier
    }

    /// 唯一的画法：cell 的 `displaying` 与位图缓存都走这里，保证两者逐像素一致
    func draw(in context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.fill)
        // 8 方向偏移的黑色描边：保证在任何画面上都清晰可读
        let offsets: [CGFloat] = [-1, 0, 1]
        for dx in offsets {
            for dy in offsets where !(dx == 0 && dy == 0) {
                context.textPosition = CGPoint(x: textOrigin.x + stroke * dx,
                                               y: textOrigin.y + stroke * dy)
                CTLineDraw(outlineLine, context)
            }
        }
        context.textPosition = textOrigin
        CTLineDraw(fillLine, context)
        context.restoreGState()
    }

    /// 位图缓存的键
    var cacheKey: NSString {
        DanmakuTextRenderer.key(text: item.text, fontSize: fontSize,
                                color: item.color, scale: renderScale)
    }

    private static func color(from raw: UInt32) -> PlatformColor {
        .srgb(CGFloat((raw >> 16) & 0xFF) / 255,
              CGFloat((raw >> 8) & 0xFF) / 255,
              CGFloat(raw & 0xFF) / 255)
    }
}

/// 弹幕文字位图缓存。
///
/// 全屏过渡结束时的"原子重建"如果能直接拿到位图，就只是把 `layer.contents` 拷过去，
/// 不会有"旧弹幕已清空、新弹幕还在后台栅格化"的空窗——那正是过渡收尾时弹幕闪一下
/// 的原因。过渡期间会按目标尺寸先在后台预热，收尾几乎全部命中缓存。
enum DanmakuTextRenderer {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func key(text: String, fontSize: CGFloat, color: UInt32, scale: CGFloat) -> NSString {
        "\(text)\u{1F}|\(Int((fontSize * 10).rounded()))|\(color)|\(Int((scale * 10).rounded()))" as NSString
    }

    static func image(for key: NSString) -> CGImage? {
        cache.object(forKey: key)
    }

    static func store(_ image: CGImage, for key: NSString) {
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    }

}

/// 弹幕 Cell：把文字画进 DanmakuKit 给的位图上下文。
///
/// 必须用 Core Text 直接绘制：DanmakuKit 的 `DanmakuAsyncLayer` 在后台队列里自行
/// 创建 CGContext，此时 `NSGraphicsContext.current` 是 nil，AppKit 的
/// `NSString.draw(at:withAttributes:)` 会静默画不出任何像素（弹幕"看不见"的根因）。
final class BilibiliDanmakuCell: DanmakuCell {
    override func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {
        guard let model = model as? BilibiliDanmakuModel else { return }
        model.draw(in: context)
    }

    /// 命中位图缓存时同步换图：重建（全屏过渡收尾 / 拖窗口收尾）不会闪出空窗
    override func redraw() {
        guard let model = model as? BilibiliDanmakuModel else {
            super.redraw()
            return
        }
        // 位图密度由 model 决定（跟随当前显示缩放），换场/重画前先对齐
        if abs((backingLayer?.contentsScale ?? 0) - model.renderScale) > 0.05 {
            backingLayer?.contentsScale = model.renderScale
        }
        if let image = DanmakuTextRenderer.image(for: model.cacheKey) {
            backingLayer?.contents = image
            return
        }
        super.redraw()
    }

    /// 第一次后台画完的位图存进缓存，之后同文案/同尺寸直接命中
    override func didDisplay(_ finished: Bool) {
        super.didDisplay(finished)
        guard finished,
              let model = model as? BilibiliDanmakuModel,
              let raw = backingLayer?.contents,
              CFGetTypeID(raw as CFTypeRef) == CGImage.typeID else { return }
        DanmakuTextRenderer.store((raw as! CGImage), for: model.cacheKey)
    }
}

/// 弹幕引擎：对外只暴露"按播放头推进"的 `update`，内部把弹幕喂给 DanmakuKit。
///
/// 生成/回收由播放头驱动（而不是按墙钟时间），因此暂停、快进、拖进度条、切换分P、
/// 进出全屏都能落到正确的播放位置；弹幕位移交给 Core Animation 在渲染侧推进。
@MainActor
final class DanmakuEngine {
    /// 基准舞台宽度：内嵌播放器最大内容宽度（980 内容列 - 两侧 24pt 内边距）。
    /// 全屏时容器变宽，字号/轨道按 width/baseWidth 等比放大，横穿时间不变。
    private static let baseWidth: CGFloat = 932
    private static let rowHeight: CGFloat = 26
    private static let topInset: CGFloat = 6
    private static let bottomReserve: CGFloat = 40
    /// 播放头跳变超过该值视为 seek（快进/快退/拖进度条/切分P）
    private static let seekThreshold: Double = 3.0
    /// 弹幕最长生存时长：seek 后按它回填画面中部
    private static let maxLife: Double = 10

    /// 滚动 + 顶部弹幕
    let danmakuView = DanmakuView(frame: .zero)
    /// 底部固定弹幕单独一张视图：全屏过渡时底部弹幕要绕画面**下边**缩放，
    /// 顶部/滚动弹幕绕**上边**缩放，容器宽高比变化时两者的位移量并不相同
    /// （见 `DanmakuOverlayView` 的两个舞台层）。
    let bottomDanmakuView = DanmakuView(frame: .zero)

    private var items: [DanmakuItem] = []
    /// 下一条待发射弹幕在 items 中的下标（items 按时间升序）
    private var nextIndex = 0
    private var lastPlayerTime = 0.0
    private var lastPlaying = false
    /// 当前舞台基准尺寸与缩放比例：弹幕的坐标、字号、轨道都基于它
    private(set) var stageSize: CGSize = .zero
    private var stageScale: CGFloat = 1
    /// 最近一次应用到弹幕视图上的播放倍速（长按右方向键 2 倍速时跟随）
    private var appliedRate: Float = 0
    /// 最近一次应用的外观设置（避免每帧 updateNSView 都重设一遍库属性）
    private var appliedSettings: DanmakuSettings?
    /// 用户字号缩放：作为舞台缩放的额外倍数，纯 transform，不重排轨道
    private(set) var fontScale: CGFloat = 1
    /// 文字位图的栅格化倍率（跟随窗口 backing scale）
    private var renderScale: CGFloat = PlatformScreen.mainScale(fallback: 2)
    /// 舞台基准之外的额外显示缩放（全屏跟随期间由渲染层传入）
    private var displayScale: CGFloat = 1

    /// 文字位图当前该用的栅格化密度：屏幕 backing scale × 显示缩放。
    /// 舞台坐标永远是基准尺寸，靠舞台层缩放显示；密度跟着一起放大，
    /// 放大后的文字才清晰。
    private var displayDensity: CGFloat { renderScale * displayScale }

    init() {
        configure(danmakuView)
        configure(bottomDanmakuView)
        danmakuView.enableBottomDanmaku = false
        bottomDanmakuView.enableFloatingDanmaku = false
        bottomDanmakuView.enableTopDanmaku = false
    }

    private func configure(_ view: DanmakuView) {
        // 密集弹幕（每秒上百条）会大量被"轨道已满"拒绝：开启复用后这些 cell
        // 回到池里而不是被丢弃，重建只发生在新 cell 上
        view.enableCellReusable = true
        view.displayArea = 1
        view.isOverlap = false
        view.trackHeight = Self.rowHeight
        view.paddingTop = Self.topInset
        view.paddingBottom = Self.bottomReserve
        view.viewAlpha = CGFloat(DanmakuSettings.default.opacity)
    }

    // MARK: - 外观 / 行为设置

    /// 应用弹幕设置（不透明度、显示区域、显示类型、是否允许重叠、字号缩放）。
    ///
    /// 前四项都是 DanmakuKit 的现成属性，改完即时生效（关掉某类型会立刻清掉那类弹幕）。
    /// 字号缩放不重排轨道：它作为舞台缩放的额外倍数，整层等比放大，所以拖动滑杆时
    /// 在屏弹幕会连续变化，而不是"等新弹幕才生效"。
    func apply(_ settings: DanmakuSettings) {
        guard settings != appliedSettings else { return }
        appliedSettings = settings
        fontScale = CGFloat(settings.fontScale)
        for view in views {
            view.viewAlpha = CGFloat(settings.opacity)
            view.displayArea = CGFloat(settings.displayArea.rawValue)
            view.isOverlap = settings.allowsOverlap
        }
        danmakuView.enableFloatingDanmaku = settings.showsFloating
        danmakuView.enableTopDanmaku = settings.showsTop
        bottomDanmakuView.enableBottomDanmaku = settings.showsBottom
    }

    // MARK: - 数据

    func load(_ source: [DanmakuItem]) {
        items = source.sorted { $0.time < $1.time }
        reset()
    }

    func reset() {
        for view in views {
            view.stop()
            view.clean()
        }
        nextIndex = 0
        lastPlayerTime = 0
        lastPlaying = false
    }

    /// 关闭弹幕：只清掉屏上的弹幕，不改播放进度（重新打开时接着放）。
    func clearVisible() {
        for view in views {
            view.pause()
            view.clean()
        }
    }

    // MARK: - 舞台

    /// 建立/更新舞台基准：弹幕的坐标、字号、轨道高度都按这个尺寸换算。
    /// 只调整几何，不动正在飘的弹幕（全屏过渡期间由渲染层负责缩放跟随）。
    func setStage(size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - stageSize.width) > 0.5
                || abs(size.height - stageSize.height) > 0.5 else { return }
        stageSize = size
        stageScale = min(max(size.width / Self.baseWidth, 0.45), 5)
        let frame = CGRect(origin: .zero, size: size)
        for view in views {
            view.frame = frame
            view.paddingTop = Self.topInset * stageScale
            view.paddingBottom = Self.bottomReserve * stageScale
            view.trackHeight = Self.rowHeight * stageScale
            view.recalculateTracks()
        }
    }

    // MARK: - 每帧推进

    func update(playerTime: Double, isPlaying: Bool, rate: Float) {
        guard playerTime.isFinite, stageSize != .zero else { return }
        lastPlaying = isPlaying

        // 播放倍速（长按 → 2 倍速）同步给弹幕，位移速度与画面一致
        let playingRate: Float = isPlaying ? max(rate, 0.1) : 1
        if abs(playingRate - appliedRate) > 0.05 {
            appliedRate = playingRate
            for view in views { view.playingSpeed = playingRate }
        }

        // seek：清屏并按新播放头回填画面中部（而不是让旧弹幕继续飘走）
        if playerTime < lastPlayerTime || playerTime - lastPlayerTime > Self.seekThreshold {
            reseed(at: playerTime, isPlaying: isPlaying)
            lastPlayerTime = playerTime
            return
        }
        lastPlayerTime = playerTime

        guard isPlaying else {
            // 暂停/缓冲：弹幕一起钉住（动画被移除，恢复时按剩余路程续走）
            for view in views where view.status == .play { view.pause() }
            return
        }
        for view in views where view.status != .play { view.play() }
        shootDue(until: playerTime)
    }

    // MARK: - 发射

    private var views: [DanmakuView] { [danmakuView, bottomDanmakuView] }

    private func view(for type: DanmakuCellType) -> DanmakuView {
        type == .bottom ? bottomDanmakuView : danmakuView
    }

    private func shootDue(until time: Double) {
        let duration = DanmakuSpeed.current.duration
        while nextIndex < items.count, items[nextIndex].time <= time {
            let item = items[nextIndex]
            nextIndex += 1
            let model = makeModel(item, duration: duration)
            view(for: model.type).shoot(danmaku: model)
        }
    }

    /// 清屏并按播放头回填：已经在屏上的弹幕按各自进度 `sync` 到画面中部，
    /// 尚未出现的留给后续帧正常发射。
    private func reseed(at time: Double, isPlaying: Bool) {
        for view in views {
            view.clean()
            // DanmakuKit 的 sync 只在非 stop 状态下生效；暂停中也要先把状态推离 stop
            if view.status == .stop { view.play() }
            if !isPlaying, view.status == .play { view.pause() }
        }

        let duration = DanmakuSpeed.current.duration
        var index = firstIndex(atOrAfter: time - Self.maxLife)
        while index < items.count, items[index].time <= time {
            let item = items[index]
            index += 1
            let model = makeModel(item, duration: duration)
            let progress = (time - item.time) / model.displayTime
            // 已经飘出画面的弹幕不再回填（顶部/底部固定弹幕停留更短，按各自时长算）
            guard progress < 1 else { continue }
            let target = view(for: model.type)
            if progress <= 0.05 {
                target.shoot(danmaku: model)
            } else if !target.sync(danmaku: model, at: Float(progress)) {
                // 轨道满了就丢弃，与播放中的行为一致
                target.shoot(danmaku: model)
            }
        }
        nextIndex = firstIndex(atOrAfter: time)
    }

    private func makeModel(_ item: DanmakuItem, duration: Double) -> BilibiliDanmakuModel {
        BilibiliDanmakuModel(item: item, stageScale: stageScale,
                             duration: duration, renderScale: displayDensity)
    }

    /// 换屏 / 分辨率变化时更新 backing scale（缓存键里带密度，不会误命中旧图）
    func setRenderScale(_ scale: CGFloat) {
        guard scale > 0.5, abs(scale - renderScale) > 0.01 else { return }
        renderScale = scale
    }

    /// 显示缩放变化（全屏过渡跟随）：之后新发射的弹幕直接按新的显示密度栅格化。
    func setDisplayScale(_ scale: CGFloat) {
        displayScale = min(max(scale, 0.05), 8)
    }

    /// 过渡结束：把在屏弹幕的文字位图按新的显示密度重画一遍。
    ///
    /// **几何完全不动**——不重排轨道、不重建 cell，所以弹幕不会换行、不会闪，
    /// 只是把跟着画面放大后变糊的位图重新画清楚（每条各自异步重画，画好即替换）。
    func rerasterizeLiveCells() {
        let density = displayDensity
        for view in views {
            for case let cell as BilibiliDanmakuCell in view.subviews
            where (cell.backingLayer?.opacity ?? 0) > 0.01 {
                guard let model = cell.model as? BilibiliDanmakuModel,
                      abs(model.renderScale - density) > 0.05 else { continue }
                model.renderScale = density
                cell.redraw()
            }
        }
    }

    /// items 按时间升序，二分查找第一条 time >= 给定时间的下标
    private func firstIndex(atOrAfter time: Double) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].time < time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

}
