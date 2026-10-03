import SwiftUI

/// 视频详情页动作栏里的「下载」入口。
///
/// 自成一个视图：按钮 + 弹层（清晰度列表 + 常用可选项 + 下载进度）都在这里，
/// 详情页只需要把 `DownloadRequest` 传进来。
struct DownloadActionItem: View {
    let request: DownloadRequest

    @StateObject private var controller = DownloadController()

    var body: some View {
        Button {
            controller.loadQualitiesIfNeeded(for: request)
            controller.showPicker = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: iconName)
                Text(labelText)
                    .font(.caption2)
                    .monospacedDigit()
            }
            .foregroundStyle(iconColor)
        }
        .buttonStyle(.plain)
        .hoverScale(scale: 1.06)
        .help("下载这个视频")
        .popover(isPresented: $controller.showPicker, arrowEdge: .bottom) {
            card
                // iPhone 上 popover 会自适应成 sheet：清晰度/进度卡片被拉成整屏很别扭，
                // 显式要求紧凑宽度下仍按 popover 呈现。
                .presentationCompactAdaptation(.popover)
                .onDisappear { controller.dismiss() }
        }
    }

    // MARK: - 按钮外观

    /// 产物定位那一行的文案：macOS 是访达，iOS 是「文件」App。
    private var revealTitle: String {
        #if os(macOS)
        "在访达中显示"
        #else
        "在「文件」中查看"
        #endif
    }

    private var iconName: String {
        switch controller.phase {
        case .downloading, .loadingQualities: "arrow.down.circle"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .idle: "arrow.down.circle"
        }
    }

    private var labelText: String {
        switch controller.phase {
        case .downloading:
            controller.progress?.percentText ?? "下载中"
        case .loadingQualities:
            "获取中"
        case .finished:
            "已下载"
        case .failed:
            "重试"
        case .idle:
            "下载"
        }
    }

    private var iconColor: Color {
        switch controller.phase {
        case .finished: .green
        case .failed: .orange
        case .downloading, .loadingQualities: .accentColor
        case .idle: .primary
        }
    }

    // MARK: - 弹层

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider().padding(.horizontal, 10)

            switch controller.phase {
            case .loadingQualities:
                loadingSection
            case .downloading:
                progressSection
            case .finished:
                finishedSection
            case .failed(let message):
                failureSection(message)
            case .idle:
                idleSection
            }
        }
        .padding(6)
        .frame(width: 330)
    }

    private var title: String {
        switch controller.phase {
        case .downloading: "正在下载"
        default: "下载视频 · \(request.displayName)"
        }
    }

    // MARK: - 各阶段

    private var loadingSection: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在获取可下载清晰度…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.qualities.isEmpty {
                Text("当前账号没有可下载的清晰度。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
            } else {
                Text("选择清晰度")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                ForEach(controller.qualities) { quality in
                    DownloadQualityRow(quality: quality) {
                        controller.start(quality, for: request)
                    }
                }
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 6)

            optionsSection
        }
    }

    /// 常用可选项。引擎支持的选项远不止这几个，这里只放最常改的三项。
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DownloadOptionRow(title: "输出格式") {
                DownloadChip(title: "MP4", selected: controller.options.container == .mp4) {
                    controller.options.container = .mp4
                }
                DownloadChip(title: "原始流", selected: controller.options.container == .rawStreams) {
                    controller.options.container = .rawStreams
                }
            }

            DownloadOptionRow(title: "并发数") {
                ForEach([1, 4, 8, 16], id: \.self) { value in
                    DownloadChip(title: "\(value)", selected: controller.options.concurrency == value) {
                        controller.options.concurrency = value
                    }
                }
            }

            DownloadOptionRow(title: "限速") {
                DownloadChip(title: "不限", selected: controller.options.speedLimit == nil) {
                    controller.options.speedLimit = nil
                }
                ForEach([1, 5, 10], id: \.self) { megabytes in
                    let bytes = Int64(megabytes) << 20
                    DownloadChip(title: "\(megabytes)M", selected: controller.options.speedLimit == bytes) {
                        controller.options.speedLimit = bytes
                    }
                }
            }

            DownloadOptionRow(title: "编码") {
                ForEach(DownloadOptions.VideoCodecPreference.allCases, id: \.self) { codec in
                    DownloadChip(title: codec.displayName, selected: controller.options.videoCodec == codec) {
                        controller.options.videoCodec = codec
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let progress = controller.progress

            VStack(alignment: .leading, spacing: 4) {
                Text(progress?.detail ?? "准备中…")
                    .font(.callout)
                Text(progress?.fileName ?? request.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            DownloadProgressBar(fraction: progress?.fraction)

            HStack(spacing: 6) {
                Text(progress?.percentText ?? "—")
                    .monospacedDigit()
                if let progress, progress.bytesTotal > 0 {
                    Text("· \(DownloadFormat.size(progress.bytesReceived)) / \(DownloadFormat.size(progress.bytesTotal))")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(DownloadFormat.speed(progress?.bytesPerSecond ?? 0))
                Text("· 剩余 \(DownloadFormat.remaining(progress?.estimatedRemaining))")
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Button {
                controller.cancel()
            } label: {
                Text("取消下载")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private var finishedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载完成").font(.callout)
                    if let result = controller.result {
                        Text("\(result.qualityName) · \(DownloadFormat.size(result.byteCount))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if let result = controller.result {
                Text(result.fileURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
            }

            MenuActionRow(icon: "folder", title: revealTitle) {
                controller.revealResult()
            }
            MenuActionRow(icon: "arrow.down.circle", title: "再下载一次") {
                controller.reset()
                controller.loadQualitiesIfNeeded(for: request, force: true)
            }
        }
        .padding(.bottom, 6)
    }

    private func failureSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            MenuActionRow(icon: "arrow.clockwise", title: "重试") {
                controller.loadQualitiesIfNeeded(for: request, force: true)
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - 卡片内的基础控件

/// 一条清晰度：名称 + 规格，右侧码率信息。
private struct DownloadQualityRow: View {
    let quality: DownloadQuality
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quality.name).font(.callout)
                    if !quality.detail.isEmpty {
                        Text(quality.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 一行可选项：左侧标题，右侧若干胶囊。
private struct DownloadOptionRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                content
                Spacer(minLength: 0)
            }
        }
    }
}

/// 可选中的小胶囊。
private struct DownloadChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected
                              ? Color.accentColor.opacity(0.22)
                              : Color.primary.opacity(hovering ? 0.12 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 下载进度条。总量未知时退化为不确定态的滑动条。
private struct DownloadProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                if let fraction {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(2, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}
