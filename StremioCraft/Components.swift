import SwiftUI

struct PosterCard: View {
    var title: String
    var subtitle: String?
    var posterURL: URL?
    var progress: Double?
    var showsCaption = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color.white.opacity(0.08))
                            .overlay {
                                Image(systemName: "film")
                                    .font(.system(size: 42))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 250, height: 375)
                .clipped()

                if let progress, progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle().fill(Color.red)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .frame(width: 250, height: 375)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if showsCaption {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(width: 250, alignment: .leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 250, alignment: .leading)
                }
            }
        }
    }
}

struct MediaLink: View {
    var item: MediaItem
    var subtitle: String?
    var progress: Double?

    var body: some View {
        NavigationLink(value: AppRoute.detail(item)) {
            PosterCard(
                title: item.title,
                subtitle: subtitle ?? item.yearText,
                posterURL: item.posterURL,
                progress: progress
            )
        }
        .buttonStyle(.card)
    }
}

struct EmptyHint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 640, alignment: .leading)
            .padding(.vertical, 24)
            .focusable()
    }
}




