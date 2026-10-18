import SwiftUI

/// Beschreibt eine TMDB-Discover-Liste: Genre, Plattformen, nur Neues.
/// Filme und Serien werden getrennt abgefragt und in Regalen gemischt.
struct DiscoverQuery: Hashable {
    var title: String
    var providers: [Int] = []
    var movieGenre: Int?
    var tvGenre: Int?
    var includeMovies = true
    var includeSeries = true
    var recent = false
    var sort: GenreSort = .popular
    /// Feste Katalog-Region (z. B. Hulu → US); sonst die eingestellte Region.
    var region: String?

    /// Neu & im Trend quer über die Plattformen der eingestellten Region (Startseiten-Reihe).
    /// Anbieter mit fester anderer Region (Hulu) gehören nicht dazu.
    static var newOnAllProviders: DiscoverQuery {
        DiscoverQuery(
            title: "Neu & im Trend auf deinen Plattformen",
            providers: TMDBClient.providers.filter { $0.region == nil }.flatMap(\.allIds),
            recent: true
        )
    }

    private var isGenreQuery: Bool { movieGenre != nil || tvGenre != nil }
    var allowsMovies: Bool { includeMovies && (!isGenreQuery || movieGenre != nil) }
    var allowsSeries: Bool { includeSeries && (!isGenreQuery || tvGenre != nil) }
}

/// Hält erste Seiten im Speicher, damit Zurück-Navigation nichts neu lädt.
actor DiscoverCache {
    static let shared = DiscoverCache()

    /// Je Region getrennt, sonst bliebe nach einem Regionswechsel der alte Katalog stehen.
    private struct Key: Hashable {
        var query: DiscoverQuery
        var country: String
    }

    private var rows: [Key: [MediaItem]] = [:]

    func firstPage(_ query: DiscoverQuery, apiKey: String, country: String) async throws -> [MediaItem] {
        let key = Key(query: query, country: country)
        if let hit = rows[key] { return hit }
        async let movies: [MediaItem] = query.allowsMovies
            ? TMDBClient.fetchDiscover(apiKey: apiKey, country: country, query: query, type: "movie", sort: query.sort, page: 1).items
            : []
        async let series: [MediaItem] = query.allowsSeries
            ? TMDBClient.fetchDiscover(apiKey: apiKey, country: country, query: query, type: "tv", sort: query.sort, page: 1).items
            : []
        let (m, s) = try await (movies, series)
        var mixed: [MediaItem] = []
        for index in 0..<max(m.count, s.count) {
            if index < m.count { mixed.append(m[index]) }
            if index < s.count { mixed.append(s[index]) }
        }
        rows[key] = mixed
        return mixed
    }
}

/// Regal, das seine Inhalte selbst lädt, sobald es sichtbar wird.
struct DiscoverShelf: View {
    @Environment(AppModel.self) private var model
    var query: DiscoverQuery

    @State private var items: [MediaItem] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded || !items.isEmpty {
                Shelf(title: query.title, shelfID: query.title, seeAll: items.isEmpty ? nil : .discover(query)) {
                    if items.isEmpty {
                        PlaceholderShelfItems()
                    } else {
                        ForEach(items) { item in
                            MediaLink(item: item, listRoute: .discover(query))
                        }
                    }
                }
            }
        }
        // Lädt einmal je Region (der Cache liefert Bekanntes sofort, ohne Netz).
        .task(id: model.country) {
            items = (try? await DiscoverCache.shared.firstPage(query, apiKey: model.tmdbAPIKey, country: model.country)) ?? []
            loaded = true
        }
    }
}

/// Vollständige Liste als Raster: Sortierung, ggf. Filme/Serien-Umschalter, Nachladen beim Scrollen.
struct DiscoverGridView: View {
    @Environment(AppModel.self) private var model
    var query: DiscoverQuery

    @State private var sort: GenreSort = .popular
    @State private var type = "movie"
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: Theme.posterSize.width, maximum: Theme.posterSize.width + 20), spacing: Theme.s(44))]

    private var title: String {
        guard query.allowsMovies != query.allowsSeries else { return query.title }
        return "\(query.title) · \(query.allowsSeries ? "Serien" : "Filme")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(30)) {
                Text(title)
                    .font(.system(size: Theme.s(52), weight: .heavy))
                HStack(spacing: Theme.s(20)) {
                    if query.allowsMovies && query.allowsSeries {
                        Button("Filme") { type = "movie" }
                            .buttonStyle(PillButtonStyle(selected: type == "movie"))
                        Button("Serien") { type = "tv" }
                            .buttonStyle(PillButtonStyle(selected: type == "tv"))
                        Divider().frame(height: Theme.s(40))
                    }
                    ForEach(GenreSort.allCases) { option in
                        Button(option.label) { sort = option }
                            .buttonStyle(PillButtonStyle(selected: sort == option))
                    }
                }
                .tvFocusSection()
                if let message, items.isEmpty {
                    EmptyHint(text: message, symbol: "exclamationmark.triangle")
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s(56)) {
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
                .tvFocusSection()
                if isLoading && !items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(50))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            if items.isEmpty {
                sort = query.sort
                type = query.allowsMovies ? "movie" : "tv"
            }
        }
        .task(id: "\(sort.rawValue)|\(type)") {
            items = []
            page = 0
            totalPages = 1
            message = nil
            await loadMore()
        }
    }

    private func loadMore() async {
        guard model.hasTMDBKey else {
            message = "TMDB-API-Schlüssel fehlt."
            return
        }
        guard !isLoading, page < totalPages, page < 25 else { return }
        isLoading = true
        defer { isLoading = false }
        let key = "\(sort.rawValue)|\(type)"
        do {
            let result = try await TMDBClient.fetchDiscover(
                apiKey: model.tmdbAPIKey,
                country: model.country,
                query: query,
                type: type,
                sort: sort,
                page: page + 1
            )
            guard key == "\(sort.rawValue)|\(type)" else { return }
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

/// Vollständige Ansicht einer Startseiten-Reihe (Trends, IMDb-Listen, eigene Listen, Favoriten …).
struct RowGridView: View {
    @Environment(AppModel.self) private var model
    var rowId: String
    @State private var filter: MediaFilter = .all

    private let columns = [GridItem(.adaptive(minimum: Theme.posterSize.width, maximum: Theme.posterSize.width + 20), spacing: Theme.s(44))]

    var body: some View {
        let row = model.rows.first { $0.id == rowId }
        let items = (row?.items ?? []).filter(filter.matches)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(30)) {
                Text(row?.title ?? "Liste")
                    .font(.system(size: Theme.s(52), weight: .heavy))
                HStack(spacing: Theme.s(20)) {
                    ForEach(MediaFilter.allCases) { option in
                        Button(option.label) { filter = option }
                            .buttonStyle(PillButtonStyle(selected: filter == option))
                    }
                    Text("\(items.count) Titel")
                        .font(.system(size: Theme.s(22)))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.leading, Theme.s(10))
                }
                .tvFocusSection()
                if items.isEmpty {
                    EmptyHint(text: row?.isLoading == true ? "Wird geladen…" : "Keine Titel.", symbol: "tray")
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.s(56)) {
                    ForEach(items) { item in
                        MediaLink(item: item)
                    }
                }
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(50))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - Plattform-Seite

struct ProviderBrand {
    var name: String
    var color: Color
    var providerIds: [Int]
    var region: String?

    static func brand(for id: String) -> ProviderBrand? {
        guard let provider = TMDBClient.providers.first(where: { $0.id == id }) else { return nil }
        let colors: [String: Color] = [
            "netflix": Color(red: 0.90, green: 0.04, blue: 0.08),
            "disney": Color(red: 0.07, green: 0.24, blue: 0.81),
            "prime": Color(red: 0.0, green: 0.66, blue: 0.88),
            "hbo": Color(red: 0.42, green: 0.16, blue: 0.85),
            "paramount": Color(red: 0.0, green: 0.39, blue: 1.0),
            "hulu": Color(red: 0.11, green: 0.91, blue: 0.51)
        ]
        return ProviderBrand(
            name: provider.name,
            color: colors[id] ?? Theme.accent,
            providerIds: provider.allIds,
            region: provider.region
        )
    }

    /// Aufbau ähnlich den Startseiten der Anbieter: Neues, Beliebtes, Bestbewertetes, dann Genres.
    var sections: [DiscoverQuery] {
        let p = providerIds
        let genres: [(String, Int?, Int?)] = [
            ("Action & Abenteuer", 28, 10759),
            ("Komödien", 35, 35),
            ("Drama", 18, 18),
            ("Thriller", 53, nil),
            ("Krimi", 80, 80),
            ("Science-Fiction & Fantasy", 878, 10765),
            ("Horror", 27, nil),
            ("Animation", 16, 16),
            ("Familie", 10751, 10751),
            ("Dokumentationen", 99, 99),
            ("Liebesfilme", 10749, nil),
            ("Krieg", 10752, 10768)
        ]
        let queries = [
            DiscoverQuery(title: "Neu auf \(name)", providers: p, recent: true),
            DiscoverQuery(title: "Beliebte Filme", providers: p, includeSeries: false),
            DiscoverQuery(title: "Beliebte Serien", providers: p, includeMovies: false),
            DiscoverQuery(title: "Top bewertete Filme", providers: p, includeSeries: false, sort: .topRated),
            DiscoverQuery(title: "Top bewertete Serien", providers: p, includeMovies: false, sort: .topRated)
        ] + genres.map { DiscoverQuery(title: $0.0, providers: p, movieGenre: $0.1, tvGenre: $0.2) }
        return queries.map { query in
            var copy = query
            copy.region = region
            return copy
        }
    }
}

struct ProviderView: View {
    var providerId: String
    @State private var hero = HeroState()

    var body: some View {
        if let brand = ProviderBrand.brand(for: providerId) {
            ZStack(alignment: .topLeading) {
                HeroBackdrop(fallback: nil)
                // Markenfarbe als Schimmer von oben, damit sich die Seite wie die Plattform anfühlt.
                LinearGradient(colors: [brand.color.opacity(0.45), .clear], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: Theme.s(0)) {
                    VStack(alignment: .leading, spacing: Theme.s(6)) {
                        Text(brand.name.uppercased() + (brand.region.map { "  ·  \($0)-KATALOG" } ?? ""))
                            .font(.system(size: Theme.s(26), weight: .black))
                            .kerning(4)
                            .foregroundStyle(brand.color)
                            .brightness(0.15)
                        HeroInfo(fallback: nil, placeholder: "Neu, beliebt und nach Genres")
                    }
                    .frame(height: Theme.s(185), alignment: .bottomLeading)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, Theme.headerGap)
                    ShelvesScroll {
                        ForEach(brand.sections, id: \.title) { query in
                            DiscoverShelf(query: query)
                        }
                    }
                }
            }
            .environment(hero)
            .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            EmptyHint(text: "Unbekannte Plattform.")
        }
    }
}
