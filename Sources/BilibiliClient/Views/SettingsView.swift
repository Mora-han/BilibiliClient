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

/// 软件设置页：外观、弹幕、视频显示、缓存与关于。
/// 采用 macOS 系统设置风格：普通分组行、无卡片玻璃材质；
/// 选项使用系统原生弹出按钮（Picker .menu，即 NSPopUpButton），
/// 点击小方块即以其为中心展开列表，已选选项居中。
struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("danmakuSpeed") private var danmakuSpeed = DanmakuSpeed.normal.rawValue
    @AppStorage("videoDisplayMode") private var displayMode = VideoDisplayMode.card.rawValue
    @State private var cacheCleared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appearanceSection.padding(.vertical, 16)
                Divider()
                danmakuSection.padding(.vertical, 16)
                Divider()
                displaySection.padding(.vertical, 16)
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
    }

    // MARK: - 分组

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
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("视频显示")
            optionRow("视频显示") {
                Picker("视频显示", selection: $displayMode) {
                    ForEach(VideoDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("卡片：首页式网格；列表：单列紧凑；两列列表：双列紧凑，全局所有视频列表同步切换。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("存储")
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
            }
        }
    }

    // MARK: - 样式

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
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
