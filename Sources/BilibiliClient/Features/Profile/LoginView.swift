import AppKit
import CoreImage
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var qrImage: NSImage?
    @State private var qrURL: URL?
    @State private var statusText = "正在获取二维码…"
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Text("扫码登录")
                .font(.title2.bold())

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white)
                    .frame(width: 224, height: 224)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)

                if let qrImage {
                    Image(nsImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 200, height: 200)
                } else {
                    ProgressView()
                }
            }

            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(qrImage == nil)

                Button {
                    openInBrowser()
                } label: {
                    Label("浏览器打开", systemImage: "safari")
                }
                .disabled(qrURL == nil)

                Button("取消") {
                    dismiss()
                }
            }
        }
        .padding(28)
        .frame(width: 380)
        .onAppear { refresh() }
        .onDisappear { pollTask?.cancel() }
    }

    private func refresh() {
        pollTask?.cancel()
        qrImage = nil
        qrURL = nil
        statusText = "正在获取二维码…"
        pollTask = Task { @MainActor in
            do {
                let result = try await AuthService.generateQR()
                try Task.checkCancellation()
                qrURL = result.url
                qrImage = QRGenerator.image(from: result.url.absoluteString, size: 200)
                statusText = "请使用哔哩哔哩 App 扫码"
                await poll(key: result.key)
            } catch is CancellationError {
                // 用户主动取消
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    private func poll(key: String) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
                switch try await AuthService.poll(key: key) {
                case .waiting:
                    statusText = "请使用哔哩哔哩 App 扫码"
                case .scanned:
                    statusText = "已扫描，请在手机上确认登录"
                case .expired:
                    statusText = "二维码已失效，点击刷新重试"
                    return
                case .success(let cookies):
                    session.apply(cookies: cookies)
                    dismiss()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                statusText = error.localizedDescription
                return
            }
        }
    }

    private func openInBrowser() {
        guard let qrURL else { return }
        NSWorkspace.shared.open(qrURL)
    }
}

enum QRGenerator {
    static func image(from string: String, size: CGFloat) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
