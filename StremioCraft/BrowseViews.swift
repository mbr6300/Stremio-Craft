import SwiftUI

private let gridColumns = [GridItem(.adaptive(minimum: Theme.posterSize.width, maximum: Theme.posterSize.width + 20), spacing: 44)]

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var message = "Filme und Serien über TMDB suchen."
    @State private var isSearching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if results.isEmpty {
                    EmptyHint(text: message, symbol: "magnifyingglass")
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 56) {
                        ForEach(results) { item in
                            MediaLink(item: item, subtitle: item.metaText)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .searchable(text: $query, prompt: "Film oder Serie")
        .task(id: query) {
            // Entprellen: erst suchen, wenn kurz nicht getippt wird.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
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
            VStack(alignment: .leading, spacing: 28) {
                section("Weiterschauen") {
                    if model.continueWatching.isEmpty {
                        EmptyHint(text: "Noch nichts angefangen.", symbol: "play.circle")
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 56) {
                            ForEach(model.continueWatching) { entry in
                                ContinueCard(entry: entry)
                            }
                        }
                    }
                }
                section("Meine Liste") {
                    if model.favorites.isEmpty {
                        EmptyHint(text: "Auf der Detailseite mit ♥ hinzufügen.", symbol: "heart")
                    } else {
                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 56) {
                            ForEach(model.favorites) { favorite in
                                MediaLink(item: favorite.media, subtitle: favorite.year.map(String.init))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
            content()
        }
        .focusSection()
    }
}
