import SwiftUI

struct RemoteImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.55))
    }
}
