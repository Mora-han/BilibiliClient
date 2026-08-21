import SwiftUI

/// 列表滚动到底部时自动加载下一页的原生小部件：
/// 可见即触发加载，无需手动点击；加载失败时点击可重试。
struct LoadMoreFooter: View {
    var isBusy: Bool
    var onLoad: () async -> Void

    var body: some View {
        Button {
            Task { await onLoad() }
        } label: {
            ProgressView()
                .controlSize(.small)
                .opacity(isBusy ? 1 : 0.45)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onAppear {
            Task { await onLoad() }
        }
    }
}

/// 统一的“需要登录”占位视图。
struct LoginRequiredView: View {
    let title: String
    let systemImage: String
    let message: String
    @Binding var showLogin: Bool

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button("扫码登录") { showLogin = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 统一的列表加载失败占位视图（带重试）。
struct LoadErrorView: View {
    let message: String
    var retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") {
                Task { await retry() }
            }
        }
    }
}
