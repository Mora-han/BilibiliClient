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
/// 内部共用组件，供本文件里各种骨架拼出长短不一的层次。
struct SkeletonBar: View {
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

/// 播放页 / 直播间详情的首屏骨架：16:9 画面占位 + 标题条 + UP 主行 + 数据行 + 简介条。
///
/// 与 `VideoDetailView` / `LiveDetailView` 加载态的真实布局同构（画面在上、信息在下），
/// 外层沿用两页加载态已有的 `maxWidth: 980` + `padding(24)` 约束，替换后版面不跳。
struct MediaDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .fill(.quaternary.opacity(0.55))
                }

            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(height: 20)
                    .frame(maxWidth: 520, alignment: .leading)
                SkeletonBar(height: 20)
                    .frame(maxWidth: 360, alignment: .leading)

                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.quaternary.opacity(0.55))
                            .frame(width: 30, height: 30)
                        SkeletonBar(height: 12)
                            .frame(maxWidth: 96, alignment: .leading)
                    }
                    Spacer(minLength: 8)
                    SkeletonBar(height: 12)
                        .frame(width: 56)
                    SkeletonBar(height: 12)
                        .frame(width: 56)
                }

                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonBar(height: 28)
                            .frame(width: 64)
                    }
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBar(height: 12)
                    SkeletonBar(height: 12)
                    SkeletonBar(height: 12)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}

/// 动态详情页骨架：作者头像行 + 正文条 + 配图占位 + 底部互动条。
struct DynamicDetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Circle()
                    .fill(.quaternary.opacity(0.55))
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(height: 13)
                        .frame(maxWidth: 120, alignment: .leading)
                    SkeletonBar(height: 10)
                        .frame(maxWidth: 80, alignment: .leading)
                }
                Spacer(minLength: 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(height: 13)
                SkeletonBar(height: 13)
                SkeletonBar(height: 13)
                    .frame(maxWidth: 380, alignment: .leading)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 10)],
                      spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .circular)
                                .fill(.quaternary.opacity(0.55))
                        }
                }
            }

            Divider()

            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBar(height: 12)
                        .frame(width: 56)
                }
                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}

/// UP 主页头部骨架：头像圆 + 昵称条 + 简介条 + 关注按钮位，与 `UpProfileView.header` 同构。
struct ProfileHeaderSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle()
                .fill(.quaternary.opacity(0.55))
                .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(height: 18)
                    .frame(maxWidth: 160, alignment: .leading)
                SkeletonBar(height: 12)
                    .frame(maxWidth: 300, alignment: .leading)
                SkeletonBar(height: 12)
                    .frame(maxWidth: 240, alignment: .leading)
                HStack(spacing: 20) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBar(height: 11)
                            .frame(width: 64)
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 8)

            SkeletonBar(height: 30)
                .frame(width: 76)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}

/// 动态流卡片骨架：作者行 + 正文条 + 投稿封面占位 + 底部互动条，与 `DynamicCardView` 同构。
struct DynamicCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.quaternary.opacity(0.55))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    SkeletonBar(height: 12)
                        .frame(maxWidth: 110, alignment: .leading)
                    SkeletonBar(height: 9)
                        .frame(maxWidth: 70, alignment: .leading)
                }
                Spacer(minLength: 8)
            }

            VStack(alignment: .leading, spacing: 8) {
                SkeletonBar(height: 12)
                SkeletonBar(height: 12)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .circular)
                    .fill(.quaternary.opacity(0.55))
                    .frame(width: 108, height: 62)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBar(height: 12)
                        .frame(maxWidth: 180, alignment: .leading)
                    SkeletonBar(height: 10)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBar(height: 11)
                        .frame(width: 48)
                }
                Spacer(minLength: 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}

/// 动态流骨架：与 `DynamicFeedView` 的排版一致 —— 两列列表模式双列铺卡，其余单列。
struct DynamicFeedSkeleton: View {
    var mode: VideoDisplayMode = .card
    /// 占位数量：够铺满首屏再多一点即可
    var count: Int = 6
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if mode == .list2, horizontalSizeClass != .compact {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(0..<count, id: \.self) { _ in
                        DynamicCardSkeleton()
                    }
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(0..<count, id: \.self) { _ in
                        DynamicCardSkeleton()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}

/// 菜单栏动态面板的行骨架：小头像 + 昵称条 + 正文条，与 `MenuBarDynamicRow` 同构。
/// 面板只有 380pt 宽，占位数量给足一屏即可。
struct MenuBarRowSkeleton: View {
    var count: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .padding(.leading, 56)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.quaternary.opacity(0.55))
                            .frame(width: 26, height: 26)
                        SkeletonBar(height: 11)
                            .frame(maxWidth: 96, alignment: .leading)
                        Spacer(minLength: 8)
                        SkeletonBar(height: 9)
                            .frame(width: 40)
                    }
                    SkeletonBar(height: 11)
                    SkeletonBar(height: 11)
                        .frame(maxWidth: 240, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("加载中")
    }
}
