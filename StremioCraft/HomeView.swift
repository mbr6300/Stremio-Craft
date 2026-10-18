import SwiftUI

/// Startseite: oben Infos zum fokussierten Titel (wie Stremio/Apple TV), darunter die Regale.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hero = HeroState()

    var body: some View {
        ZStack(alignment: .topLeading) {
            HeroBackdrop(fallback: model.rows.first?.items.first)
            VStack(alignment: .leading, spacing: 0) {
                // Kompakter Kopf: Infos links, Filter rechts in derselben Zone,
                // damit unten möglichst viel Platz für die Regale bleibt.
                HStack(alignment: .bottom, spacing: 40) {
                    HeroInfo(fallback: model.rows.first?.items.first)
                    Spacer(minLength: 0)
                    FilterPicker()
                }
                .frame(height: 165, alignment: .bottom)
                .padding(.horizontal, Theme.pagePadding)
                ShelvesList()
            }
        }
        .environment(hero)
        .task(id: model.catalogSignature) {
            model.loadCatalogsIfNeeded()
        }
    }
}

struct HeroBackdrop: View {
    var fallback: MediaItem?
    @Environment(HeroState.self) private var hero
    @State private var shown: URL?

    var body: some View {
        BackdropLayer(url: shown)
            .task(id: (hero.item ?? fallback)?.id) {
                guard let url = (hero.item ?? fallback)?.backdropURL else { return }
                // Kurz warten, damit schnelles Durchscrollen nicht jedes Bild lädt;
                // danach vorladen und erst mit fertigem Bild überblenden.
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                _ = await ImagePipeline.shared.image(url, maxPixel: BackdropLayer.maxPixel)
                guard !Task.isCancelled else { return }
                shown = url
            }
    }
}

struct HeroInfo: View {
    var fallback: MediaItem?
    var placeholder = "Stremio Craft"
    @Environment(HeroState.self) private var hero
    @Environment(AppModel.self) private var model
    @State private var imdb: IMDbInfo?

    var body: some View {
        if let item = hero.item ?? fallback {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 44, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                MetaLine(item: item, imdb: imdb)
                    .frame(height: 30)
                Text(item.overview)
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            .id(item.id)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: item.id)
            .task(id: item.id) {
                imdb = nil
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let info = await IMDbClient.shared.info(for: item, apiKey: model.tmdbAPIKey)
                guard !Task.isCancelled else { return }
                imdb = info
            }
        } else {
            Text(placeholder)
                .font(.system(size: 44, weight: .heavy))
        }
    }
}

private struct FilterPicker: View {
    @AppStorage("homeFilter") private var filter: MediaFilter = .all

    var body: some View {
        Picker("Anzeigen", selection: $filter) {
            ForEach(MediaFilter.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 460)
        .focusSection()
    }
}

private struct ShelvesList: View {
    @Environment(AppModel.self) private var model
    @AppStorage("homeFilter") private var filter: MediaFilter = .all

    var body: some View {
        ShelvesScroll {
            ContinueShelf(filter: filter)
                .id("continue")
            ForEach(model.rows) { row in
                CatalogShelf(row: row, filter: filter)
            }
            if model.rows.isEmpty {
                EmptyHint(text: "Keine Reihen aktiv. In den Einstellungen unter „Listen & Reihen“ einschalten.")
                    .padding(.horizontal, Theme.pagePadding)
            }
        }
    }
}

private struct CatalogShelf: View {
    @Environment(AppModel.self) private var model
    var row: CatalogRow
    var filter: MediaFilter

    /// Plattform-Reihen öffnen die Plattform-Seite, alle anderen die vollständige Liste.
    private var allRoute: AppRoute {
        switch model.catalogs.first(where: { $0.id == row.id })?.source {
        case .provider(let id): return .provider(id)
        case .newOnProviders: return .discover(.newOnAllProviders)
        default: return .row(row.id)
        }
    }

    var body: some View {
        let items = filter == .all ? row.items : row.items.filter(filter.matches)
        if !items.isEmpty || (row.isLoading && row.items.isEmpty) {
            Shelf(title: row.title, shelfID: row.id, isLoading: row.isLoading && !items.isEmpty, seeAll: items.isEmpty ? nil : allRoute) {
                if items.isEmpty {
                    PlaceholderShelfItems()
                } else {
                    ForEach(items) { item in
                        MediaLink(item: item, listRoute: allRoute)
                    }
                }
            }
        } else if row.items.isEmpty, let message = row.message {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 30, weight: .bold))
                EmptyHint(text: message, symbol: "exclamationmark.triangle")
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 24)
        }
    }
}

private struct ContinueShelf: View {
    @Environment(AppModel.self) private var model
    var filter: MediaFilter

    var body: some View {
        let entries = model.continueWatching.filter { filter.matches($0.media) }
        if !entries.isEmpty {
            Shelf(title: "Weiterschauen", shelfID: "continue") {
                ForEach(entries) { entry in
                    ContinueCard(entry: entry)
                }
            }
        }
    }
}

struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    var entry: WatchProgress

    var body: some View {
        NavigationLink(value: AppRoute.play(entry.playRequest(autoStart: model.autoPlayBest))) {
            FocusReporter(item: entry.media) {
                PosterCard(
                    title: entry.title,
                    subtitle: entry.subtitle,
                    posterURL: entry.posterURL,
                    progress: entry.fraction
                )
            }
        }
        .buttonStyle(PosterButtonStyle())
        .contextMenu {
            Button(role: .destructive) {
                model.removeProgress(entry)
            } label: {
                Label("Aus Weiterschauen entfernen", systemImage: "xmark")
            }
        }
    }
}

extension WatchProgress {
    var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return position / duration
    }

    func playRequest(autoStart: Bool) -> PlaybackRequest {
        PlaybackRequest(
            media: media,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            resumeSeconds: position,
            autoStart: autoStart,
            durationHint: duration
        )
    }
}
