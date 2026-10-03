import Foundation

/// 下载引擎的全部可调项。
///
/// 「下载」区块不内置任何写死的策略：并发度、分块大小、重试与退避、限速、
/// 编码偏好、输出容器、文件命名、合流方式……全部由这里的字段表达。
/// 调用方只覆盖自己关心的字段，其余走默认值。
///
/// 默认值是「保守但够快」的一组：AVC 优先（兼容性最好、能走无重编码合流）、
/// 8 路并发、4 MB 分块、4 次退避重试、不限速、合流成 MP4。
struct DownloadOptions: Sendable {

    // MARK: - 清晰度与编码

    /// 想要哪一档清晰度。
    var quality: QualityPreference = .automatic

    /// 视频编码偏好。默认 AVC：兼容性最好，也最容易走通无重编码的 passthrough 合流。
    var videoCodec: VideoCodecPreference = .avc

    /// 音频偏好。
    var audioPreference: AudioPreference = .highestBandwidth

    /// 是否允许选中 AVFoundation 封不进 MP4 的音频编码（杜比全景声、Hi-Res 无损）。
    /// 打开后请配合 `container == .rawStreams`，否则合流阶段大概率失败。
    var allowsExoticAudio = false

    // MARK: - 输出

    /// 输出目录。nil = 平台默认下载目录（macOS 是 ~/Downloads，iOS 是沙盒 Documents）。
    var outputDirectory: URL?

    /// 文件名模板，可用占位符：{title} {bvid} {cid} {page} {quality} {codec} {date}。
    var fileNameTemplate = DownloadOptions.defaultFileNameTemplate

    /// 输出形态：合流成单个 MP4，还是保留原始 m4s 流。
    var container: Container = .mp4

    /// 目标文件已存在时是否直接覆盖。false = 自动改成 "标题 (2).mp4"。
    var overwriteExisting = false

    /// 合流成功后是否删掉中间的 .m4s 源文件。
    var deleteIntermediateFiles = true

    // MARK: - 传输

    /// 每条流的并发连接数。
    var concurrency = 8

    /// 每个分块的字节数。越大越省请求，越小越利于断点与重试。
    var chunkSize: Int64 = 4 << 20

    /// 单个分块最多重试几次（含备用 CDN 切换）。
    var maxRetries = 4

    /// 重试退避基数（秒）：实际等待 = 基数 × 2^(已重试次数)。
    var retryBackoff: TimeInterval = 1.5

    /// 单次请求的空闲超时（秒）。
    var requestTimeout: TimeInterval = 30

    /// 全局限速（字节/秒）。nil = 不限速。
    var speedLimit: Int64?

    // MARK: - 合流

    /// 是否把音频轨合进最终文件。false = 只下视频轨。
    var muxAudio = true

    /// 合流优先用 passthrough（不重编码，无损且几乎瞬时）。
    /// 失败时自动回退到最高质量重编码。
    var preferPassthrough = true

    // MARK: - 接口

    /// playurl 的 fnval 位掩码。
    /// 默认 4048 = DASH(16) | HDR(64) | 4K(128) | 杜比音频(256) | 杜比视界(512) | 8K(1024) | AV1(2048)。
    var fnval = 4048

    // MARK: - 嵌套选项

    /// 清晰度偏好。
    enum QualityPreference: Sendable, Equatable {
        /// 服务器实际给出的最高档。
        case automatic
        /// 指定 qn，拿不到时向下取最接近的一档。
        case exactly(Int)
        /// 不高于指定 qn 的最高档。
        case atMost(Int)
        /// 只要指定 qn，拿不到就报错。
        case strictly(Int)
    }

    /// 视频编码偏好。
    enum VideoCodecPreference: Sendable, Equatable, CaseIterable {
        /// H.264，兼容性最好，优先选它。
        case avc
        /// H.265 / HEVC，同画质体积更小。
        case hevc
        /// AV1，最新但系统支持最差。
        case av1
        /// 不挑，码率最高者胜。
        case any

        var displayName: String {
            switch self {
            case .avc: "AVC / H.264"
            case .hevc: "HEVC / H.265"
            case .av1: "AV1"
            case .any: "自动"
            }
        }

        /// 该编码在 `codecs` 字段里的前缀。
        var codecPrefix: String? {
            switch self {
            case .avc: "avc1"
            case .hevc: "hev1"
            case .av1: "av01"
            case .any: nil
            }
        }
    }

    /// 音频偏好。
    enum AudioPreference: Sendable, Equatable {
        /// 码率最高的一轨。
        case highestBandwidth
        /// 体积最小的一轨。
        case lowestBandwidth
        /// 指定 audio id（如 30216 / 30232 / 30280）。
        case exactly(Int)
    }

    /// 输出容器。
    enum Container: Sendable, Equatable {
        /// 视频轨 + 音频轨合流成单个 MP4。
        case mp4
        /// 原始流：分别落成 .m4s 文件，不合成。
        case rawStreams
    }

    // MARK: - 默认值

    static let defaultFileNameTemplate = "{title}"

    /// 平台默认下载目录。
    static var defaultOutputDirectory: URL {
        let fileManager = FileManager.default
        #if os(macOS)
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            return downloads
        }
        #else
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents
        }
        #endif
        return fileManager.temporaryDirectory
    }

    /// 把各选项夹到合法区间，避免调用方传入 0 并发、负数分块之类的值把引擎拖死。
    func normalized() -> DownloadOptions {
        var copy = self
        copy.concurrency = min(max(concurrency, 1), 16)
        copy.chunkSize = min(max(chunkSize, 256 << 10), 64 << 20)
        copy.maxRetries = min(max(maxRetries, 0), 10)
        copy.retryBackoff = min(max(retryBackoff, 0.2), 30)
        copy.requestTimeout = min(max(requestTimeout, 5), 300)
        if let limit = copy.speedLimit, limit <= 0 { copy.speedLimit = nil }
        if copy.fileNameTemplate.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.fileNameTemplate = DownloadOptions.defaultFileNameTemplate
        }
        return copy
    }

    /// 实际生效的输出目录（把 nil 解析成平台默认目录，并确保目录存在）。
    func resolvedOutputDirectory() -> URL {
        let directory = outputDirectory ?? DownloadOptions.defaultOutputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
