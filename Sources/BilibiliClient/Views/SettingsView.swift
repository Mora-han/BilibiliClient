import SwiftUI

/// 设置项通用协议：可枚举、可展示当前值、点击弹出菜单切换。
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
/// 选项采用 Apple 风格：单行只展示当前选中值，点击弹出小列表切换。
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
            menuRow(AppearanceMode.self, "外观", selection: $appearance)
        }
    }

    private var danmakuSection: some View {
        settingsCard("弹幕") {
            Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                .font(.callout)
            Divider()
            menuRow(DanmakuSpeed.self, "弹幕速度", selection: $danmakuSpeed)
        }
    }

    private var displaySection: some View {
        settingsCard("视频显示") {
            menuRow(VideoDisplayMode.self, "视频显示", selection: $displayMode)
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

    /// Apple 风格选项行：左侧标题，右侧当前值 + 展开箭头，点击弹出选项列表。
    private func menuRow<O: SettingOption>(_ type: O.Type,
                                           _ title: String,
                                           selection: Binding<String>) -> some View {
        let options = Array(O.allCases)
        let current = options.first { $0.rawValue == selection.wrappedValue }
        return HStack {
            Text(title)
                .font(.callout)
            Spacer()
            Menu {
                ForEach(options) { option in
                    Button {
                        selection.wrappedValue = option.rawValue
                    } label: {
                        if option.rawValue == selection.wrappedValue {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
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
            .menuStyle(.borderlessButton)
            .fixedSize()
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
