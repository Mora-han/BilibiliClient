import SwiftUI

/// 外观模式（设置项，跟随系统 / 浅色 / 深色）
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

/// 侧边栏底部账户区的弹出面板：账户信息 / 软件设置 / 关于 / 退出登录。
struct AccountPanelView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showLogin: Bool

    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("danmakuSpeed") private var danmakuSpeed = DanmakuSpeed.normal.rawValue
    @State private var cacheCleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.loggedIn {
                userSection
            } else {
                loginSection
            }

            Divider()
            settingsSection
            Divider()
            aboutSection

            if session.loggedIn {
                Divider()
                logoutButton
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    // MARK: - 账户

    private var userSection: some View {
        VStack(spacing: 12) {
            if let user = session.user {
                RemoteImage(url: Formatters.https(user.face))
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                VStack(spacing: 3) {
                    Text(user.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Lv.\(user.level)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    stat("关注", Formatters.count(user.following))
                    stat("粉丝", Formatters.count(user.follower))
                    stat("硬币", Formatters.decimal(user.coin))
                }
                .padding(.top, 2)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var loginSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.qrcode")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Button {
                showLogin = true
            } label: {
                Label("扫码登录", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("设置", systemImage: "gearshape.fill")
                .font(.headline)

            settingRow("外观") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("默认开启弹幕", isOn: $danmakuEnabled)
                .font(.callout)

            settingRow("弹幕速度") {
                Picker("弹幕速度", selection: $danmakuSpeed) {
                    ForEach(DanmakuSpeed.allCases) { speed in
                        Text(speed.label).tag(speed.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

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

    private func settingRow(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
            control()
        }
    }

    // MARK: - 关于 / 退出

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("关于", systemImage: "info.circle")
                .font(.headline)
            Text("Bilibili Client \(BuildInfo.version)（构建 \(BuildInfo.build)）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("原生 SwiftUI · Liquid Glass · 仅供个人学习研究")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var logoutButton: some View {
        Button(role: .destructive) {
            session.logout()
        } label: {
            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
    }
}
