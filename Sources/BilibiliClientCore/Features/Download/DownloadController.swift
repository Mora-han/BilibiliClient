import Foundation
import SwiftUI

/// 下载界面状态机。把引擎的进度流翻译成视图能直接渲染的状态。
///
/// 每个视频详情页持有一个实例：它只关心「当前这一条下载」，
/// 不做下载队列（队列属于下载管理，不在这一版的范围内）。
@MainActor
final class DownloadController: ObservableObject {

    /// 界面所处的阶段。
    enum Phase: Equatable {
        /// 什么也没发生，展示清晰度列表。
        case idle
        /// 正在拉取可下载清晰度。
        case loadingQualities
        /// 正在下载。
        case downloading
        /// 下载完成。
        case finished
        /// 失败或取消。
        case failed(String)

        var isBusy: Bool {
            self == .loadingQualities || self == .downloading
        }
    }

    @Published private(set) var qualities: [DownloadQuality] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: DownloadProgress?
    @Published private(set) var result: DownloadResult?
    /// 控制弹层显示。
    @Published var showPicker = false
    /// 界面上的可选项。引擎支持更多项，这里只暴露最常用的几个。
    @Published var options = DownloadOptions()

    private var qualitiesTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    /// 记下已经加载过清晰度的分P，切分P 时才需要重新拉。
    private var loadedKey: String?

    deinit {
        qualitiesTask?.cancel()
        downloadTask?.cancel()
    }

    // MARK: - 清晰度

    /// 按需加载清晰度列表（同一个分P 只拉一次）。
    func loadQualitiesIfNeeded(for request: DownloadRequest, force: Bool = false) {
        let key = "\(request.bvid)-\(request.cid)"
        guard force || loadedKey != key else { return }
        loadedKey = key

        qualitiesTask?.cancel()
        qualities = []
        phase = .loadingQualities

        qualitiesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await BiliDownloadEngine.shared.qualities(for: request, options: options)
                guard !Task.isCancelled else { return }
                self.qualities = list
                self.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 下载

    func start(_ quality: DownloadQuality, for request: DownloadRequest) {
        guard !phase.isBusy else { return }

        showPicker = false
        result = nil
        progress = nil
        phase = .downloading

        let options = self.options
        downloadTask = Task { [weak self] in
            // 取一次强引用：DownloadController 是 @MainActor 类（因此是 Sendable），
            // 在下面的 @Sendable 进度闭包里直接用 self 才不会踩到可变捕获。
            guard let self else { return }
            do {
                let outcome = try await BiliDownloadEngine.shared.download(
                    request,
                    qualityID: quality.id,
                    options: options
                ) { update in
                    // 引擎在后台线程回调，状态必须回主线程改
                    Task { @MainActor in
                        self.progress = update
                    }
                }
                guard !Task.isCancelled else { return }
                self.result = outcome
                self.phase = .finished
            } catch is CancellationError {
                self.phase = .idle
                self.progress = nil
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.progress = nil
            }
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        progress = nil
        phase = .idle
    }

    /// 关掉弹层时顺带把失败提示清掉，下次打开是干净状态。
    func dismiss() {
        showPicker = false
        if case .failed = phase { phase = .idle }
    }

    func reset() {
        cancel()
        qualitiesTask?.cancel()
        loadedKey = nil
        qualities = []
        result = nil
        phase = .idle
    }

    // MARK: - 产物

    /// 在访达（macOS）/ 「文件」App（iOS）中定位产物。
    func revealResult() {
        guard let result else { return }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
        #else
        // iOS 上把 `file://` 交给 `UIApplication.open` 是静默失败的 —— 用户点了没反应。
        // 产物在 App 的 Documents 里（Info.plist 已开 `UIFileSharingEnabled`，所以
        // 「文件」App 的「我的 iPhone」下能看到），这里直接跳到「文件」App。
        let folder = result.fileURL.deletingLastPathComponent()
        if let filesURL = URL(string: "shareddocuments://\(folder.path)"),
           UIApplication.shared.canOpenURL(filesURL) {
            UIApplication.shared.open(filesURL)
        } else if let fallback = URL(string: "shareddocuments://") {
            UIApplication.shared.open(fallback)
        }
        #endif
    }

    /// 产物所在目录，用于「打开下载目录」。
    var resultDirectory: URL? {
        result?.fileURL.deletingLastPathComponent()
    }
}
