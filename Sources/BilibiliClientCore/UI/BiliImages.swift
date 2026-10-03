import Foundation
import Nuke

/// 全 App 共用的图片管线（Nuke）。
///
/// 相比之前自研的 `RemoteImageLoader`，这里补上了三件关键的事：
/// 1. **解码在后台线程完成**。之前 `NSImage(data:)` 是懒解码，真正解码发生在
///    SwiftUI 渲染那一帧的主线程（实测封面 11ms/张、峰值 60ms，一帧两张就掉帧）；
///    管线里打开 decompression 后主线程只拿到现成位图。
/// 2. **两级缓存按图片场景配置**：内存按成本计费 + 磁盘缓存（可缓存处理后的变体），
///    滚动回去不再重新下载/解码。
/// 3. **预取**：列表加载后把这一页的图先拉好，滚动到时直接命中。
public enum BiliImages {
    /// 统一管线：NukeUI 的 `LazyImage` 默认走 `ImagePipeline.shared`，启动时把它换掉
    static let pipeline: ImagePipeline = {
        var configuration = ImagePipeline.Configuration()
        configuration.dataLoader = DataLoader(configuration: sessionConfiguration)
        configuration.dataCache = try? DataCache(name: "com.codex.bilibili-client.images")
        configuration.imageCache = ImageCache(costLimit: 128 * 1024 * 1024, countLimit: 400)
        // macOS 上 Nuke 默认不解压（系统偏懒解码）：打开后解码在管线线程完成
        configuration.isDecompressionEnabled = true
        return ImagePipeline(configuration: configuration)
    }()

    /// 图床需要 UA / Referer，否则会 403
    private static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": APIConstants.userAgent,
            "Referer": APIConstants.referer,
        ]
        // 图床带缓存头时直接复用本地响应
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        return configuration
    }

    /// App 启动时调用一次
    public static func install() {
        ImagePipeline.shared = pipeline
    }

    // MARK: - 预取

    private static let prefetcher = ImagePrefetcher(pipeline: pipeline)

    /// 提前把一页图片拉好（低优先级，和可见后的正式请求会合并）
    static func prefetch(_ urls: [URL?]) {
        let list = urls.compactMap { $0 }
        guard !list.isEmpty else { return }
        // 适度预加载：一次只暖首屏这一小段（约 4 行卡片）的图，
        // 其余随滚动实时加载。之前整页 50 张一起预取，既吃带宽也占内存。
        prefetcher.startPrefetching(with: Array(list.prefix(12)))
    }

    /// 列表加载完一页后调用：传原始地址（接口里的可选字符串）+ 用途即可
    static func prefetch(_ rawURLs: [String?], variant: Formatters.ImageVariant) {
        prefetch(rawURLs.compactMap { $0 }.map { Formatters.sized(Formatters.https($0), variant) })
    }

    /// 动态流：作者头像 + 配图（配图宽高比不定，只约束宽度）
    static func prefetchDynamic(_ items: [DynamicItem]) {
        var urls: [URL?] = []
        for item in items {
            urls.append(Formatters.sized(Formatters.https(item.modules.moduleAuthor?.face ?? ""), .avatar))
            if let draw = item.modules.moduleDynamic?.major?.draw {
                urls.append(contentsOf: draw.imageURLs.map { Formatters.sized($0, .keepAspect) })
            }
            if let opus = item.modules.moduleDynamic?.major?.opus {
                urls.append(contentsOf: opus.picsURLs.map { Formatters.sized($0, .keepAspect) })
            }
            if let origin = item.orig {
                if let draw = origin.modules?.moduleDynamic?.major?.draw {
                    urls.append(contentsOf: draw.imageURLs.map { Formatters.sized($0, .keepAspect) })
                }
                if let opus = origin.modules?.moduleDynamic?.major?.opus {
                    urls.append(contentsOf: opus.picsURLs.map { Formatters.sized($0, .keepAspect) })
                }
            }
        }
        prefetch(urls)
    }

    // MARK: - 缓存

    /// 清空图片内存 + 磁盘缓存（设置页"清空缓存"用）
    static func clearCaches() {
        pipeline.cache.removeAll()
        pipeline.configuration.dataCache?.removeAll()
    }
}
