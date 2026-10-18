import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: Theme.posterSize.width, maximum: Theme.posterSize.width + 20), spacing: Theme.s(44))]

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var message = "Filme und Serien über TMDB suchen."
    @State private var isSearching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(24)) {
                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if results.isEmpty {
                    if trimmedQuery.isEmpty && !model.recentSearches.isEmpty {
                        recentSearches
                    } else {
                        EmptyHint(text: message, symbol: "magnifyingglass")
                    }
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.s(56)) {
                        ForEach(results) { item in
                            MediaLink(item: item, subtitle: item.metaText)
                        }
                    }
                    .tvFocusSection()
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(40))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .searchable(text: $query, prompt: "Film oder Serie")
        .onSubmit(of: .search) { model.addRecentSearch(query) }
        .task(id: query) {
            // Entprellen: erst suchen, wenn kurz nicht getippt wird.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await search()
            // Begriff merken, wenn er Treffer hatte und eine Weile stehen bleibt
            // (live getippte Zwischenstände landen so nicht im Verlauf).
            guard !results.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            model.addRecentSearch(query)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: Theme.s(20)) {
            HStack(spacing: Theme.s(24)) {
                Text("Zuletzt gesucht")
                    .font(.system(size: Theme.s(30), weight: .bold))
                Spacer()
                Button("Verlauf löschen") { model.clearRecentSearches() }
                    .buttonStyle(PillButtonStyle())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.s(300)), spacing: Theme.s(24))], alignment: .leading, spacing: Theme.s(24)) {
                ForEach(model.recentSearches, id: \.self) { term in
                    Button {
                        query = term
                    } label: {
                        Label(term, systemImage: "clock.arrow.circlepath")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PillButtonStyle())
                    .contextMenu {
                        Button("Aus Verlauf entfernen", role: .destructive) { model.removeRecentSearch(term) }
                    }
                }
            }
        }
        .tvFocusSection()
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            results = []
            message = "Filme und Serien über TMDB suchen."
            return
        }
        guard model.hasTMDBKey else {
            message = "TMDB-API-Schlüssel fehlt. Bitte in den Einstellungen eintragen."
            results = []
            return
        }
        isSearching = results.isEmpty
        defer { isSearching = false }
        do {
            let found = try await TMDBClient.search(apiKey: model.tmdbAPIKey, query: text)
            guard !Task.isCancelled else { return }
            results = found
            message = found.isEmpty ? "Nichts gefunden für „\(text)“." : ""
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            message = error.localizedDescription
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(28)) {
                section("Weiterschauen") {
                    if model.continueWatching.isEmpty {
                        EmptyHint(text: "Noch nichts angefangen.", symbol: "play.circle")
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.s(56)) {
                            ForEach(model.continueWatching) { entry in
                                ContinueCard(entry: entry)
                            }
                        }
                    }
                }
                section("Meine Liste") {
                    if model.favorites.isEmpty {
                        EmptyHint(text: "Auf der Detailseite mit „Meine Liste“ merken.", symbol: "plus")
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.s(56)) {
                            ForEach(model.favorites) { favorite in
                                MediaLink(item: favorite.media, subtitle: favorite.year.map(String.init))
                            }
                        }
                    }
                }
                section("♥ Lieblingstitel") {
                    if model.loved.isEmpty {
                        EmptyHint(text: "Titel, die du besonders magst, mit ♥ markieren – sie prägen die Empfehlungen.", symbol: "heart")
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Theme.s(56)) {
                            ForEach(model.loved) { item in
                                MediaLink(item: item.media, subtitle: item.year.map(String.init))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(40))
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.s(24)) {
            Text(title)
                .font(.system(size: Theme.s(34), weight: .bold))
            content()
        }
        .tvFocusSection()
    }
}
