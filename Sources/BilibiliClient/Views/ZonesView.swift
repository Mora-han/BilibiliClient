import SwiftUI

/// 分区页：官方主分区卡片
@MainActor
struct ZonesView: View {
    let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(BiliZones.main) { zone in
                    NavigationLink(value: PartitionRoute(tid: zone.id, name: zone.name)) {
                        ZoneCard(zone: zone)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .navigationTitle("分区")
    }
}

/// 分区卡片：鼠标靠近时放大 + 高亮描边（与首页视频卡片同款动效）。
@MainActor
private struct ZoneCard: View {
    let zone: BiliZone

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: zone.icon)
                .font(.system(size: 30))
            Text(zone.name)
                .font(.callout.weight(.medium))
            Text("排行榜")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .contentCard(cornerRadius: 18)
        .hoverScale(scale: 1.03, cornerRadius: 18)
    }
}
