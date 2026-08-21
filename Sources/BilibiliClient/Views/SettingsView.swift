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

/// 软件设置页：外观、弹幕、视频显示模式、缓存与关于。
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
            Picker("外观", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var danmakuSection: some View {
        settingsCard("弹幕") {
            Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                .font(.callout)
            Picker("弹幕速度", selection: $danmakuSpeed) {
                ForEach(DanmakuSpeed.allCases) { speed in
                    Text(speed.label).tag(speed.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var displaySection: some View {
        settingsCard("视频显示") {
            Picker("视频显示模式", selection: $displayMode) {
                ForEach(VideoDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("卡片模式更贴近首页观感；列表模式信息更紧凑，全局所有视频列表同步切换。")
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
                Label(cacheCleared ? "已清除" : "清除图片缓存", systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(cacheCleared ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
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
