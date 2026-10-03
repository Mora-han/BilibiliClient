import Foundation

// MARK: - 片段

/// 一条空降片段。
///
/// 数据来自 SponsorBlock 兼容接口 `GET /api/skipSegments/{hashPrefix}`，
/// 该接口一次返回「哈希前缀相同」的一批视频，所以这里只承载单条片段，
/// 归属由 `SponsorBlockService` 负责筛。
struct SponsorSegment: Identifiable, Hashable, Sendable {
    /// 服务端 UUID，用来做「这条已经跳过了」的标记。
    let id: String
    let category: SponsorCategory
    let action: SponsorAction
    /// 起始秒。
    let start: Double
    /// 结束秒。
    let end: Double
    /// 所属分P（服务端返回的是字符串，这里转成 Int 方便比对）。
    let cid: Int?
    /// 该片段标注时的视频总时长，用于分辨同名分P。
    let videoDuration: Double
    /// 净赞数（服务端字段就是净票）。
    let votes: Int
    let description: String

    /// 片段区间（结束早于开始时收敛成一个点，避免出现非法区间）。
    var range: ClosedRange<Double> { start...max(end, start) }

    /// 片段时长。
    var duration: Double { max(end - start, 0) }

    /// 是否覆盖整个视频（`actionType == full`，即「整片都是广告」）。
    ///
    /// 这类片段**绝不能被当作跳过区间**，否则一按就等于跳完整支视频。
    var coversWholeVideo: Bool { action == .full }

    func contains(_ position: Double) -> Bool {
        position >= start && position < end
    }
}

// MARK: - 动作

/// 片段该被怎么处理。
enum SponsorAction: String, Sendable, CaseIterable {
    /// 自动跳过。
    case skip
    /// 跳到这个位置（高光点），不做自动处理。
    case poi
    /// 静音通过。
    case mute
    /// 整支视频都算广告。
    case full

    var label: String {
        switch self {
        case .skip: "跳过"
        case .poi: "高光"
        case .mute: "静音"
        case .full: "整片标记"
        }
    }
}

// MARK: - 分类

/// 片段分类，取值与上游 `config.json` 的 `categoryList` 一致。
enum SponsorCategory: String, CaseIterable, Identifiable, Sendable {
    case sponsor
    case selfpromo
    case exclusiveAccess = "exclusive_access"
    case interaction
    case poiHighlight = "poi_highlight"
    case intro
    case outro
    case preview
    case padding
    case filler
    case musicOfftopic = "music_offtopic"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sponsor: "赞助广告"
        case .selfpromo: "自我推广"
        case .exclusiveAccess: "品牌合作"
        case .interaction: "三连提醒"
        case .poiHighlight: "高光时刻"
        case .intro: "开场动画"
        case .outro: "片尾"
        case .preview: "预告回顾"
        case .padding: "填充内容"
        case .filler: "跑题闲聊"
        case .musicOfftopic: "非音乐片段"
        }
    }

    /// 进度条上色块的颜色语义。
    var markerColorHex: String {
        switch self {
        case .sponsor: "#00A3A3"
        case .selfpromo: "#FFD700"
        case .exclusiveAccess: "#7A5CFF"
        case .interaction: "#CC66FF"
        case .poiHighlight: "#FF66CC"
        case .intro: "#00CCCC"
        case .outro: "#00CCCC"
        case .preview: "#0088CC"
        case .padding: "#FF9900"
        case .filler: "#FF9900"
        case .musicOfftopic: "#99CC00"
        }
    }

    /// 默认是否启用。
    ///
    /// 排除 `poiHighlight`（那是「跳过去」不是「跳过去」）和 `exclusiveAccess`
    /// （它只支持 `full`，而整片标记不适合自动跳过）。
    var isEnabledByDefault: Bool {
        switch self {
        case .poiHighlight, .exclusiveAccess: false
        default: true
        }
    }

    /// 该分类能被自动处理的动作。
    var supportedActions: Set<SponsorAction> {
        switch self {
        case .sponsor, .selfpromo: [.skip, .mute, .full]
        case .exclusiveAccess: [.full]
        case .interaction, .intro, .outro, .preview, .filler: [.skip, .mute]
        case .musicOfftopic, .padding: [.skip]
        case .poiHighlight: [.poi]
        }
    }
}

// MARK: - 进度条标记

/// 进度条上的一个色块。
struct SponsorMarker: Identifiable, Hashable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let category: SponsorCategory
}

// MARK: - 跳过提示

/// 画面上的一次空降提示，用于告诉用户「刚刚做了什么」，并支持一键回退。
struct SponsorNotice: Identifiable, Equatable, Sendable {

    /// 这条提示对应的事件。
    enum Kind: Equatable, Sendable {
        /// 自动跳过了一段。
        case skipped(SponsorSegment)
        /// 自动静音了一段。
        case muted(SponsorSegment)
        /// 用户撤销了上面这次处理。
        case undone(SponsorSegment)
    }

    let id: UUID
    let kind: Kind

    init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
    }

    /// 涉及的片段。
    var segment: SponsorSegment {
        switch kind {
        case .skipped(let segment), .muted(let segment), .undone(let segment):
            return segment
        }
    }

    /// 是否还能点「回退」。撤销提示本身不再可撤销。
    var isUndoable: Bool {
        if case .undone = kind { return false }
        return true
    }

    /// 是否是静音类事件。
    var isMuted: Bool {
        if case .muted = kind { return true }
        return false
    }

    var text: String {
        switch kind {
        case .skipped(let segment):
            return "已跳过\(segment.category.displayName) · \(Int(segment.duration.rounded())) 秒"
        case .muted(let segment):
            return "已静音\(segment.category.displayName) · \(Int(segment.duration.rounded())) 秒"
        case .undone:
            return "已回退 · 这段不再自动跳过"
        }
    }

    /// 卡片标题。
    var title: String {
        switch kind {
        case .skipped: "已跳过赞助片段"
        case .muted: "已静音赞助片段"
        case .undone: "已回退"
        }
    }

    /// 卡片副标题：说清楚跳的是哪一类、多长，以及回退会发生什么。
    var subtitle: String {
        let category = segment.category.displayName
        let seconds = "\(Int(segment.duration.rounded())) 秒"
        switch kind {
        case .skipped: return "\(category) · \(seconds)"
        case .muted: return "\(category) · \(seconds)（已静音通过）"
        case .undone: return "\(category) · 本场播放不再自动跳过"
        }
    }

    /// 卡片右侧的动作说明。
    var actionHint: String? {
        isUndoable ? "回到这段开头，正常看完" : nil
    }

    /// 面向界面的图标。
    var symbolName: String {
        switch kind {
        case .skipped: "forward.end.fill"
        case .muted: "speaker.slash.fill"
        case .undone: "arrow.uturn.backward"
        }
    }
}

// MARK: - 设置

/// 空降助手的行为模式。
enum SponsorSkipMode: String, CaseIterable, Identifiable, Sendable {
    /// 自动跳过。
    case automatic
    /// 只在进度条上标出来，不动播放位置。
    case markOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "自动跳过"
        case .markOnly: "仅标记不跳"
        }
    }
}

/// 空降助手设置。
///
/// 直接读写 `UserDefaults`：这套设置既被设置页（`@AppStorage`）改，
/// 也被播放器（非视图层，每个节拍都要问一次）读，走 UserDefaults 是唯一
/// 两边都够轻的公共面。键名与设置页里的 `@AppStorage` 一一对应。
enum SponsorPreferences {
    static let enabledKey = "sponsorBlockEnabled"
    static let modeKey = "sponsorBlockMode"
    static let categoriesKey = "sponsorBlockCategories"
    static let muteSegmentsKey = "sponsorBlockMuteSegments"

    /// 总开关。默认开启——这是用户明确要求的功能，关掉只需设置里一个开关。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var mode: SponsorSkipMode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey) else { return .automatic }
        return SponsorSkipMode(rawValue: raw) ?? .automatic
    }

    /// 启用的分类。没写过就取各分类自己的默认值。
    ///
    /// 用逗号分隔的字符串存而不是数组：`@AppStorage` 不支持数组，
    /// 设置页要能直接用一个 `@AppStorage` 绑上去。
    static var enabledCategories: Set<SponsorCategory> {
        guard let raw = UserDefaults.standard.string(forKey: categoriesKey) else {
            return Set(SponsorCategory.allCases.filter(\.isEnabledByDefault))
        }
        return Set(raw.split(separator: ",").map(String.init).compactMap(SponsorCategory.init(rawValue:)))
    }

    /// 分类集合的存储形态。
    static func storageString(for categories: Set<SponsorCategory>) -> String {
        categories.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// 设置页 `@AppStorage` 的默认值。
    static var defaultCategoriesStorage: String {
        storageString(for: Set(SponsorCategory.allCases.filter(\.isEnabledByDefault)))
    }

    /// 是否对 `mute` 类片段静音通过。
    static var mutesSegments: Bool {
        UserDefaults.standard.object(forKey: muteSegmentsKey) as? Bool ?? true
    }

    /// 当前设置下，这段片段是否该参与处理。
    static func accepts(_ segment: SponsorSegment) -> Bool {
        guard isEnabled else { return false }
        guard enabledCategories.contains(segment.category) else { return false }
        guard segment.category.supportedActions.contains(segment.action) else { return false }
        // 整片标记永远不自动处理：跳它等于跳完整支视频
        if segment.coversWholeVideo { return false }
        if segment.action == .mute, !mutesSegments { return false }
        return segment.action == .skip || segment.action == .mute
    }

    /// 按当前设置过滤一批片段（同时按分P 过滤）。
    static func filter(_ segments: [SponsorSegment], cid: Int?) -> [SponsorSegment] {
        segments.filter { segment in
            guard accepts(segment) else { return false }
            // 分P 视频：片段自带 cid，只保留当前这一 P 的
            if let cid, let segmentCid = segment.cid, segmentCid != cid {
                return false
            }
            return true
        }
    }

}

extension Notification.Name {
    /// 空降设置变了：播放器据此重新按新设置筛一遍片段（服务端结果有缓存，不额外发请求）。
    static let sponsorPreferencesDidChange = Notification.Name("sponsorPreferencesDidChange")
}
