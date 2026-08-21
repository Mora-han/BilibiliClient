import SwiftUI

/// 侧边栏底部账户卡片弹出的面板：仅展示纯个人信息与退出登录。
struct AccountPanelView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var showLogin: Bool

    var body: some View {
        VStack(spacing: 14) {
            if session.loggedIn {
                userSection
                Divider()
                logoutButton
            } else {
                loginSection
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var userSection: some View {
        VStack(spacing: 12) {
            if let user = session.user {
                RemoteImage(url: Formatters.https(user.face))
                    .frame(width: 60, height: 60)
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
