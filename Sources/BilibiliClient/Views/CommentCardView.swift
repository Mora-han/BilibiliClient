import SwiftUI

struct CommentCardView: View {
    let comment: CommentItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteImage(url: Formatters.https(comment.member?.avatar ?? ""))
                .frame(width: 32, height: 32)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.member?.uname ?? "匿名用户")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let level = comment.member?.levelInfo?.currentLevel {
                        Text("Lv.\(level)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if comment.upAction?.like == true {
                        Label("UP 赞了", systemImage: "hand.thumbsup.fill")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                    }
                }

                Text(comment.content?.message ?? "")
                    .font(.callout)
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    Text(Formatters.timeAgo(comment.ctime ?? 0))
                    Label(Formatters.count(comment.like ?? 0), systemImage: "hand.thumbsup")
                    if let rcount = comment.rcount, rcount > 0 {
                        Text("\(rcount) 条回复")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}
