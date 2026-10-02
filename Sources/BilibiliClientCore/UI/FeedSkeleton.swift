import SwiftUI

/// 首屏加载骨架：数据到达前先用「空白视频占位」铺满版面，而不是整页转圈。
///
/// 骨架直接复用 `VideoFeedLayout`，列数、间距与卡片 / 列表形态和真实内容完全一致，
/// 内容填充时不会发生布局跳动；占位块统一用 `.quaternary` 层级灰，浅色 / 深色都成立。
struct VideoFeedSkeleton: View {
    /// 与内容区一致的展示模式（卡片 / 单列 / 两列）
    var mode: VideoDisplayMode = .card
    /// 占位数量：够铺满首屏再多一点即可
    var count: Int = 12

    var body: some View {
        VideoFeedLayout(mode: mode) {
            ForEach(0..<count, id: \.self) { _ in
                VideoCardSkeleton()
            }
        } rowContent: {
            ForEach(0..<count, id: \.self) { _ in
                MediaListRowSkeleton()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}

/// 骨架里的一根占位条：宽度自适应，必要时用 `maxWidth` 截出长短不一的层次。
private struct SkeletonBar: View {
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .circular)
            .fill(.quaternary)
            .frame(height: height)
    }
}

/// 与 `VideoCardView` 同构的空白卡片：16:9 封面 + 两行标题 + 底部信息条。
private struct VideoCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .fill(.quaternary.opacity(0.55))
                }
                .overlay(alignment: .bottomTrailing) {
                    // 时长角标的位置
                    RoundedRectangle(cornerRadius: 5, style: .circular)
                        .fill(.quaternary)
                        .frame(width: 36, height: 13)
                        .padding(6)
                }

            // 隐藏的换行撑出与真实卡片一致的两行标题高度，短标题也不会让卡片变矮
            ZStack(alignment: .topLeading) {
                Text("\n")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .hidden()
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(height: 12)
                    SkeletonBar(height: 12)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 8) {
                SkeletonBar(height: 11)
                    .frame(maxWidth: 110, alignment: .leading)
                Spacer(minLength: 8)
                SkeletonBar(height: 11)
                    .frame(width: 44)
            }
        }
        .padding(10)
        .contentCard()
    }
}

/// 与 `MediaListRow` 同构的空白行：固定尺寸封面 + 标题 / UP 主 / 播放量占位条。
private struct MediaListRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .circular)
                .fill(.quaternary.opacity(0.55))
                .frame(width: 132, height: 78)

            VStack(alignment: .leading, spacing: 5) {
                SkeletonBar(height: 13)
                SkeletonBar(height: 13)
                    .frame(maxWidth: 200, alignment: .leading)
                SkeletonBar(height: 10)
                    .frame(maxWidth: 96, alignment: .leading)
                SkeletonBar(height: 10)
                    .frame(maxWidth: 72, alignment: .leading)
            }
        }
        .padding(10)
        .contentCard(cornerRadius: 14)
    }
}
