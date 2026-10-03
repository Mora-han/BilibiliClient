import Foundation

/// 一次下载所需的完整信息：选定好的视频轨、音频轨，以及界面上要展示的清晰度列表。
///
/// 由 `DownloadPlanner` 从一次 playurl 请求解析而来，是引擎内部唯一的「事实来源」。
struct DownloadPlan: Sendable {

    /// 原始请求。
    let request: DownloadRequest
    /// 视频总时长（秒）。
    let duration: Int?
    /// 服务器实际授予的清晰度 qn。
    let grantedQuality: Int?
    /// 选定的视频轨。
    let video: Stream
    /// 选定的音频轨（没有音频时为 nil）。
    let audio: Stream?
    /// 当前账号能下到的全部清晰度，按 qn 从高到低。
    let qualities: [DownloadQuality]

    /// 一条媒体轨。
    struct Stream: Sendable {
        /// 轨道 id：视频是 qn，音频是 audio id。
        let id: Int
        /// 主地址 + 备用地址，按优先级排列。
        let urls: [URL]
        /// 码率（bit/s）。
        let bandwidth: Int
        /// 编码串，如 "avc1.640028"。
        let codecs: String?
        /// MIME 类型。
        let mimeType: String?
        let width: Int?
        let height: Int?
        let frameRate: String?
    }
}

/// 把 playurl 的返回整理成 `DownloadPlan`。
///
/// 这里刻意只做「解析 + 选择」，不碰网络重试与落盘，
/// 这样选清晰度、选编码、选音轨的规则可以单独被理解和替换。
struct DownloadPlanner {

    /// B 站清晰度编号 → 中文名。仅在后端没给 `accept_description` 时兜底。
    private static let fallbackQualityNames: [Int: String] = [
        127: "8K 超高清",
        126: "杜比视界",
        125: "HDR 真彩",
        120: "4K 超清",
        116: "1080P60",
        112: "1080P 高码率",
        100: "智能修复",
        80: "1080P 高清",
        74: "720P60",
        64: "720P 高清",
        32: "480P 清晰",
        16: "360P 流畅",
        6: "240P 极速",
    ]

    /// 拉取并解析下载计划。
    func plan(for request: DownloadRequest, options: DownloadOptions) async throws -> DownloadPlan {
        let data: PlayURLData = try await APIClient.shared.get(
            "/x/player/wbi/playurl",
            query: [
                "bvid": request.bvid,
                "cid": "\(request.cid)",
                // 127 是 B 站的最大 qn，表示「能给我多高就给多高」
                "qn": "127",
                "fnval": "\(options.fnval)",
                "fourk": "1",
                "platform": "pc",
                "otype": "json",
            ],
            wbi: true
        )

        guard let dash = data.dash, let videos = dash.video, !videos.isEmpty else {
            throw DownloadError.noDashStream
        }

        let names = Self.qualityNames(from: data)
        let duration = Self.durationSeconds(from: data)
        let qualities = Self.qualityList(from: videos, duration: duration, names: names)

        let video = try Self.pickVideo(videos, options: options)
        let audio = Self.pickAudio(dash.audio ?? [], options: options)

        return DownloadPlan(
            request: request,
            duration: duration,
            grantedQuality: data.quality,
            video: Self.stream(from: video),
            audio: audio.map(Self.stream(from:)),
            qualities: qualities
        )
    }

    // MARK: - 清晰度列表

    /// 从 `accept_quality` / `accept_description` 建 qn → 名称的映射。
    private static func qualityNames(from data: PlayURLData) -> [Int: String] {
        var names: [Int: String] = [:]
        if let ids = data.acceptQuality, let descriptions = data.acceptDescription {
            for (id, name) in zip(ids, descriptions) where names[id] == nil {
                names[id] = name
            }
        }
        return names
    }

    private static func durationSeconds(from data: PlayURLData) -> Int? {
        if let dashDuration = data.dash?.duration, dashDuration > 0 { return dashDuration }
        if let timelength = data.timelength, timelength > 0 { return timelength / 1000 }
        return nil
    }

    /// 按 qn 归并视频轨，同 qn 取码率最高的一条；结果按 qn 降序。
    private static func qualityList(from videos: [PlayURLData.DashStream],
                                    duration: Int?,
                                    names: [Int: String]) -> [DownloadQuality] {
        var best: [Int: PlayURLData.DashStream] = [:]
        for stream in videos {
            if let existing = best[stream.id], existing.bandwidth >= stream.bandwidth { continue }
            best[stream.id] = stream
        }

        return best.values
            .sorted { $0.id > $1.id }
            .map { stream in
                let name = names[stream.id] ?? fallbackQualityNames[stream.id] ?? "qn \(stream.id)"
                var parts: [String] = []
                if let width = stream.width, let height = stream.height, width > 0, height > 0 {
                    parts.append("\(width)×\(height)")
                }
                if let frameRate = stream.frameRate, let fps = Double(frameRate), fps > 30 {
                    parts.append("\(Int(fps))fps")
                }
                if let codec = codecLabel(stream.codecs) { parts.append(codec) }
                if stream.bandwidth > 0 { parts.append(DownloadFormat.bitrate(stream.bandwidth)) }
                if let duration, duration > 0, stream.bandwidth > 0 {
                    parts.append("约 " + DownloadFormat.size(Int64(stream.bandwidth) * Int64(duration) / 8))
                }

                return DownloadQuality(
                    id: stream.id,
                    name: name,
                    detail: parts.joined(separator: " · "),
                    bandwidth: stream.bandwidth,
                    estimatedSize: duration.flatMap { total -> Int64? in
                        guard total > 0, stream.bandwidth > 0 else { return nil }
                        return Int64(stream.bandwidth) * Int64(total) / 8
                    },
                    codec: codecLabel(stream.codecs)
                )
            }
    }

    /// "avc1.640028" → "AVC"；认不出来就返回原串的前半段。
    private static func codecLabel(_ codecs: String?) -> String? {
        guard let codecs, !codecs.isEmpty else { return nil }
        if codecs.hasPrefix("avc1") { return "AVC" }
        if codecs.hasPrefix("hev1") || codecs.hasPrefix("hvc1") { return "HEVC" }
        if codecs.hasPrefix("av01") { return "AV1" }
        return codecs.split(separator: ".").first.map(String.init)
    }

    // MARK: - 选择视频轨

    /// 先按清晰度偏好定 qn，再在同 qn 内按编码偏好挑码率最高的一条。
    private static func pickVideo(_ videos: [PlayURLData.DashStream],
                                  options: DownloadOptions) throws -> PlayURLData.DashStream {
        let available = Set(videos.map(\.id))

        let targetQuality: Int
        switch options.quality {
        case .automatic:
            targetQuality = available.max() ?? 0
        case .exactly(let qn):
            if available.contains(qn) {
                targetQuality = qn
            } else if let lower = available.filter({ $0 < qn }).max() {
                targetQuality = lower
            } else {
                targetQuality = available.max() ?? 0
            }
        case .atMost(let qn):
            targetQuality = available.filter { $0 <= qn }.max() ?? available.min() ?? 0
        case .strictly(let qn):
            guard available.contains(qn) else { throw DownloadError.qualityUnavailable(requested: qn) }
            targetQuality = qn
        }

        let sameQuality = videos.filter { $0.id == targetQuality }
        guard !sameQuality.isEmpty else { throw DownloadError.noVideoStream }

        // 编码偏好：优先选指定编码，选不到就退回同清晰度的全部候选
        if let prefix = options.videoCodec.codecPrefix {
            let matched = sameQuality.filter { $0.codecs?.hasPrefix(prefix) ?? false }
            if let best = matched.max(by: { $0.bandwidth < $1.bandwidth }) {
                return best
            }
        }
        guard let best = sameQuality.max(by: { $0.bandwidth < $1.bandwidth }) else {
            throw DownloadError.noVideoStream
        }
        return best
    }

    // MARK: - 选择音频轨

    /// 默认只认 AAC：杜比全景声与 Hi-Res 无损合不进 MP4，
    /// 需要它们时必须显式打开 `allowsExoticAudio`。
    private static func pickAudio(_ audios: [PlayURLData.DashStream],
                                  options: DownloadOptions) -> PlayURLData.DashStream? {
        guard !audios.isEmpty else { return nil }

        var candidates = audios
        if !options.allowsExoticAudio {
            let aac = audios.filter { $0.codecs?.hasPrefix("mp4a") ?? false }
            if !aac.isEmpty { candidates = aac }
        }

        switch options.audioPreference {
        case .highestBandwidth:
            return candidates.max(by: { $0.bandwidth < $1.bandwidth })
        case .lowestBandwidth:
            return candidates.min(by: { $0.bandwidth < $1.bandwidth })
        case .exactly(let id):
            return candidates.first { $0.id == id }
                ?? candidates.max(by: { $0.bandwidth < $1.bandwidth })
        }
    }

    // MARK: - 转换

    private static func stream(from raw: PlayURLData.DashStream) -> DownloadPlan.Stream {
        var urls: [URL] = []
        // B 站 CDN 有时返回 http，统一升级到 https 以免被 ATS 拦掉
        let primary = raw.baseUrl.replacingOccurrences(of: "http://", with: "https://")
        if let url = URL(string: primary) { urls.append(url) }
        for backup in raw.backupUrl ?? [] {
            let upgraded = backup.replacingOccurrences(of: "http://", with: "https://")
            if let url = URL(string: upgraded), !urls.contains(url) { urls.append(url) }
        }
        return DownloadPlan.Stream(
            id: raw.id,
            urls: urls,
            bandwidth: raw.bandwidth,
            codecs: raw.codecs,
            mimeType: raw.mimeType,
            width: raw.width,
            height: raw.height,
            frameRate: raw.frameRate
        )
    }
}
