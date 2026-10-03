import Foundation

/// 空降的判定逻辑。
///
/// 刻意做成不碰 `AVPlayer` 的纯值类型：输入的只有播放位置与节拍，
/// 输出的是「该做什么」，因此可以脱离播放器单独推演与验证。
///
/// 三个必须处理对的状态：
/// 1. **不能重复跳**：seek 到片段末尾后，下一个节拍仍可能落在区间内，
///    所以跳过过的片段要记住。
/// 2. **用户手动拖回去要重新武装**：拖到片段前面之后，那段应该重新生效。
/// 3. **静音只恢复自己按下去的**：用户自己点的静音不能被我们擅自解除。
struct SponsorSkipEngine {

    /// 一个节拍算出来的结论。
    enum Outcome: Equatable {
        case none
        /// 跳到该片段的末尾。
        case skip(SponsorSegment)
        /// 进入静音片段。
        case mute(SponsorSegment)
        /// 离开静音片段。
        case unmute
    }

    /// 参与处理的片段（已按设置过滤），按开始时间升序。
    private(set) var segments: [SponsorSegment]

    /// 已经跳过的片段 id。
    private var handled: Set<String> = []
    /// 用户明确「回退」过的片段 id：本场播放内不再拦截它们。
    /// 与 `handled` 分开，是因为 `handled` 会在用户拖回去时被重新武装，
    /// 而这里的「我不想跳这段」必须一直有效。
    private var ignored: Set<String> = []
    /// 上一次节拍的播放位置与时刻，用于识别「用户手动拖动」。
    private var lastPosition: Double?
    private var lastTickAt: Date?
    /// 当前正在静音的片段 id（由本引擎自己维护，避免误碰用户的静音）。
    private var mutedSegmentID: String?

    init(segments: [SponsorSegment] = []) {
        self.segments = segments.sorted { $0.start < $1.start }
    }

    // MARK: - 输入

    /// 换一批片段（切视频 / 切分P / 设置变更）。会一并清空「已跳过」记录。
    mutating func update(segments: [SponsorSegment]) {
        self.segments = segments.sorted { $0.start < $1.start }
        handled.removeAll()
        ignored.removeAll()
        lastPosition = nil
        lastTickAt = nil
        mutedSegmentID = nil
    }

    /// 用户点了「回退」：这一场播放里不再拦截这段。
    ///
    /// 同时从 `handled` 里摘掉，是为了让「回退」的语义干净——
    /// 这段回到「未处理」状态，只是被拉进了黑名单。
    mutating func ignore(_ segment: SponsorSegment) {
        ignored.insert(segment.id)
        handled.remove(segment.id)
        // 如果正在为这段静音，顺手把内部状态清掉，
        // 免得下一拍拿着陈旧状态多报一次 unmute
        if mutedSegmentID == segment.id {
            mutedSegmentID = nil
        }
    }

    /// 一次节拍。
    ///
    /// - Parameters:
    ///   - position: 当前播放位置（秒）。
    ///   - rate: 当前倍速，用来估算两个节拍之间「正常播放」至多能推进多少。
    ///   - now: 本次节拍的时刻。默认取当前时间，测试里可以显式传入。
    mutating func tick(position: Double, rate: Float, now: Date = Date()) -> Outcome {
        detectSeek(position: position, rate: rate, now: now)
        lastPosition = position
        lastTickAt = now

        // 1) 跳过优先：它比静音更强，跳出去之后下一拍自然重新判定
        if let segment = pendingSkip(at: position) {
            handled.insert(segment.id)
            // 跳走之后必然离开静音区，状态一并清掉，下一拍会按需重新进入
            mutedSegmentID = nil
            return .skip(segment)
        }

        // 2) 静音：只报「状态变化」，不反复喊
        let activeMute = segments.first {
            $0.action == .mute && !ignored.contains($0.id) && $0.contains(position)
        }
        if let activeMute {
            if mutedSegmentID != activeMute.id {
                mutedSegmentID = activeMute.id
                return .mute(activeMute)
            }
        } else if mutedSegmentID != nil {
            mutedSegmentID = nil
            return .unmute
        }

        return .none
    }

    /// 该位置命中的、尚未跳过且未被回退的片段。
    func pendingSkip(at position: Double) -> SponsorSegment? {
        segments.first {
            $0.action == .skip
                && !handled.contains($0.id)
                && !ignored.contains($0.id)
                && $0.contains(position)
        }
    }

    // MARK: - 进度条标记

    /// 进度条上要画的色块（跳过与静音类都标出来，用户能看到「这里有个广告」）。
    var markers: [SponsorMarker] {
        segments.map {
            SponsorMarker(id: $0.id, start: $0.start, end: $0.end, category: $0.category)
        }
    }

    // MARK: - 内部

    /// 识别用户拖动。
    ///
    /// 关键是拿「实际经过的时间」而不是节拍名义间隔去算：主线程一忙，
    /// 0.25 秒的节拍可能隔了 1 秒才到，那时位置前进了 1 秒是正常的，
    /// 用固定阈值会把这种正常播放误判成拖动（进而反复重新武装片段）。
    private mutating func detectSeek(position: Double, rate: Float, now: Date) {
        guard let lastPosition, let lastTickAt else { return }

        let elapsed = max(now.timeIntervalSince(lastTickAt), 0)
        // 正常播放至多推进 rate × 经过时间；留 50% 余量再给 0.5 秒容错
        let maxAdvance = Double(max(rate, 0)) * elapsed * 1.5 + 0.5
        let jump = position - lastPosition
        guard jump > maxAdvance || jump < -0.5 else { return }

        // 用户回到了某个片段之前：把它重新武装，下次进入还会跳
        let rearmed = segments.filter { $0.start >= position }.map(\.id)
        handled.subtract(rearmed)

        // 拖动之后静音状态归零，让下一拍重新判定
        mutedSegmentID = nil
    }
}
