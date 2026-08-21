import AppKit
import SwiftUI

/// 弹幕引擎：负责轨道分配、按播放时间生成/回收弹幕、计算位置。
/// 每次画面刷新调用 tick(playerTime:size:)，渲染层直接读 active。
@MainActor
final class DanmakuEngine: ObservableObject {
    struct Active: Identifiable {
        let id: Int
        let text: String
        let color: Color
        let scale: CGFloat
        let mode: Int          // 1 滚动 / 4 底部 / 5 顶部
        let lane: Int          // 轨道编号
        let startTime: Double  // 该弹幕进入画面的播放器时间
        let speed: CGFloat     // 滚动速度（px/s，用于轨道避让）
        let textWidth: CGFloat
        let spawnWidth: CGFloat  // 生成时的容器宽度（滚动位置归一化基准）
        let yFraction: CGFloat   // 生成时的纵向位置比例（0-1，随窗口缩放同步）

        static let rowHeight: CGFloat = 26
        static let topInset: CGFloat = 6
        static let bottomReserve: CGFloat = 40
        static let scrollDuration = 8.0
        static let fixedDuration = 4.5
        static let maxActive = 100

        var isScroll: Bool { mode == 1 }

        /// 滚动弹幕越过后半段时才真正占住轨道（尾端完全进入画面后放行下一跳）
        var tailEnterDuration: Double {
            guard speed > 0 else { return Active.scrollDuration }
            return Double(textWidth / speed)
        }

        /// 位置使用归一化坐标（比例），窗口缩放时弹幕随视频一起缩放，不跳变。
        func position(in size: CGSize, at time: Double) -> CGPoint {
            if mode == 1 {
                let progress = min(max((time - startTime) / Self.scrollDuration, 0), 1)
                let travel = (1 + textWidth / max(spawnWidth, 1)) * progress
                let x = size.width * (1 - travel)
                return CGPoint(x: x, y: size.height * yFraction)
            }
            return CGPoint(x: size.width / 2, y: size.height * yFraction)
        }

        func isFinished(at time: Double) -> Bool {
            let progress = time - startTime
            return progress >= (isScroll ? Self.scrollDuration : Self.fixedDuration)
        }
    }

    @Published private(set) var active: [Active] = []

    private var all: [DanmakuItem] = []
    private var nextIndex = 0
    private var configuredSize: CGSize = .zero

    private struct LaneState {
        var lastStart: Double = -1
        var lastSpeed: CGFloat = 0
        var lastWidth: CGFloat = 0
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
        guard size.width > 0, size.height > 0, playerTime.isFinite else { return }
        if size != configuredSize {
            configuredSize = size
            rebuildLanes(size: size)
        }

        let t = playerTime

        // 生成新弹幕（跳过时间跨度大于 2.5s 的，避免拖动进度条时瞬间堆满）
        while nextIndex < all.count, all[nextIndex].time <= t {
            let item = all[nextIndex]
            nextIndex += 1
            if t - item.time < 2.5 {
                spawn(item, time: t, size: size)
            }
        }

        // 回收已离开画面的弹幕
        if !active.isEmpty {
            active.removeAll { $0.isFinished(at: t) }
        }
    }

    // MARK: - 轨道与生成

    private func rebuildLanes(size: CGSize) {
        let usable = max(1, size.height - Active.topInset - Active.bottomReserve)
        let scrollCount = max(3, Int(usable / Active.rowHeight))
        scrollLanes = Array(repeating: LaneState(), count: scrollCount)
        let fixedCount = max(2, Int(usable / (Active.rowHeight * 1.2)))
        topLanes = Array(repeating: LaneState(), count: min(fixedCount, 6))
        bottomLanes = Array(repeating: LaneState(), count: min(fixedCount, 6))
    }

    private func spawn(_ item: DanmakuItem, time: Double, size: CGSize) {
        guard active.count < Active.maxActive else { return }
        let scale = min(max(CGFloat(item.fontSize) / 18.0, 0.6), 1.8)
        let textWidth = Self.estimateWidth(text: item.text, scale: scale)
        let color = Self.color(from: item.color)

        switch item.mode {
        case 1:
            guard let lane = freeScrollLane(time: time, width: size.width) else { return }
            let speed = (size.width + textWidth) / CGFloat(Active.scrollDuration)
            scrollLanes[lane] = LaneState(lastStart: time,
                                          lastSpeed: speed,
                                          lastWidth: textWidth)
            let yFraction = (Active.topInset + CGFloat(lane) * Active.rowHeight + Active.rowHeight / 2) / size.height
            active.append(Active(id: item.id,
                                 text: item.text,
                                 color: color,
                                 scale: scale,
                                 mode: 1,
                                 lane: lane,
                                 startTime: time,
                                 speed: speed,
                                 textWidth: textWidth,
                                 spawnWidth: size.width,
                                 yFraction: yFraction))
        case 5:
            guard let lane = freeFixedLane(topLanes, time: time, isTop: true),
                  lane >= 0, lane < topLanes.count else { return }
            topLanes[lane] = LaneState(lastStart: time, lastSpeed: 0, lastWidth: 0)
            let yFraction = (Active.topInset + CGFloat(lane) * Active.rowHeight + Active.rowHeight / 2) / size.height
            active.append(Active(id: item.id,
                                 text: item.text,
                                 color: color,
                                 scale: scale,
                                 mode: 5,
                                 lane: lane,
                                 startTime: time,
                                 speed: 0,
                                 textWidth: textWidth,
                                 spawnWidth: size.width,
                                 yFraction: yFraction))
        case 4:
            guard let lane = freeFixedLane(bottomLanes, time: time, isTop: false),
                  lane >= 0, lane < bottomLanes.count else { return }
            bottomLanes[lane] = LaneState(lastStart: time, lastSpeed: 0, lastWidth: 0)
            let yFraction = (size.height - Active.bottomReserve - CGFloat(lane) * Active.rowHeight - Active.rowHeight / 2) / size.height
            active.append(Active(id: item.id,
                                 text: item.text,
                                 color: color,
                                 scale: scale,
                                 mode: 4,
                                 lane: lane,
                                 startTime: time,
                                 speed: 0,
                                 textWidth: textWidth,
                                 spawnWidth: size.width,
                                 yFraction: yFraction))
        default:
            break
        }
    }

    private func freeScrollLane(time: Double, width: CGFloat) -> Int? {
        for (i, lane) in scrollLanes.enumerated() {
            guard lane.lastStart >= 0 else { return i }
            let tailEnter = lane.lastStart + Double(lane.lastWidth / max(lane.lastSpeed, 1))
            if time >= tailEnter + 0.35 {
                return i
            }
        }
        return nil
    }

    private func freeFixedLane(_ lanes: [LaneState], time: Double, isTop: Bool) -> Int? {
        let count = lanes.count
        // 顶部：从上往下找；底部：从下往上找
        let order = isTop ? Array(0..<count) : Array((0..<count).reversed())
        for i in order {
            let lane = lanes[i]
            if lane.lastStart < 0 || time >= lane.lastStart + Active.fixedDuration + 0.2 {
                return i
            }
        }
        return nil
    }

    // MARK: - 工具

    private static func estimateWidth(text: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 20 * scale, weight: .bold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    private static func color(from raw: UInt32) -> Color {
        if raw == 0xFFFFFF {
            return .white
        }
        let r = Double((raw >> 16) & 0xFF) / 255.0
        let g = Double((raw >> 8) & 0xFF) / 255.0
        let b = Double(raw & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
