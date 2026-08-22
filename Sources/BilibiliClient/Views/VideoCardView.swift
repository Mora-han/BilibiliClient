import SwiftUI

/// 首页卡片（推荐/热门/分区排行通用），支持右上角排行序号。
struct VideoCardView: View {
    let bvid: String
    let title: String
    let pic: String
    let duration: Int
    let ownerName: String
    let viewCount: Int
    var badgeText: String?
    var rank: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text(ownerName.isEmpty ? "未知UP主" : ownerName)
                    .lineLimit(1)
                Spacer()
                if viewCount > 0 {
                    Image(systemName: "play.fill")
                    Text(Formatters.count(viewCount))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .contentCard()
        .hoverScale(cornerRadius: 18)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(url: Formatters.https(pic))
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)

            if duration > 0 {
                Text(Formatters.duration(duration))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if let badgeText, !badgeText.isEmpty {
                Text(badgeText)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.pink.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let rank {
                Text("\(rank)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(rankColor(rank), in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.95, green: 0.27, blue: 0.27)
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.16)
        case 3: return Color(red: 0.95, green: 0.76, blue: 0.22)
        default: return .black.opacity(0.6)
        }
    }
}
