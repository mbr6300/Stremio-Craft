import SwiftUI

/// Startseite: oben Infos zum fokussierten Titel (wie Stremio/Apple TV), darunter die Regale.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hero = HeroState()

    /// Solange nichts fokussiert ist: erster Titel der ersten nicht-leeren Reihe.
    private var fallback: MediaItem? {
        model.rows.first { !$0.items.isEmpty }?.items.first
    }

    var body: some View {
        Group {
            #if os(tvOS)
            tvLayout
            #else
            TouchHome()
            #endif
        }
        .environment(hero)
        .task(id: model.catalogSignature) {
            model.loadCatalogsIfNeeded()
        }
    }

    /// Fernbedienung: Kopf folgt dem fokussierten Titel, die gewählte Reihe steht fest darunter.
    private var tvLayout: some View {
        ZStack(alignment: .topLeading) {
            HeroBackdrop(fallback: fallback)
            VStack(alignment: .leading, spacing: Theme.s(0)) {
                // Kompakter Kopf: Infos links, Filter rechts in derselben Zone,
                // damit unten möglichst viel Platz für die Regale bleibt.
                HStack(alignment: .bottom, spacing: Theme.s(40)) {
                    HeroInfo(fallback: fallback)
                    Spacer(minLength: 0)
                    FilterPicker()
                }
                .frame(height: Theme.s(165), alignment: .bottom)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, Theme.headerGap)
                ShelvesList()
            }
            // Ganz oben rechts, auf Höhe des Menü-Knopfs links.
            HStack(spacing: Theme.s(16)) {
                RegionMenu()
                ActiveProfileBadge()
            }
                .padding(.trailing, Theme.pagePadding)
                .padding(.top, Theme.s(48))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .ignoresSafeArea(edges: .top)
                .tvFocusSection()
        }
    }
}

/// iPad (Touch): Banner mit Top-Titeln zum Durchwischen und Antippen, darunter Filter, Region
/// und Profil, dann normal scrollbare Reihen. Ohne Fokus gibt es keinen „mitlaufenden“ Kopf.
private struct TouchHome: View {
    @Environment(AppModel.self) private var model
    @AppStorage("homeFilter") private var filter: MediaFilter = .all

    private var featured: [MediaItem] {
        let source = model.rows.first { $0.items.contains { $0.backdropURL != nil } }?.items ?? []
        return Array(source.filter { $0.backdropURL != nil && filter.matches($0) }.prefix(8))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                if !featured.isEmpty {
                    TabView {
                        ForEach(featured) { item in
                            NavigationLink(value: AppRoute.detail(item)) {
                                FeaturedBanner(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .frame(height: 380)
                }
                HStack(spacing: 12) {
                    FilterPicker()
                    Spacer(minLength: 8)
                    RegionMenu()
                    ActiveProfileBadge()
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 8)
                ContinueShelf(filter: filter)
                ForEach(model.rows) { row in
                    CatalogShelf(row: row, filter: filter)
                }
                if model.rows.isEmpty {
                    EmptyHint(text: "Keine Reihen aktiv. In den Einstellungen unter „Listen & Reihen“ einschalten.")
                        .padding(.horizontal, Theme.pagePadding)
                }
            }
            .padding(.bottom, 40)
        }
        .background(Theme.background.ignoresSafeArea())
        .refreshable { await model.loadCatalogs() }
    }
}

/// Grosses Titelbild mit Infos für den iPad-Banner.
private struct FeaturedBanner: View {
    @Environment(AppModel.self) private var model
    var item: MediaItem
    @State private var imdb: IMDbInfo?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.backdropURL, maxPoints: 1280, placeholderSymbol: "film")
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .clipped()
            LinearGradient(colors: [.clear, Theme.background.opacity(0.75), Theme.background],
                           startPoint: .center, endPoint: .bottom)
            LinearGradient(colors: [Theme.background.opacity(0.7), .clear],
                           startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 34, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                MetaLine(item: item, imdb: imdb)
                Text(item.overview)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 40)
        }
        .frame(height: 380)
        .task(id: item.id) {
            imdb = await IMDbClient.shared.info(for: item, apiKey: model.tmdbAPIKey)
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
            // Feste Höhen für Titel, Infozeile und Beschreibung: der Block steht immer gleich,
            // egal wie lang Titel oder Beschreibung sind.
            VStack(alignment: .leading, spacing: Theme.s(6)) {
                Text(item.title)
                    .font(.system(size: Theme.s(44), weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: Theme.s(54), alignment: .bottomLeading)
                MetaLine(item: item, imdb: imdb)
                    .frame(height: Theme.s(30), alignment: .leading)
                Text(item.overview)
                    .font(.system(size: Theme.s(21)))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .frame(maxWidth: Theme.s(1000), alignment: .topLeading)
                    .frame(height: Theme.s(56), alignment: .topLeading)
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
                .font(.system(size: Theme.s(44), weight: .heavy))
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
        .frame(width: Theme.s(460))
        .tvFocusSection()
    }
}

/// Bubble mit aktueller Region; öffnet eine Auswahl, der Wechsel lädt die Reihen neu.
private struct RegionMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = Region.named(model.country)
        Menu {
            ForEach(Region.all) { region in
                Button {
                    model.setCountry(region.id)
                } label: {
                    if region.id == model.country {
                        Label("\(region.flag)  \(region.name)", systemImage: "checkmark")
                    } else {
                        Text("\(region.flag)  \(region.name)")
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.s(10)) {
                // Das Menü-Label auf iPadOS zeigt Flaggen-Emojis nicht an (nur „?“), daher dort ein Globus.
                if Platform.isTV {
                    Text(current.flag)
                } else {
                    Image(systemName: "globe")
                }
                Text(current.id)
                Image(systemName: "chevron.down")
                    .font(.system(size: Theme.s(18), weight: .bold))
            }
            .frame(height: Theme.pillContentHeight)
        }
        .buttonStyle(PillButtonStyle())
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
            VStack(alignment: .leading, spacing: Theme.s(4)) {
                Text(row.title)
                    .font(.system(size: Theme.s(30), weight: .bold))
                EmptyHint(text: message, symbol: "exclamationmark.triangle")
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.s(24))
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
    @Environment(\.openRoute) private var openRoute
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
            // Klick setzt direkt fort; hier geht's stattdessen zur Detailseite (Folgen, Infos, andere Streams).
            Button {
                openRoute(.detail(entry.media))
            } label: {
                Label("Details anzeigen", systemImage: "info.circle")
            }
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
