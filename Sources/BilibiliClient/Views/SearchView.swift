import SwiftUI

struct SearchView: View {
    @State private var keyword = ""
    @State private var results: [SearchVideo] = []
    @State private var page = 0
    @State private var numResults = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var order: SearchOrder = .totalrank

    enum SearchOrder: String, CaseIterable, Identifiable {
        case totalrank = "综合排序"
        case click = "最多播放"
        case pubdate = "最新发布"
        case dm = "最多弹幕"
        case stow = "最多收藏"
        case scores = "最多评论"

        var id: String { rawValue }

        var apiValue: String {
            switch self {
            case .totalrank: return "totalrank"
            case .click: return "click"
            case .pubdate: return "pubdate"
            case .dm: return "dm"
            case .stow: return "stow"
            case .scores: return "scores"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultArea
        }
        .navigationTitle("搜索")
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索视频", text: $keyword)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await search(reset: true) }
                    }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        results = []
                        numResults = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Menu {
                ForEach(SearchOrder.allCases) { item in
                    Button {
                        guard order != item else { return }
                        order = item
                        Task { await search(reset: true) }
                    } label: {
                        if item == order {
                            Label(item.rawValue, systemImage: "checkmark")
                        } else {
                            Text(item.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(order.rawValue)
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("搜索") {
                Task { await search(reset: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var resultArea: some View {
        if isLoading && results.isEmpty {
            ProgressView("搜索中…")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let errorMessage, results.isEmpty {
            ContentUnavailableView {
                Label("搜索失败", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") {
                    Task { await search(reset: true) }
                }
            }
        } else if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("输入关键词开始搜索")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("找到 \(Formatters.count(numResults)) 个视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.bottom, 2)

                    LazyVStack(spacing: 12) {
                        ForEach(results) { video in
                            if let bvid = video.bvid, !bvid.isEmpty {
                                NavigationLink(value: bvid) {
                                    row(video)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if hasMore {
                            Button {
                                Task { await search(reset: false) }
                            } label: {
                                if isLoadingMore {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("加载更多")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
    }

    private func row(_ video: SearchVideo) -> some View {
        MediaListRow(
            coverURL: video.pic ?? "",
            title: video.cleanTitle,
            line2: "\(video.author ?? "未知UP主") · \(video.typename ?? "")",
            line3: "播放 \(Formatters.count(video.play ?? 0)) · 弹幕 \(Formatters.count(video.videoReview ?? 0)) · 收藏 \(Formatters.count(video.favorites ?? 0)) · \(Formatters.timeAgo(video.pubdate ?? 0))",
            durationText: video.duration
        )
    }

    private func search(reset: Bool) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if reset {
            guard !isLoading else { return }
            page = 0
            results = []
            numResults = 0
            hasMore = true
            errorMessage = nil
        } else {
            guard !isLoadingMore, hasMore else { return }
        }

        let targetPage = reset ? 1 : page + 1
        if reset {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        do {
            let data = try await SearchService().videos(keyword: trimmed, page: targetPage, order: order.apiValue)
            if reset {
                results = data.result
                page = 1
            } else {
                let seen = Set(results.map(\.id))
                results.append(contentsOf: data.result.filter { !seen.contains($0.id) })
                page = targetPage
            }
            numResults = data.numResults ?? results.count
            hasMore = results.count < (data.numResults ?? 0) && (data.numPages ?? 1) > targetPage
        } catch {
            if reset {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
        isLoadingMore = false
    }
}
