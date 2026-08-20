import SwiftUI

/// 分区页：官方主分区卡片
struct ZonesView: View {
    let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(BiliZones.main) { zone in
                    NavigationLink(value: PartitionRoute(tid: zone.id, name: zone.name)) {
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
                        .glassCard(cornerRadius: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .navigationTitle("分区")
    }
}
