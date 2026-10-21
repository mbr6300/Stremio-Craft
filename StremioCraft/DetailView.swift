import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    var item: MediaItem

    @State private var detail: TitleDetail?
    @State private var episodes: [EpisodeInfo] = []
    @State private var selectedSeason: Int?
    @State private var status: String?
    @State private var loadingEpisodes = false
    /// Staffel der fokussierten Folge – die Reihe läuft über Staffelgrenzen hinweg weiter.
    @State private var highlightedSeason: Int?
    @State private var appendingSeason = false
    @State private var imdb: IMDbInfo?
    @State private var trailers: [Trailer] = []

    private var shown: MediaItem { detail?.media ?? item }
    private var saved: WatchProgress? { model.progress(for: shown) }
    private var isSeries: Bool { shown.normalizedType == "tv" }

    var body: some View {
        // Hintergrund fest hinter der ganzen Seite: als `.background` der ScrollView war er nur
        // so breit wie deren Inhalt, daneben blieb ein grauer Balken.
        ZStack {
            BackdropLayer(url: shown.backdropURL)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s(22)) {
                    header
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.top, Theme.s(90))
                    if isSeries {
                        seasonBar
                        episodeShelf
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.s(80))
            }
            .scrollClipDisabled()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s(12)) {
            Text(shown.title)
                .font(.system(size: Theme.s(54), weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            MetaLine(item: shown, imdb: imdb, extra: extraMeta)
                .frame(height: Theme.s(32))
            Text(shown.overview.isEmpty ? "Keine Beschreibung." : shown.overview)
                .font(.system(size: Theme.s(22)))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)
                .frame(maxWidth: Theme.s(1050), alignment: .leading)
            credits
            if let status {
                Text(status)
                    .font(.system(size: Theme.s(20)))
                    .foregroundStyle(.yellow)
            }
            actions
                .padding(.top, Theme.s(6))
                .tvFocusSection()
        }
    }

    private var extraMeta: [String] {
        var parts: [String] = []
        if let runtime = detail?.runtime ?? imdb?.runtimeMinutes, runtime > 0 { parts.append(Self.duration(runtime)) }
        if let genres = detail?.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts
    }

    @ViewBuilder
    private var credits: some View {
        if let imdb, !(imdb.directors.isEmpty && imdb.cast.isEmpty) {
            VStack(alignment: .leading, spacing: Theme.s(6)) {
                if !imdb.directors.isEmpty {
                    creditLine(isSeries ? "Idee" : "Regie", imdb.directors.prefix(2).joined(separator: ", "))
                }
                if !imdb.cast.isEmpty {
                    creditLine("Mit", imdb.cast.joined(separator: ", "))
                }
            }
            .font(.system(size: Theme.s(20)))
            .frame(maxWidth: Theme.s(1050), alignment: .leading)
        }
    }

    private func creditLine(_ label: String, _ names: String) -> some View {
        (Text("\(label)  ").foregroundStyle(.white.opacity(0.45)) + Text(names).foregroundStyle(.white.opacity(0.85)))
            .lineLimit(1)
    }

    private static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) Std. \(minutes % 60) Min." : "\(minutes) Min."
    }

    private var actions: some View {
        HStack(spacing: Theme.s(24)) {
            if let primary = primaryRequest {
                NavigationLink(value: AppRoute.play(primary.request)) {
                    Label(primary.label, systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(prominent: true))

                NavigationLink(value: AppRoute.play(withAutoStart(primary.request, false))) {
                    Label("Streams wählen", systemImage: "list.bullet")
                }
                .buttonStyle(PillButtonStyle())
            }
            if !trailers.isEmpty {
                TrailerButton(trailers: trailers)
            }
            if !isSeries, let saved, saved.position >= 15 {
                NavigationLink(value: AppRoute.play(movieRequest(resume: 0))) {
                    Label("Von vorne", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(PillButtonStyle())
            }
            Button {
                model.toggleFavorite(shown)
            } label: {
                Label(
                    model.isFavorite(shown) ? "In meiner Liste" : "Meine Liste",
                    systemImage: model.isFavorite(shown) ? "checkmark" : "plus"
                )
            }
            .buttonStyle(PillButtonStyle(selected: model.isFavorite(shown)))
            Button {
                model.toggleLoved(shown)
            } label: {
                Image(systemName: model.isLoved(shown) ? "heart.fill" : "heart")
                    .foregroundStyle(model.isLoved(shown) ? Color(red: 0.93, green: 0.2, blue: 0.33) : .white)
                    .frame(height: Theme.s(30))
            }
            .buttonStyle(PillButtonStyle())
            if !isSeries {
                let watched = model.isWatched(shown)
                Button {
                    model.setWatched([AppModel.movieKey(shown.tmdbId)], !watched)
                    if !watched { model.clearProgressIfWatched(shown) }
                } label: {
                    Label(watched ? "Gesehen" : "Als gesehen markieren", systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(PillButtonStyle(selected: watched))
            }
        }
    }

    private var primaryRequest: (label: String, request: PlaybackRequest)? {
        if !isSeries {
            if let saved, saved.position >= 15 {
                return ("Fortsetzen · \(WatchProgress.clock(saved.position))", movieRequest(resume: saved.position))
            }
            return ("Abspielen", movieRequest(resume: 0))
        }
        if let saved, let season = saved.season, let episode = saved.episode {
            let info = episodes.first { $0.seasonNumber == season && $0.episodeNumber == episode }
            let request = PlaybackRequest(
                media: shown,
                season: season,
                episode: episode,
                episodeTitle: saved.episodeTitle,
                resumeSeconds: saved.position,
                autoStart: model.autoPlayBest,
                durationHint: info?.runtime.map { Double($0 * 60) } ?? saved.duration
            )
            return ("Fortsetzen · \(String(format: "S%02dE%02d", season, episode))", request)
        }
        // Ohne laufenden Fortschritt: erste noch ungesehene Folge der Staffel.
        guard let next = episodes.first(where: { !model.isWatched($0, of: shown) }) ?? episodes.first else { return nil }
        return ("Abspielen · \(next.label)", episodeRequest(next))
    }

    // MARK: - Gesehen

    private func episodeKey(_ episode: EpisodeInfo) -> String {
        AppModel.episodeKey(shown.tmdbId, episode.seasonNumber, episode.episodeNumber)
    }

    /// Markiert die Folge – auf Wunsch auch alle früheren Staffeln und Folgen bis hierhin.
    private func markWatched(upTo episode: EpisodeInfo, includingPrevious: Bool) {
        var keys = [episodeKey(episode)]
        if includingPrevious {
            for number in 1..<max(episode.episodeNumber, 1) {
                keys.append(AppModel.episodeKey(shown.tmdbId, episode.seasonNumber, number))
            }
            for season in detail?.seasons ?? [] where season.seasonNumber < episode.seasonNumber {
                for number in stride(from: 1, through: season.episodeCount, by: 1) {
                    keys.append(AppModel.episodeKey(shown.tmdbId, season.seasonNumber, number))
                }
            }
        }
        let inContinueWatching = model.progress(for: shown) != nil
        model.setWatched(keys, true)
        model.clearProgressIfWatched(shown)
        // Läuft die Serie gerade, gleich die nächste Folge vormerken.
        if inContinueWatching {
            let series = shown
            Task { await model.queueNextEpisode(after: series, season: episode.seasonNumber, episode: episode.episodeNumber) }
        }
    }

    // MARK: - Staffeln & Folgen

    private var seasonBar: some View {
        let seasons = detail?.seasons ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s(18)) {
                ForEach(seasons) { season in
                    Button {
                        guard (highlightedSeason ?? selectedSeason) != season.seasonNumber
                                || episodes.first?.seasonNumber != season.seasonNumber else { return }
                        selectedSeason = season.seasonNumber
                        Task { await loadEpisodes(season.seasonNumber) }
                    } label: {
                        Text(season.name)
                    }
                    .buttonStyle(PillButtonStyle(selected: (highlightedSeason ?? selectedSeason) == season.seasonNumber))
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(8))
        }
        .scrollClipDisabled()
        .tvFocusSection()
    }

    private var episodeShelf: some View {
        Group {
            if loadingEpisodes && episodes.isEmpty {
                ProgressView().padding(.horizontal, Theme.pagePadding)
            } else if episodes.isEmpty {
                EmptyHint(text: "Keine Folgen geladen.", symbol: "tv")
                    .padding(.horizontal, Theme.pagePadding)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Theme.s(40)) {
                            ForEach(episodes) { episode in
                                let watched = model.isWatched(episode, of: shown)
                                NavigationLink(value: AppRoute.play(episodeRequest(episode))) {
                                    EpisodeCard(
                                        episode: episode,
                                        progress: episodeProgress(episode),
                                        watched: watched,
                                        startsSeason: startsAppendedSeason(episode)
                                    ) {
                                        if highlightedSeason != episode.seasonNumber {
                                            highlightedSeason = episode.seasonNumber
                                        }
                                    }
                                }
                                .buttonStyle(PosterButtonStyle())
                                .id(episode.id)
                                .onAppear {
                                    // Am Ende der geladenen Folgen die nächste Staffel anhängen.
                                    if episode.id == episodes.last?.id {
                                        Task { await appendNextSeason() }
                                    }
                                }
                                .contextMenu {
                                    if watched {
                                        Button {
                                            model.setWatched([episodeKey(episode)], false)
                                        } label: {
                                            Label("Als ungesehen markieren", systemImage: "eye.slash")
                                        }
                                    } else {
                                        Section("Als gesehen markieren") {
                                            Button {
                                                markWatched(upTo: episode, includingPrevious: false)
                                            } label: {
                                                Label("Nur diese Folge", systemImage: "checkmark.circle")
                                            }
                                            Button {
                                                markWatched(upTo: episode, includingPrevious: true)
                                            } label: {
                                                Label("Diese und alle vorherigen", systemImage: "checkmark.circle.fill")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.vertical, Theme.s(18))
                    }
                    .scrollClipDisabled()
                    .onAppear {
                        if let saved, saved.season == selectedSeason, let episode = saved.episode {
                            proxy.scrollTo("\(saved.season ?? 0)-\(episode)", anchor: .leading)
                        }
                    }
                }
                .tvFocusSection()
            }
        }
    }

    private func episodeProgress(_ episode: EpisodeInfo) -> Double? {
        guard let saved, saved.season == episode.seasonNumber, saved.episode == episode.episodeNumber else { return nil }
        return saved.fraction ?? 0.05
    }

    // MARK: - Anfragen

    private func movieRequest(resume: Double) -> PlaybackRequest {
        PlaybackRequest(
            media: shown,
            season: nil,
            episode: nil,
            episodeTitle: nil,
            resumeSeconds: resume,
            autoStart: model.autoPlayBest,
            durationHint: detail?.runtime.map { Double($0 * 60) }
        )
    }

    private func episodeRequest(_ episode: EpisodeInfo) -> PlaybackRequest {
        let resume = saved.flatMap { saved -> Double? in
            saved.season == episode.seasonNumber && saved.episode == episode.episodeNumber ? saved.position : nil
        } ?? 0
        return PlaybackRequest(
            media: shown,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            episodeTitle: episode.name,
            resumeSeconds: resume,
            autoStart: model.autoPlayBest,
            durationHint: (episode.runtime ?? detail?.runtime).map { Double($0 * 60) }
        )
    }

    private func withAutoStart(_ request: PlaybackRequest, _ autoStart: Bool) -> PlaybackRequest {
        var copy = request
        copy.autoStart = autoStart
        return copy
    }

    // MARK: - Laden

    private func load() async {
        guard detail == nil else { return }
        guard model.hasTMDBKey else {
            status = "TMDB-API-Schlüssel fehlt."
            return
        }
        do {
            let loaded = try await TMDBClient.fetchDetail(apiKey: model.tmdbAPIKey, item: item)
            detail = loaded
            status = nil
            if let id = loaded.media.imdbId {
                Task { imdb = await IMDbClient.shared.info(imdbId: id) }
            }
            let key = model.tmdbAPIKey
            Task {
                trailers = (try? await TMDBClient.fetchTrailers(apiKey: key, tmdbId: item.tmdbId, mediaType: item.normalizedType)) ?? []
            }
            if loaded.media.normalizedType == "tv" {
                let season = saved?.season ?? loaded.seasons.first?.seasonNumber ?? 1
                selectedSeason = season
                await loadEpisodes(season)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func loadEpisodes(_ season: Int) async {
        guard model.hasTMDBKey else { return }
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        do {
            let loaded = try await TMDBClient.fetchEpisodes(apiKey: model.tmdbAPIKey, tmdbId: shown.tmdbId, season: season)
            if selectedSeason == season {
                episodes = loaded
                highlightedSeason = season
            }
        } catch {
            episodes = []
            status = error.localizedDescription
        }
    }

    /// Hängt die nächste Staffel an, damit man mit → einfach über das Staffelende weiterblättert.
    private func appendNextSeason() async {
        guard !appendingSeason, model.hasTMDBKey, let last = episodes.last,
              let next = (detail?.seasons ?? []).first(where: { $0.seasonNumber > last.seasonNumber }) else { return }
        appendingSeason = true
        defer { appendingSeason = false }
        guard let loaded = try? await TMDBClient.fetchEpisodes(apiKey: model.tmdbAPIKey, tmdbId: shown.tmdbId, season: next.seasonNumber),
              episodes.last?.id == last.id else { return } // Liste wurde inzwischen ersetzt
        episodes += loaded
    }

    /// Erste Folge einer angehängten Staffel – bekommt eine „Staffel N“-Marke.
    private func startsAppendedSeason(_ episode: EpisodeInfo) -> Bool {
        guard episode.seasonNumber != episodes.first?.seasonNumber else { return false }
        return episodes.first { $0.seasonNumber == episode.seasonNumber }?.id == episode.id
    }
}

private struct EpisodeCard: View {
    var episode: EpisodeInfo
    var progress: Double?
    var watched = false
    var startsSeason = false
    var onFocus: () -> Void = {}
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(10)) {
            PosterArtwork(url: episode.stillURL, size: Theme.stillSize, progress: progress, symbol: "tv", watched: watched)
                // Gesehene Folgen leicht abdunkeln, im Fokus wieder voll.
                .opacity(watched && !isFocused ? 0.6 : 1)
                .overlay(alignment: .topLeading) {
                    if startsSeason {
                        Text("Staffel \(episode.seasonNumber)")
                            .font(.system(size: Theme.s(18), weight: .heavy))
                            .padding(.horizontal, Theme.s(12))
                            .padding(.vertical, Theme.s(5))
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(Theme.s(10))
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if focused { onFocus() }
                }
            VStack(alignment: .leading, spacing: Theme.s(4)) {
                Text("\(episode.episodeNumber). \(episode.name)")
                    .font(.system(size: Theme.s(22), weight: .semibold))
                    .lineLimit(1)
                if let date = episode.airDateText {
                    // Kommende Folgen orange („ab …“), bereits erschienene dezent grau.
                    Label(episode.isAired ? date : "Ab \(date)", systemImage: episode.isAired ? "calendar" : "calendar.badge.clock")
                        .font(.system(size: Theme.s(17), weight: episode.isAired ? .regular : .semibold))
                        .foregroundStyle(episode.isAired ? Color.white.opacity(0.55) : Color.orange)
                        .lineLimit(1)
                }
                Text(episode.overview.isEmpty ? episode.label : episode.overview)
                    .font(.system(size: Theme.s(18)))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            .frame(width: Theme.stillSize.width, alignment: .leading)
            .foregroundStyle(isFocused ? .white : .white.opacity(0.75))
            .offset(y: isFocused ? 14 : 0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
    }
}
