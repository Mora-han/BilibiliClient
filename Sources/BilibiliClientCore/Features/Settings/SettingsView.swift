import SwiftUI

/// 外观模式（跟随系统 / 浅色 / 深色）
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 关闭主窗口时的行为（完全退出 / 菜单栏模式 / 每次询问）
public enum CloseBehavior: String, CaseIterable, Identifiable {
    case quit
    case menuBar
    case ask

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quit: return "完全退出"
        case .menuBar: return "菜单栏模式"
        case .ask: return "每次询问"
        }
    }

    public static var current: CloseBehavior {
        CloseBehavior(rawValue: UserDefaults.standard.string(forKey: "closeBehavior") ?? "") ?? .ask
    }
}

/// 卡片样式（设置项）：液态玻璃 / 实色卡片，全局统一生效。
enum CardStyle: String, CaseIterable, Identifiable {
    case glass
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "液态玻璃"
        case .solid: return "实色卡片"
        }
    }
}

/// 动态页 UP 切换栏位置（设置项）：上侧 / 左侧。
enum UpBarPosition: String, CaseIterable, Identifiable {
    case top
    case left

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: return "上侧"
        case .left: return "左侧"
        }
    }
}

/// 软件设置页：外观、窗口、弹幕、视频显示、缓存与关于。
/// 采用 macOS 系统设置风格：普通分组行、无卡片玻璃材质；
/// 选项使用系统原生弹出按钮（Picker .menu，即 NSPopUpButton），
/// 点击小方块即以其为中心展开列表，已选选项居中。
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("danmakuSpeed") private var danmakuSpeed = DanmakuSpeed.normal.rawValue
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card.rawValue
    @AppStorage("cardStyle") private var cardStyle = CardStyle.solid.rawValue
    @AppStorage("upBarPosition") private var upBarPosition = UpBarPosition.top.rawValue
    @AppStorage("closeBehavior") private var closeBehavior = CloseBehavior.ask.rawValue
    @AppStorage("favoriteBehavior") private var favoriteBehavior = FavoriteBehavior.defaultFolder.rawValue
    // 空降助手（键名与 SponsorPreferences 共用，播放器侧直接读 UserDefaults）
    @AppStorage(SponsorPreferences.enabledKey) private var sponsorEnabled = true
    @AppStorage(SponsorPreferences.modeKey) private var sponsorMode = SponsorSkipMode.automatic.rawValue
    @AppStorage(SponsorPreferences.categoriesKey) private var sponsorCategories = SponsorPreferences.defaultCategoriesStorage
    @AppStorage(SponsorPreferences.muteSegmentsKey) private var sponsorMutesSegments = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var cacheCleared = false
    @State private var showLogin = false

    /// 紧凑宽度（iPhone 竖屏）下能真正生效的显示模式：双列列表会被运行时降级成单列，
    /// 动态页的左侧 UP 栏在紧凑宽度下也会退回上侧。把无效选项藏起来，避免设置了看不到效果。
    private var isCompactWidth: Bool { horizontalSizeClass == .compact }

    private var availableDisplayModes: [VideoDisplayMode] {
        isCompactWidth ? VideoDisplayMode.allCases.filter { $0 != .list2 } : VideoDisplayMode.allCases
    }

    private var availableUpBarPositions: [UpBarPosition] {
        isCompactWidth ? UpBarPosition.allCases.filter { $0 != .left } : UpBarPosition.allCases
    }

    private var displayModeHint: String {
        isCompactWidth
            ? "卡片：首页式网格；列表：单列紧凑。双列列表在 iPhone 竖屏放不下内容，已隐藏。"
            : "卡片：首页式网格；列表：单列紧凑；两列列表：双列紧凑，全局所有视频列表同步切换。"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                accountSection.padding(.vertical, 16)
                Divider()
                appearanceSection.padding(.vertical, 16)
                Divider()
                // 「关闭窗口后行为」只对有窗口/菜单栏概念的平台有意义（macOS）
                if AppPlatform.hasWindowManagement {
                    windowSection.padding(.vertical, 16)
                    Divider()
                }
                danmakuSection.padding(.vertical, 16)
                Divider()
                sponsorSection.padding(.vertical, 16)
                Divider()
                displaySection.padding(.vertical, 16)
                Divider()
                favoriteSection.padding(.vertical, 16)
                Divider()
                dynamicSection.padding(.vertical, 16)
                Divider()
                storageSection.padding(.vertical, 16)
                Divider()
                aboutSection.padding(.vertical, 16)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showLogin) { LoginView() }
    }

    // MARK: - 分组

    /// 账户：登录 / 退出登录入口。
    ///
    /// 侧边栏底部那张账户卡片靠 `tabViewSidebarFooter` 呈现，而苹果明确说明它
    /// 「只在 TabView 显示为侧边栏时可见」——iPhone 永远是标签栏形态，那块内容
    /// 整块不会出现。于是 iPhone 上既看不到当前账号，也没有任何地方能退出登录
    /// （`AccountPanelView` 的唯一入口就在那张卡片上）。这里补一个端点两边都有的入口。
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("账户")
            if session.loggedIn {
                HStack(spacing: 12) {
                    if let user = session.user {
                        RemoteImage(url: Formatters.https(user.face), variant: .avatar)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text("Lv.\(user.level) · 关注 \(Formatters.count(user.following)) · 粉丝 \(Formatters.count(user.follower))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        ProgressView()
                            .frame(width: 44, height: 44)
                        Text("同步中…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                Button(role: .destructive) {
                    session.logout()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    showLogin = true
                } label: {
                    Label("扫码登录", systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent)
                Text("登录后可同步收藏夹、观看历史与稍后再看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("收藏")
            optionRow("收藏位置") {
                Picker("收藏位置", selection: $favoriteBehavior) {
                    ForEach(FavoriteBehavior.allCases) { item in Text(item.label).tag(item.rawValue) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("外观")
            optionRow("外观") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("窗口")
            optionRow("关闭窗口时") {
                Picker("关闭窗口时", selection: $closeBehavior) {
                    ForEach(CloseBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("选择“菜单栏模式”后，关闭窗口会隐藏到顶部菜单栏继续运行；“每次询问”会在关闭时弹出选择。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var danmakuSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("弹幕")
            Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                .font(.body)
            Divider()
            optionRow("弹幕速度") {
                Picker("弹幕速度", selection: $danmakuSpeed) {
                    ForEach(DanmakuSpeed.allCases) { speed in
                        Text(speed.label).tag(speed.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("不透明度、字号、显示区域、显示类型等更多设置，在播放页视频下方的「弹幕设置」里调整。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("视频显示")
            optionRow("视频显示") {
                Picker("视频显示", selection: $displayMode) {
                    ForEach(availableDisplayModes) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            optionRow("卡片样式") {
                Picker("卡片样式", selection: $cardStyle) {
                    ForEach(CardStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text(displayModeHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dynamicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("动态")
            optionRow("UP 栏位置") {
                Picker("UP 栏位置", selection: $upBarPosition) {
                    ForEach(availableUpBarPositions) { position in
                        Text(position.label).tag(position.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text(isCompactWidth
                 ? "选择“左侧”后 UP 筛选栏固定在动态列表左侧竖排展示；iPhone 竖屏放不下，已隐藏。"
                 : "选择“左侧”后，UP 筛选栏固定在动态列表左侧竖排展示。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("存储")
            Button {
                URLCache.shared.removeAllCachedResponses()
                BiliImages.clearCaches()
                cacheCleared = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    cacheCleared = false
                }
            } label: {
                HStack {
                    Text("清除图片缓存")
                    Spacer()
                    Text(cacheCleared ? "已清除" : "")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(cacheCleared ? Color.green : Color.primary)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("关于")
            VStack(alignment: .leading, spacing: 4) {
                Text("Bilibili Client \(BuildInfo.version)（构建 \(BuildInfo.build)）")
                    .font(.callout)
                Text("原生 SwiftUI · Liquid Glass · 数据接口来自社区整理的 bilibili-API-collect，仅用于个人学习研究。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: URL(string: "https://github.com/Mora-han/BilibiliClient")!) {
                    Label("GitHub 项目主页", systemImage: "link")
                }
                .font(.caption)
            }
            Divider()
            updateRows
        }
    }

    /// 自动更新（macOS 走 Sparkle）：开关 + 手动检查。
    ///
    /// 只有注入了 `AppUpdater` 的平台才显示；iOS 不提供应用内更新入口，整块隐藏。
    @ViewBuilder
    private var updateRows: some View {
        if let updater = AppUpdaterStore.shared {
            Toggle("自动检查更新", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            .font(.body)

            Toggle("自动下载并安装", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .font(.body)
            .disabled(!updater.automaticallyChecksForUpdates)

            optionRow("版本更新") {
                Button("检查更新…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            if let last = updater.lastUpdateCheckDate {
                Text("上次检查：\(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 样式

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }

    // MARK: - 空降助手

    private var sponsorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("空降助手")
            Toggle("自动跳过赞助片段", isOn: $sponsorEnabled)
                .font(.body)

            if sponsorEnabled {
                Divider()

                optionRow("处理方式") {
                    Picker("处理方式", selection: $sponsorMode) {
                        ForEach(SponsorSkipMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle("静音类片段静音通过", isOn: $sponsorMutesSegments)
                    .font(.body)

                Divider()

                Text("跳过哪些分类")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(SponsorCategory.allCases) { category in
                    Toggle(category.displayName, isOn: categoryBinding(category))
                        .font(.body)
                }

                Text("片段由网友标注，通过第三方公开服务（SponsorBlock 兼容接口）获取。请求只上传视频 ID 的哈希前缀，服务端无法得知你在看哪个视频。该服务由社区个人维护，不可用时播放不受影响；进度条上的色块表示该处有可跳过片段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: sponsorEnabled) { _, _ in notifySponsorSettingsChanged() }
        .onChange(of: sponsorMode) { _, _ in notifySponsorSettingsChanged() }
        .onChange(of: sponsorMutesSegments) { _, _ in notifySponsorSettingsChanged() }
        .onChange(of: sponsorCategories) { _, _ in notifySponsorSettingsChanged() }
    }

    /// 单个分类的开关。分类集合以逗号分隔字符串存，这里做一层读写映射。
    private func categoryBinding(_ category: SponsorCategory) -> Binding<Bool> {
        Binding(
            get: { SponsorPreferences.enabledCategories.contains(category) },
            set: { isOn in
                var enabled = SponsorPreferences.enabledCategories
                if isOn {
                    enabled.insert(category)
                } else {
                    enabled.remove(category)
                }
                sponsorCategories = SponsorPreferences.storageString(for: enabled)
            }
        )
    }

    /// 通知正在播放的页面按新设置重新筛片段。
    private func notifySponsorSettingsChanged() {
        NotificationCenter.default.post(name: .sponsorPreferencesDidChange, object: nil)
    }

    private func optionRow<Content: View>(_ title: String,
                                          @ViewBuilder control: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            control()
        }
        .padding(.vertical, 5)
    }
}
