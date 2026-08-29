import AppKit
import CoreGraphics
import Foundation

/// 弹幕速度档位（设置页可选），通过缩放横穿时长实现
enum DanmakuSpeed: String, CaseIterable, Identifiable {
    case relaxed
    case normal
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relaxed: return "舒缓"
        case .normal: return "标准"
        case .fast: return "快速"
        }
    }

    /// 滚动弹幕横穿屏幕的总时长（秒），越大越慢
    var duration: Double {
        switch self {
        case .relaxed: return 10
        case .normal: return 8
        case .fast: return 6
        }
    }

    static var current: DanmakuSpeed {
        let raw = UserDefaults.standard.string(forKey: "danmakuSpeed") ?? ""
        return DanmakuSpeed(rawValue: raw) ?? .normal
    }
}

/// 弹幕引擎：纯逻辑，负责轨道分配、按播放时间生成/回收弹幕、计算位置。
/// 不发布任何状态、不触发视图刷新；渲染层每帧调用 tick 后直接读 active。
@MainActor
final class DanmakuEngine {
    struct Active: Identifiable {
        let id: Int
        let text: String
        let color: CGColor
        let scale: CGFloat
        let mode: Int          // 1 滚动 / 4 底部 / 5 顶部
        let lane: Int          // 轨道编号
        let startTime: Double  // 该弹幕进入画面的播放器时间
        let duration: Double   // 总生存时长（滚动由弹幕速度设置决定，固定=4.5s）
        let textWidth: CGFloat // 基准舞台宽度（baseWidth）下的文字宽度

        /// 基准舞台宽度：对应内嵌播放器最大宽度（980 内容列 - 两侧 24pt 内边距）。
        /// 全屏时容器变宽，字号/轨道/滚动路径都按 width/baseWidth 等比放大，
        /// 横穿时间不变——观感与官网网页端一致（舞台整体放大，而不是弹幕变快）。
        static let baseWidth: CGFloat = 932
        static let rowHeight: CGFloat = 26
        static let topInset: CGFloat = 6
        static let bottomReserve: CGFloat = 40
        static let fixedDuration = 4.5
        static let maxActive = 100

        /// 当前容器宽度对应的舞台缩放比例
        func stageScale(for width: CGFloat) -> CGFloat {
            width / Self.baseWidth
        }

        /// 当前容器宽度下应渲染的字号
        func fontSize(for width: CGFloat) -> CGFloat {
            18 * scale * stageScale(for: width)
        }

        /// 当前容器宽度下的文字层宽度
        func width(for width: CGFloat) -> CGFloat {
            textWidth * stageScale(for: width)
        }

        /// 弹幕中心位置（左上角原点，与 SwiftUI 画布坐标一致）
        func position(in size: CGSize, at time: Double) -> CGPoint {
            let s = stageScale(for: size.width)
            let row = Self.rowHeight * s
            let inset = Self.topInset * s
            let reserve = Self.bottomReserve * s
            let y: CGFloat
            switch mode {
            case 4:
                y = size.height - reserve - CGFloat(lane) * row - row / 2
            default:
                y = inset + CGFloat(lane) * row + row / 2
            }
            if mode == 1 {
                // progress 是 0...1 的归一化进度（经过秒数 / 总横穿时长），
                // 再乘总行程，避免直接把“秒 × 像素”当成速度导致弹幕快十倍。
                let progress = min(max((time - startTime) / duration, 0), 1)
                let travel = size.width + width(for: size.width)
                let x = size.width - CGFloat(progress) * travel
                return CGPoint(x: x, y: y)
            }
            return CGPoint(x: size.width / 2, y: y)
        }

        func isFinished(at time: Double) -> Bool {
            time - startTime >= duration
        }
    }

    private(set) var active: [Active] = []

    private var all: [DanmakuItem] = []
    private var nextIndex = 0
    private var configuredSize: CGSize = .zero
    /// 上一帧播放时间：用于侦测 seek 跳变
    private var lastTickTime: Double = 0
    /// 时间差超过该值视为 seek（快进/快退/拖进度条）
    private static let seekThreshold: Double = 3.0

    private struct LaneState {
        /// 该轨道可被复用的最早时间（滚动=尾端进入+0.35s；固定=上一条结束+0.2s）
        var busyUntil: Double = -1
    }
    private var scrollLanes: [LaneState] = []
    private var topLanes: [LaneState] = []
    private var bottomLanes: [LaneState] = []

    // MARK: - 数据

    func load(_ items: [DanmakuItem]) {
        all = items.sorted { $0.time < $1.time }
        reset()
    }

    func reset() {
        active = []
        nextIndex = 0
        lastTickTime = 0
        scrollLanes = []
        topLanes = []
        bottomLanes = []
        configuredSize = .zero
    }

    /// 清空当前屏幕上的弹幕（关闭开关时调用）。
    func clear() {
        active = []
    }

    // MARK: - 每帧更新

    func tick(playerTime: Double, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // seek 瞬时的非有限时间（如 kCMTimeInvalid）：跳过本帧，避免误当成 0 秒
        guard playerTime.isFinite else { return }
        let t = playerTime

        // 侦测 seek：时间回退或大步前进时，清空画面、重置轨道并把指针回退到
        // 目标时间附近，让新位置附近的弹幕重新生成。否则旧弹幕 startTime 在未来，
        // 永不回收、占着轨道，表现为画面冻住。
        let jump = t - lastTickTime
        if t < lastTickTime || jump > Self.seekThreshold {
            active = []
            rebuildLanes(size: size)
            nextIndex = firstIndex(atOrAfter: t - 2.5)
            lastTickTime = t
            return
        }
        lastTickTime = t

        if size != configuredSize {
            configuredSize = size
            rebuildLanes(size: size)
        }

        // 生成新弹幕（跳过时间跨度大于 2.5s 的，避免拖动进度条时瞬间堆满）。
        // 每帧最多生成 6 条：seek 后摊开铺满，避免单帧压力瞬间爆表。
        var spawnedThisTick = 0
        while nextIndex < all.count, all[nextIndex].time <= t, spawnedThisTick < 6 {
            let item = all[nextIndex]
            nextIndex += 1
            if t - item.time < 2.5 {
                spawn(item, time: t, size: size)
                spawnedThisTick += 1
            }
        }

        // 回收已离开画面的弹幕
        if !active.isEmpty {
            active.removeAll { $0.isFinished(at: t) }
        }
    }

    /// all 按时间升序，二分查找第一条 time >= 给定时间的下标
    private func firstIndex(atOrAfter time: Double) -> Int {
        var lo = 0
        var hi = all.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].time < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    // MARK: - 轨道与生成

    private func rebuildLanes(size: CGSize) {
        let s = size.width / Active.baseWidth
        let row = Active.rowHeight * s
        let usable = max(1, size.height - (Active.topInset + Active.bottomReserve) * s)
        let scrollCount = max(3, Int(usable / row))
        scrollLanes = Array(repeating: LaneState(), count: scrollCount)
        let fixedCount = max(2, Int(usable / (row * 1.2)))
        topLanes = Array(repeating: LaneState(), count: min(fixedCount, 6))
        bottomLanes = Array(repeating: LaneState(), count: min(fixedCount, 6))
    }

    private func spawn(_ item: DanmakuItem, time: Double, size: CGSize) {
        guard active.count < Active.maxActive else { return }
        let scale = min(max(CGFloat(item.fontSize) / 18.0, 0.6), 1.8)
        let textWidth = Self.estimateWidth(text: item.text, scale: scale)
        let color = Self.cgColor(from: item.color)

        switch item.mode {
        case 1:
            guard let lane = freeScrollLane(time: time) else { return }
            let duration = DanmakuSpeed.current.duration
            let tailEnter = duration * (textWidth / Active.baseWidth) /
                (1 + textWidth / Active.baseWidth)
            scrollLanes[lane] = LaneState(busyUntil: time + tailEnter + 0.35)
            active.append(Active(id: item.id,
                                 text: item.text,
                                 color: color,
                                 scale: scale,
                                 mode: 1,
                                 lane: lane,
                                 startTime: time,
                                 duration: duration,
                                 textWidth: textWidth))
        case 5:
            guard let lane = freeFixedLane(topLanes, time: time, isTop: true),
                  lane >= 0, lane < topLanes.count else { return }
            topLanes[lane] = LaneState(busyUntil: time + Active.fixedDuration + 0.2)
            active.append(Active(id: item.id,
                                 text: item.text,
                                 color: color,
                                 scale: scale,
                                 mode: 5,
                                 lane: lane,
                                 startTime: time,
                                 duration: Active.fixedDuration,
                                 textWidth: textWidth))
        case 4:
            guard let lane = freeFixedLane(bottomLanes, time: time, isTop: false),
                  lane >= 0, lane < bottomLanes.count else { return }
            bottomLanes[lane] = LaneState(busyUntil: time + Active.fixedDuration + 0.2)
            active.append(Active(id: item.id,
                                 text: item.text,
                                 color: color,
                                 scale: scale,
                                 mode: 4,
                                 lane: lane,
                                 startTime: time,
                                 duration: Active.fixedDuration,
                                 textWidth: textWidth))
        default:
            break
        }
    }

    private func freeScrollLane(time: Double) -> Int? {
        for (i, lane) in scrollLanes.enumerated() where time >= lane.busyUntil {
            return i
        }
        return nil
    }

    private func freeFixedLane(_ lanes: [LaneState], time: Double, isTop: Bool) -> Int? {
        let count = lanes.count
        // 顶部：从上往下找；底部：从下往上找
        let order = isTop ? Array(0..<count) : Array((0..<count).reversed())
        for i in order {
            let lane = lanes[i]
            if time >= lane.busyUntil {
                return i
            }
        }
        return nil
    }

    // MARK: - 工具

    private static func estimateWidth(text: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 18 * scale, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func cgColor(from raw: UInt32) -> CGColor {
        if raw == 0xFFFFFF {
            return CGColor(gray: 1, alpha: 1)
        }
        let r = CGFloat((raw >> 16) & 0xFF) / 255.0
        let g = CGFloat((raw >> 8) & 0xFF) / 255.0
        let b = CGFloat(raw & 0xFF) / 255.0
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
