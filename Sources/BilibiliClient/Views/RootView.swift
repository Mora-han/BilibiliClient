import SwiftUI

struct UpRoute: Hashable {
    let mid: Int
}

struct PartitionRoute: Hashable {
    let tid: Int
    let name: String
}

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var selection: SidebarItem? = .home
    @State private var showLogin = false
    @State private var searchText = ""
    @State private var submittedQuery = ""

    enum SidebarItem: String, CaseIterable, Identifiable {
        case home = "推荐"
        case zones = "分区"
        case popular = "热门"
        case search = "搜索"
        case dynamics = "动态"
        case profile = "我的"
        case favorites = "收藏"
        case history = "历史"
        case watchLater = "稍后再看"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .zones: return "square.grid.2x2"
            case .popular: return "flame.fill"
            case .search: return "magnifyingglass"
            case .dynamics: return "sparkles"
            case .profile: return "person.crop.circle.fill"
            case .favorites: return "bookmark.fill"
            case .history: return "clock.arrow.circlepath"
            case .watchLater: return "clock.badge.checkmark"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 270)
        } detail: {
            NavigationStack {
                Group {
                    switch selection {
                    case .home:
                        RecommendView()
                    case .zones:
                        ZonesView()
                    case .popular:
                        PopularView()
                    case .search:
                        SearchView(query: submittedQuery)
                    case .dynamics:
                        DynamicFeedView()
                    case .profile:
                        ProfileView()
                    case .favorites:
                        FavoritesView()
                    case .history:
                        HistoryView()
                    case .watchLater:
                        WatchLaterView()
                    case nil:
                        RecommendView()
                    }
                }
                .navigationDestination(for: String.self) { bvid in
                    VideoDetailView(bvid: bvid)
                }
                .navigationDestination(for: UpRoute.self) { route in
                    UpProfileView(mid: route.mid)
                }
                .navigationDestination(for: PartitionRoute.self) { route in
                    PartitionVideosView(zone: BiliZone(id: route.tid, name: route.name, icon: "play.rectangle"))
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("浏览") {
                ForEach([SidebarItem.home, .zones, .popular, .dynamics, .profile]) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
            Section("我的") {
                ForEach([SidebarItem.favorites, .history, .watchLater]) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassSearchField(text: $searchText) {
                submitSearch()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) { accountBar }
    }

    private var accountBar: some View {
        VStack(spacing: 0) {
            Divider()
            if session.loggedIn {
                if let user = session.user {
                    HStack(spacing: 10) {
                        avatar(url: user.face, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text("Lv.\(user.level)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("同步中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(10)
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("扫码登录", systemImage: "qrcode")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
        }
    }

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        submittedQuery = trimmed
        if !trimmed.isEmpty {
            selection = .search
        }
    }

    private func avatar(url: String, size: CGFloat) -> some View {
        RemoteImage(url: Formatters.https(url))
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}
