import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                    .focusSection()
                continueRow
                favoritesRow
                ForEach(model.rows) { row in
                    shelf(title: row.title) {
                        if row.items.isEmpty {
                            EmptyHint(text: row.message ?? "Keine Titel.")
                        } else {
                            horizontal {
                                ForEach(row.items) { item in
                                    MediaLink(item: item, subtitle: item.yearText, progress: nil)
                                }
                            }
                        }
                    }
                }
                if model.isLoadingCatalog {
                    ProgressView("Kataloge werden geladen…")
                        .padding(.bottom, 40)
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 36)
            .padding(.bottom, 200)
        }
        .background(Color.black)
        .task {
            await model.loadCatalogsIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stremio Craft")
                    .font(.system(size: 56, weight: .bold))
                Text("Kataloge über TMDB, Wiedergabe über Torrentio und Real-Debrid")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink(value: AppRoute.search) {
                Label("Suche", systemImage: "magnifyingglass")
                    .font(.title3)
            }
            NavigationLink(value: AppRoute.settings) {
                Label("Einstellungen", systemImage: "gearshape")
                    .font(.title3)
            }
        }
    }

    private var continueRow: some View {
        shelf(title: "Weiterschauen") {
            if model.continueWatching.isEmpty {
                EmptyHint(text: "Noch nichts angefangen. Starte einen Film oder eine Folge.")
            } else {
                horizontal {
                    ForEach(model.continueWatching) { entry in
                        NavigationLink(value: AppRoute.play(playRequest(entry))) {
                            PosterCard(
                                title: entry.title,
                                subtitle: entry.subtitle,
                                posterURL: entry.posterURL,
                                progress: fraction(entry)
                            )
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }

    private var favoritesRow: some View {
        shelf(title: "Favoriten") {
            if model.favorites.isEmpty {
                EmptyHint(text: "Keine Favoriten. Auf der Detailseite hinzufügen.")
            } else {
                horizontal {
                    ForEach(model.favorites) { favorite in
                        MediaLink(item: favorite.media, subtitle: favorite.year.map(String.init), progress: nil)
                    }
                }
            }
        }
    }

    private func playRequest(_ entry: WatchProgress) -> PlaybackRequest {
        PlaybackRequest(
            media: entry.media,
            season: entry.season,
            episode: entry.episode,
            episodeTitle: entry.episodeTitle,
            resumeSeconds: entry.position,
            autoStart: true
        )
    }

    private func fraction(_ entry: WatchProgress) -> Double? {
        guard let duration = entry.duration, duration > 0 else { return nil }
        return entry.position / duration
    }

    private func shelf<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
        .focusSection()
    }

    private func horizontal<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 40) {
                content()
            }
            .padding(.vertical, 28)
            .padding(.trailing, 80)
        }
        .focusSection()
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var message = "Titel suchen. Quelle ist die TMDB-Suche, Sprache Deutsch, wie in Stremio-VMB."
    @State private var isSearching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Suche")
                    .font(.largeTitle.bold())
                HStack(spacing: 20) {
                    TextField("Film oder Serie", text: $query)
                        .frame(width: 700)
                    Button("Suchen") {
                        Task { await search() }
                    }
                    .disabled(isSearching)
                }
                .focusSection()
                if isSearching {
                    ProgressView("Suche…")
                } else if results.isEmpty {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .focusable()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 28)], alignment: .leading, spacing: 28) {
                        ForEach(results) { item in
                            MediaLink(item: item, subtitle: item.yearText, progress: nil)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 48)
            .padding(.bottom, 200)
        }
        .background(Color.black)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard model.hasTMDBKey else {
            message = "TMDB-API-Schlüssel fehlt. Bitte in den Einstellungen eintragen."
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await TMDBClient.search(apiKey: model.tmdbAPIKey, query: text)
            message = results.isEmpty ? "Nichts gefunden." : ""
        } catch {
            results = []
            message = error.localizedDescription
        }
    }
}
