import SwiftUI

/// 设置项通用协议：可枚举、可展示当前值、点击弹出列表切换。
protocol SettingOption: CaseIterable, Identifiable, RawRepresentable where RawValue == String {
    var label: String { get }
}

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

extension AppearanceMode: SettingOption {}
extension DanmakuSpeed: SettingOption {}
extension VideoDisplayMode: SettingOption {}

/// 软件设置页：外观、弹幕、视频显示、缓存与关于。
struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("danmakuSpeed") private var danmakuSpeed = DanmakuSpeed.normal.rawValue
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card.rawValue
    @State private var cacheCleared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                appearanceSection
                danmakuSection
                displaySection
                storageSection
                aboutSection
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .navigationTitle("设置")
    }

    private var appearanceSection: some View {
        settingsCard("外观") {
            SettingMenuRow<AppearanceMode>(title: "外观", selection: $appearance)
        }
    }

    private var danmakuSection: some View {
        settingsCard("弹幕") {
            Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                .font(.callout)
            Divider()
            SettingMenuRow<DanmakuSpeed>(title: "弹幕速度", selection: $danmakuSpeed)
        }
    }

    private var displaySection: some View {
        settingsCard("视频显示") {
            SettingMenuRow<VideoDisplayMode>(title: "视频显示", selection: $displayMode)
            Text("卡片：首页式网格；列表：单列紧凑；两列列表：双列紧凑，全局所有视频列表同步切换。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        settingsCard("存储") {
            Button {
                URLCache.shared.removeAllCachedResponses()
                cacheCleared = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    cacheCleared = false
                }
            } label: {
                HStack {
                    Text("清除图片缓存")
                        .font(.callout)
                    Spacer()
                    Text(cacheCleared ? "已清除" : "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(cacheCleared ? Color.green : Color.primary)
        }
    }

    private var aboutSection: some View {
        settingsCard("关于") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bilibili Client \(BuildInfo.version)（构建 \(BuildInfo.build)）")
                    .font(.callout)
                Text("原生 SwiftUI · Liquid Glass · 数据接口来自社区整理的 bilibili-API-collect，仅用于个人学习研究。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 14)
    }
}

/// Apple Music 风格选项行：点击后弹出选项列表，已选选项位于列表正中。
private struct SettingMenuRow<O: SettingOption>: View {
    let title: String
    @Binding var selection: String
    @State private var isOpen = false

    private var options: [O] { Array(O.allCases) }
    private var current: O? { options.first { $0.rawValue == selection } }

    private let rowHeight: CGFloat = 36

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                HStack(spacing: 5) {
                    Text(current?.label ?? "")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            optionList
        }
    }

    /// 弹出列表：三行可见、上下留白，使已选选项始终位于列表正中。
    private var optionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: rowHeight * 1.25)
                    ForEach(options) { option in
                        Button {
                            selection = option.rawValue
                            isOpen = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(option.label)
                                    .font(.callout)
                                Spacer()
                                if option.rawValue == selection {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            .background(
                                option.rawValue == selection
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(option.rawValue)
                    }
                    Color.clear.frame(height: rowHeight * 1.25)
                }
            }
            .frame(width: 230, height: rowHeight * 3 + 10)
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
        .padding(6)
    }
}
