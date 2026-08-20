import SwiftUI

/// 液态玻璃风格搜索框（App Store 样式）。
struct GlassSearchField: View {
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(0.06))
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
