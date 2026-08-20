import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var showLogin = false
    @State private var showLogoutConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if session.loggedIn {
                    userCard
                    logoutButton
                } else {
                    loginCard
                }
                aboutCard
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .navigationTitle("我的")
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .confirmationDialog("确定退出登录吗？", isPresented: $showLogoutConfirm,
                            titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                session.logout()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var userCard: some View {
        VStack(spacing: 14) {
            if let user = session.user {
                RemoteImage(url: Formatters.https(user.face))
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                Text(user.name)
                    .font(.title3.bold())

                Text("Lv.\(user.level)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 30) {
                    VStack {
                        Text(Formatters.count(user.following)).font(.headline)
                        Text("关注").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack {
                        Text(Formatters.count(user.follower)).font(.headline)
                        Text("粉丝").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack {
                        Text(Formatters.decimal(user.coin)).font(.headline)
                        Text("硬币").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassCard()
    }

    private var logoutButton: some View {
        Button(role: .destructive) {
            showLogoutConfirm = true
        } label: {
            Text("退出登录")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var loginCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.qrcode")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("登录后同步关注与推荐")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("扫码登录") {
                showLogin = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Bilibili Client", systemImage: "info.circle")
                .font(.headline)
            Text("版本 \(BuildInfo.version)（构建 \(BuildInfo.build)）· 原生 SwiftUI · Liquid Glass")
                .font(.callout)
            Text("数据接口来自社区整理的 bilibili-API-collect，仅用于个人学习研究。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 14)
    }
}
