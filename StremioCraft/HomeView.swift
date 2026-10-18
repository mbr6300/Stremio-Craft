import SwiftUI

/// Startseite: oben Infos zum fokussierten Titel (wie Stremio/Apple TV), darunter die Regale.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hero = HeroState()

    var body: some View {
        ZStack(alignment: .topLeading) {
            HeroBackdrop(fallback: model.rows.first?.items.first)
            VStack(alignment: .leading, spacing: 0) {
                HeroInfo(fallback: model.rows.first?.items.first)
                    .frame(height: 330, alignment: .bottomLeading)
                    .padding(.horizontal, Theme.pagePadding)
                ShelvesList()
            }
        }
        .environment(hero)
        .task(id: model.catalogSignature) {
            await model.loadCatalogsIfNeeded()
        }
    }
}

private struct HeroBackdrop: View {
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

private struct HeroInfo: View {
    var fallback: MediaItem?
    @Environment(HeroState.self) private var hero
    @Environment(AppModel.self) private var model
    @State private var imdb: IMDbInfo?

    var body: some View {
        if let item = hero.item ?? fallback {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.title)
                    .font(.system(size: 54, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                MetaLine(item: item, imdb: imdb)
                    .frame(height: 30)
                Text(item.overview)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(3)
                    .frame(maxWidth: 1000, alignment: .leading)
            }
            .padding(.bottom, 10)
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
            Text("Stremio Craft")
                .font(.system(size: 54, weight: .heavy))
        }
    }
}

private struct ShelvesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ContinueShelf()
                ForEach(model.rows) { row in
                    CatalogShelf(row: row)
                }
                if model.rows.isEmpty {
                    EmptyHint(text: "Keine Reihen aktiv. In den Einstellungen unter „Listen & Reihen“ einschalten.")
                        .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.bottom, 80)
        }
        // Abschneiden statt `scrollClipDisabled`: sonst bleiben weggescrollte Regale
        // (z. B. „Weiterschauen“) über dem Hero-Text sichtbar. Oben weich ausblenden.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                Color.black
            }
            // nur oben abschneiden; seitlich und unten über den Rand hinaus sichtbar lassen
            .padding(.horizontal, -400)
            .padding(.bottom, -400)
        }
    }
}

private struct CatalogShelf: View, Equatable {
    var row: CatalogRow

    var body: some View {
        if !row.items.isEmpty || row.isLoading {
            Shelf(title: row.title, isLoading: row.isLoading && !row.items.isEmpty) {
                if row.items.isEmpty {
                    PlaceholderShelfItems()
                } else {
                    ForEach(row.items) { item in
                        MediaLink(item: item)
                    }
                }
            }
        } else if let message = row.message {
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

    var body: some View {
        if !model.continueWatching.isEmpty {
            Shelf(title: "Weiterschauen") {
                ForEach(model.continueWatching) { entry in
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
