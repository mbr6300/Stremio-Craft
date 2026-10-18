import SwiftUI

struct Genre: Identifiable, Hashable {
    var id: Int
    var name: String
    var symbol: String
    var hue: Double

    /// TMDB-Genre-IDs. Film- und Serien-Genres unterscheiden sich teilweise.
    static let movie: [Genre] = [
        Genre(id: 28, name: "Action", symbol: "flame", hue: 0.02),
        Genre(id: 12, name: "Abenteuer", symbol: "map", hue: 0.09),
        Genre(id: 35, name: "Komödie", symbol: "face.smiling", hue: 0.14),
        Genre(id: 18, name: "Drama", symbol: "theatermasks", hue: 0.58),
        Genre(id: 53, name: "Thriller", symbol: "eye", hue: 0.75),
        Genre(id: 80, name: "Krimi", symbol: "magnifyingglass", hue: 0.66),
        Genre(id: 27, name: "Horror", symbol: "moon.stars", hue: 0.97),
        Genre(id: 878, name: "Science-Fiction", symbol: "sparkles", hue: 0.52),
        Genre(id: 14, name: "Fantasy", symbol: "wand.and.stars", hue: 0.80),
        Genre(id: 10752, name: "Krieg", symbol: "shield", hue: 0.27),
        Genre(id: 10749, name: "Liebesfilm", symbol: "heart", hue: 0.92),
        Genre(id: 9648, name: "Mystery", symbol: "questionmark.circle", hue: 0.70),
        Genre(id: 16, name: "Animation", symbol: "paintpalette", hue: 0.45),
        Genre(id: 10751, name: "Familie", symbol: "figure.2.and.child.holdinghands", hue: 0.36),
        Genre(id: 36, name: "Historie", symbol: "building.columns", hue: 0.11),
        Genre(id: 99, name: "Dokumentarfilm", symbol: "film", hue: 0.55),
        Genre(id: 37, name: "Western", symbol: "sun.max", hue: 0.07),
        Genre(id: 10402, name: "Musik", symbol: "music.note", hue: 0.85)
    ]

    static let series: [Genre] = [
        Genre(id: 10759, name: "Action & Abenteuer", symbol: "flame", hue: 0.02),
        Genre(id: 35, name: "Komödie", symbol: "face.smiling", hue: 0.14),
        Genre(id: 18, name: "Drama", symbol: "theatermasks", hue: 0.58),
        Genre(id: 80, name: "Krimi", symbol: "magnifyingglass", hue: 0.66),
        Genre(id: 9648, name: "Mystery", symbol: "questionmark.circle", hue: 0.70),
        Genre(id: 10765, name: "Sci-Fi & Fantasy", symbol: "sparkles", hue: 0.52),
        Genre(id: 10768, name: "Krieg & Politik", symbol: "shield", hue: 0.27),
        Genre(id: 16, name: "Animation", symbol: "paintpalette", hue: 0.45),
        Genre(id: 99, name: "Dokumentation", symbol: "film", hue: 0.55),
        Genre(id: 10751, name: "Familie", symbol: "figure.2.and.child.holdinghands", hue: 0.36),
        Genre(id: 10762, name: "Kinder", symbol: "balloon", hue: 0.40),
        Genre(id: 10764, name: "Reality", symbol: "video", hue: 0.88),
        Genre(id: 37, name: "Western", symbol: "sun.max", hue: 0.07)
    ]
}

enum GenreSort: String, CaseIterable, Identifiable, Hashable {
    case popular, topRated, newest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popular: return "Beliebt"
        case .topRated: return "Top bewertet"
        case .newest: return "Neu"
        }
    }
}

struct GenreSelection: Hashable {
    var genre: Genre
    /// "movie" oder "tv"
    var type: String
}

/// Übersicht aller Genres als Kacheln, umschaltbar zwischen Filmen und Serien.
struct CategoriesView: View {
    @AppStorage("categoriesType") private var type = "movie"

    private var genres: [Genre] { type == "tv" ? Genre.series : Genre.movie }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text("Kategorien")
                    .font(.system(size: 52, weight: .heavy))
                Picker("Art", selection: $type) {
                    Text("Filme").tag("movie")
                    Text("Serien").tag("tv")
                }
                .pickerStyle(.segmented)
                .frame(width: 420)
                .focusSection()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 40)], spacing: 40) {
                    ForEach(genres) { genre in
                        NavigationLink(value: AppRoute.genre(GenreSelection(genre: genre, type: type))) {
                            GenreTile(genre: genre)
                        }
                        .buttonStyle(PosterButtonStyle())
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 50)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
    }
}

private struct GenreTile: View {
    var genre: Genre
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    Color(hue: genre.hue, saturation: 0.75, brightness: 0.75),
                    Color(hue: (genre.hue + 0.06).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: genre.symbol)
                .font(.system(size: 90, weight: .semibold))
                .foregroundStyle(.white.opacity(0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(20)
            Text(genre.name)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .padding(24)
        }
        .frame(width: 380, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(isFocused ? 0.9 : 0), lineWidth: 4)
        }
        .scaleEffect(isFocused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// Titel eines Genres als Raster mit Sortierung; lädt beim Scrollen weitere Seiten nach.
struct GenreView: View {
    @Environment(AppModel.self) private var model
    var selection: GenreSelection

    @State private var sort: GenreSort = .popular
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: Theme.posterSize.width, maximum: Theme.posterSize.width + 20), spacing: 44)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("\(selection.genre.name) · \(selection.type == "tv" ? "Serien" : "Filme")")
                    .font(.system(size: 52, weight: .heavy))
                HStack(spacing: 20) {
                    ForEach(GenreSort.allCases) { option in
                        Button(option.label) { sort = option }
                            .buttonStyle(PillButtonStyle(selected: sort == option))
                    }
                }
                .focusSection()
                if let message, items.isEmpty {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                    ForEach(items) { item in
                        MediaLink(item: item)
                            .onAppear {
                                if item.id == items.last?.id { Task { await loadMore() } }
                            }
                    }
                    if isLoading && items.isEmpty {
                        PlaceholderShelfItems(count: 14)
                    }
                }
                .focusSection()
                if isLoading && !items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 50)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .task(id: sort) {
            items = []
            page = 0
            totalPages = 1
            message = nil
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !isLoading, page < totalPages, page < 25, model.hasTMDBKey else {
            if !model.hasTMDBKey { message = "TMDB-API-Schlüssel fehlt." }
            return
        }
        isLoading = true
        defer { isLoading = false }
        let currentSort = sort
        do {
            let result = try await TMDBClient.fetchGenre(
                apiKey: model.tmdbAPIKey,
                country: model.country,
                type: selection.type,
                genreId: selection.genre.id,
                sort: currentSort,
                page: page + 1
            )
            guard currentSort == sort else { return }
            let known = Set(items.map(\.id))
            items += result.items.filter { !known.contains($0.id) }
            page += 1
            totalPages = result.totalPages
            if items.isEmpty { message = "Keine Titel gefunden." }
        } catch {
            message = error.localizedDescription
        }
    }
}
