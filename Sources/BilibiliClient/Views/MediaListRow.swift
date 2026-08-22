import SwiftUI

struct MediaListRow: View {
    let coverURL: String
    let title: String
    let line2: String
    let line3: String
    var durationText: String?
    var progress: Double?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: Formatters.https(coverURL))
                    .frame(width: 132, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let durationText {
                    Text(durationText)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Text(line2)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(line3)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let progress, progress > 0 {
                    ProgressView(value: min(progress, 1))
                        .tint(.pink)
                        .scaleEffect(y: 0.7)
                }
            }

            Spacer()
        }
        .padding(10)
        .contentCard(cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.primary.opacity(hovering ? 0.15 : 0), lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
    }
}
