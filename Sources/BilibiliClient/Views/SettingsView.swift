import SwiftUI

/// 全屏模式：平滑全屏（自带动画 + 弹幕）/ 纯享模式（系统原生，无弹幕）
enum FullscreenMode: String, CaseIterable, Identifiable {
    case smooth = "smooth"
    case pure = "pure"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "平滑全屏"
        case .pure: return "纯享模式"
        }
    }

    var subtitle: String {
        switch self {
        case .smooth: return "视频从原位平滑放大到全屏，全屏内保留弹幕与弹幕开关"
        case .pure: return "系统原生全屏与播放器动画，全屏内不显示弹幕，专注画面本身"
        }
    }
}

struct SettingsView: View {
    @AppStorage("fullscreenMode") private var modeRaw = FullscreenMode.smooth.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置")
                    .font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 10) {
                    Text("全屏模式")
                        .font(.headline)
                    Text("选择进入全屏的方式")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        ForEach(FullscreenMode.allCases) { mode in
                            modeRow(mode)
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
        .navigationTitle("设置")
    }

    private func modeRow(_ mode: FullscreenMode) -> some View {
        Button {
            modeRaw = mode.rawValue
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: modeRaw == mode.rawValue ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(modeRaw == mode.rawValue ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.body.weight(.medium))
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary.opacity(modeRaw == mode.rawValue ? 0.35 : 0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(modeRaw == mode.rawValue ? Color.accentColor.opacity(0.5) : .white.opacity(0.06),
                                          lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}
