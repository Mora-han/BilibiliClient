import SwiftUI

/// 空降提示卡片：浮在画面上，告诉用户「刚刚跳了什么」，并提供一键回退。
///
/// 材质与自绘控制栏同一套（`glassEffect` 液态玻璃），所以压在画面上不会突兀。
///
/// 关键点：这个卡片**必须挂在播放器自己的覆盖层里**，不能当播放组件的 SwiftUI
/// 同级视图。原因有两个：
/// 1. macOS 上 `AVPlayerView`（`NSViewRepresentable`）会盖住 ZStack 里的
///    SwiftUI 同级视图；
/// 2. 进全屏时 AVKit 把播放器搬进另一个窗口，页面里的浮层根本不会跟过去。
/// 控制栏与弹幕层当初也是因为同样的原因挂在 `contentOverlayView` 上。
struct SponsorNoticeCard: View {
    let notice: SponsorNotice
    /// 点「回退」。
    var onUndo: (() -> Void)?
    /// 关掉卡片（不做任何回退）。
    var onDismiss: (() -> Void)?

    @State private var hoveringUndo = false

    private var canUndo: Bool { notice.isUndoable && onUndo != nil }

    private var accent: Color {
        Color(hex: notice.segment.category.markerColorHex) ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if canUndo {
                undoButton
            }
        }
        .padding(12)
        .frame(width: 262, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.06))
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        // 卡片压在画面上，配色不跟随系统深浅，避免亮色画面上糊成一片
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 内容

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.22))
                    .frame(width: 26, height: 26)
                Image(systemName: notice.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.callout.weight(.semibold))
                Text(notice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关掉提示（不改变播放位置）")
            }
        }
    }

    private var undoButton: some View {
        Button {
            onUndo?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
                Text("回退")
                    .font(.caption.weight(.semibold))
                if let hint = notice.actionHint {
                    Text("· \(hint)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(hoveringUndo ? 0.28 : 0.16))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .onHover { inside in
            hoveringUndo = inside
            AppPlatform.setPointingHandCursor(inside)
        }
        // 卡片是定时消失的：鼠标还在上面时整条被移除，不会再有 onHover(false)
        .onDisappear {
            guard hoveringUndo else { return }
            hoveringUndo = false
            AppPlatform.setPointingHandCursor(false)
        }
    }
}
