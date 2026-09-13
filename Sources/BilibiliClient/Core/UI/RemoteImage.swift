import AppKit
import SwiftUI

/// 远程图片视图。
///
/// 替代 SwiftUI 的 `AsyncImage`：`AsyncImage` 不保留解码结果，视图一重建
/// （列表滚动、页面刷新）就会重新发请求、重新解码。这里用进程内 `NSCache`
/// 缓存已解码的 `NSImage`，并对同一 URL 的并发请求去重，滚动时几乎零开销。
struct RemoteImage: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        content
            .task(id: url) {
                guard let url else {
                    image = nil
                    return
                }
                if let cached = RemoteImageLoader.shared.cached(url) {
                    image = cached
                    return
                }
                image = await RemoteImageLoader.shared.image(for: url)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.quaternary.opacity(0.55))
        }
    }
}

/// 图片装载器：解码后的图片进 `NSCache`（按像素字节计费，超限或内存吃紧时自动回收），
/// 在途请求按 URL 去重，避免同一张封面被并发拉取多次。
@MainActor
final class RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let session: URLSession
    private let memory: NSCache<NSURL, NSImage>
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        // CDN 带缓存头时直接复用本地响应，不再走网络
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                          diskCapacity: 128 * 1024 * 1024,
                                          directory: nil)
        configuration.httpAdditionalHeaders = [
            "User-Agent": APIConstants.userAgent,
            "Referer": APIConstants.referer,
        ]
        session = URLSession(configuration: configuration)

        let memory = NSCache<NSURL, NSImage>()
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024
        self.memory = memory
    }

    func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }

        let session = self.session
        let task = Task { () -> NSImage? in
            await Self.fetch(url, session: session)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        }
        return image
    }

    /// 下载与解码都在主线程之外完成（nonisolated 会切到协作线程池）
    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// 解码后的像素字节数，作为 NSCache 的计费成本
    private nonisolated static func cost(of image: NSImage) -> Int {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }
}
