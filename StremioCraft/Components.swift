import Observation
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.24, green: 0.52, blue: 1.0)
    static let accentDeep = Color(red: 0.16, green: 0.24, blue: 0.78)
    static let background = Color(red: 0.035, green: 0.05, blue: 0.11)
    static let surface = Color.white.opacity(0.07)
    static let posterSize = CGSize(width: 200, height: 300)
    static let stillSize = CGSize(width: 384, height: 216)
    static let pagePadding: CGFloat = 80
}

/// Zuletzt fokussierter Titel. Nur der Hero-Bereich beobachtet ihn, die Regale nicht –
/// so löst ein Fokuswechsel keinen Neuaufbau der ganzen Startseite aus.
@MainActor
@Observable
final class HeroState {
    var item: MediaItem?
}

/// Fokus-Stil im Stil der Apple-TV-App: Poster hebt sich, Rahmen und Schatten nur im Fokus.
struct PosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PosterArtwork: View {
    var url: URL?
    var size: CGSize = Theme.posterSize
    var progress: Double?
    var symbol = "film"

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        RemoteImage(url: url, maxPoints: max(size.width, size.height) * 1.1, placeholderSymbol: symbol)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                if let progress, progress > 0 {
                    ProgressBar(value: progress)
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
            }
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 18, y: 12)
            .scaleEffect(isFocused ? 1.1 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
            .zIndex(isFocused ? 1 : 0)
    }
}

struct ProgressBar: View {
    var value: Double

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: geo.size.width * min(max(value, 0), 1))
                }
            }
    }
}

struct PosterCard: View {
    var title: String
    var subtitle: String?
    var posterURL: URL?
    var progress: Double?

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PosterArtwork(url: posterURL, progress: progress)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.7))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(width: Theme.posterSize.width, alignment: .leading)
            .offset(y: isFocused ? 16 : 0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}

/// Poster, das zur Detailseite führt und dem Hero-Bereich meldet, wenn es fokussiert ist.
struct MediaLink: View {
    var item: MediaItem
    var subtitle: String?
    var progress: Double?

    var body: some View {
        NavigationLink(value: AppRoute.detail(item)) {
            FocusReporter(item: item) {
                PosterCard(
                    title: item.title,
                    subtitle: subtitle ?? item.yearText,
                    posterURL: item.posterURL,
                    progress: progress
                )
            }
        }
        .buttonStyle(PosterButtonStyle())
    }
}

struct FocusReporter<Content: View>: View {
    var item: MediaItem
    @ViewBuilder var content: Content

    @Environment(\.isFocused) private var isFocused
    @Environment(HeroState.self) private var hero: HeroState?

    var body: some View {
        content
            .onChange(of: isFocused) { _, focused in
                if focused, hero?.item?.id != item.id { hero?.item = item }
            }
    }
}

/// Horizontales Regal mit Titel. Lazy, damit nur sichtbare Poster existieren.
struct Shelf<Content: View>: View {
    var title: String
    var isLoading = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                if isLoading {
                    ProgressView().scaleEffect(0.6)
                }
            }
            .padding(.leading, Theme.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 36) {
                    content
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 26)
                .padding(.bottom, 44)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct PlaceholderShelfItems: View {
    var count = 7

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: Theme.posterSize.width, height: Theme.posterSize.height)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.surface)
                    .frame(width: 140, height: 18)
            }
        }
    }
}

struct EmptyHint: View {
    var text: String
    var symbol = "sparkles.tv"

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 20)
    }
}

/// Bildschirmfüllender, abgedunkelter Hintergrund.
struct BackdropLayer: View {
    var url: URL?

    var body: some View {
        ZStack {
            Theme.background
            if let url {
                RemoteImage(url: url, maxPoints: 1920, placeholderSymbol: "")
                    .opacity(0.55)
                    .id(url)
                    .transition(.opacity)
            }
            LinearGradient(
                colors: [Theme.background.opacity(0.95), Theme.background.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [.clear, Theme.background.opacity(0.85), Theme.background],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .animation(.easeInOut(duration: 0.45), value: url)
        .ignoresSafeArea()
    }
}

extension MediaItem {
    var metaText: String {
        let kind = normalizedType == "tv" ? "Serie" : "Film"
        let rating = rating.flatMap { $0 > 0 ? String(format: "★ %.1f", $0) : nil } ?? ""
        return [kind, yearText, rating].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }
}
