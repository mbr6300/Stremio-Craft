import SwiftUI

/// Rundes Foto mit Name und Rolle – in der Reihe „Regie & Besetzung“ der Detailseite.
struct PersonCard: View {
    var person: PersonRef
    @Environment(\.isFocused) private var isFocused

    private var size: CGFloat { Theme.s(150) }

    var body: some View {
        VStack(spacing: Theme.s(10)) {
            PersonPhoto(person: person, size: size)
                .overlay {
                    Circle().strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
                }
                .scaleEffect(isFocused ? 1.1 : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
            Text(person.name)
                .font(.system(size: Theme.s(20), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(person.roleLabel)
                .font(.system(size: Theme.s(17)))
                .foregroundStyle(person.role == .cast ? .white.opacity(0.55) : Theme.accent)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(width: Theme.s(180))
    }
}

private struct PersonPhoto: View {
    var person: PersonRef
    var size: CGFloat

    var body: some View {
        Group {
            if person.photoURL != nil {
                RemoteImage(url: person.photoURL, maxPoints: size, placeholderSymbol: "person.fill")
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Personenseite: bei Regie zuerst die eigenen Filme, bei Schauspiel zuerst die Rollen.
struct PersonView: View {
    var person: PersonRef
    @Environment(AppModel.self) private var model
    @State private var filmography: Filmography?
    @State private var message: String?

    private var columns: [GridItem] {
        Platform.isPhone
            ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
            : [GridItem(.adaptive(minimum: Theme.posterSize.width, maximum: Theme.posterSize.width + 20), spacing: Theme.s(44))]
    }

    private var sections: [(title: String, items: [MediaItem])] {
        guard let filmography else { return [] }
        let directing = (title: "Regie & Idee", items: filmography.directed)
        let acting = (title: "Spielt mit in", items: filmography.acted)
        let ordered = person.role == .cast ? [acting, directing] : [directing, acting]
        return ordered.filter { !$0.items.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(40)) {
                HStack(spacing: Theme.s(28)) {
                    PersonPhoto(person: person, size: Theme.s(140))
                    Text(person.name)
                        .font(.system(size: Theme.s(52), weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
                if let message {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                } else if filmography == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if sections.isEmpty {
                    EmptyHint(text: "Keine Filme oder Serien gefunden.", symbol: "film")
                }
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: Theme.s(24)) {
                        Text(section.title)
                            .font(.system(size: Theme.s(34), weight: .bold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s(56)) {
                            ForEach(section.items) { item in
                                MediaLink(item: item, subtitle: item.yearText)
                            }
                        }
                    }
                    .tvFocusSection()
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, Theme.s(90)) // wie die Detailseite: frei vom Zurück-Knopf
            .padding(.bottom, Theme.s(50))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .task {
            guard filmography == nil else { return }
            do {
                filmography = try await TMDBClient.fetchFilmography(apiKey: model.tmdbAPIKey, personId: person.id)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
