import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    var item: MediaItem

    @State private var detail: TitleDetail?
    @State private var episodes: [EpisodeInfo] = []
    @State private var selectedSeason: Int?
    @State private var status: String?
    @State private var loadingEpisodes = false

    private var shown: MediaItem { detail?.media ?? item }
    private var saved: WatchProgress? { model.progress(for: shown) }
    private var isSeries: Bool { shown.normalizedType == "tv" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 220)
                if isSeries {
                    seasonBar
                    episodeShelf
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .background(BackdropLayer(url: shown.backdropURL))
        .task { await load() }
    }

    // MARK: - Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(shown.title)
                .font(.system(size: 64, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(metaText)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(shown.overview.isEmpty ? "Keine Beschreibung." : shown.overview)
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(5)
                .frame(maxWidth: 1050, alignment: .leading)
            if let status {
                Text(status)
                    .font(.system(size: 20))
                    .foregroundStyle(.yellow)
            }
            actions
                .padding(.top, 12)
                .focusSection()
        }
    }

    private var metaText: String {
        var parts = [shown.metaText]
        if let runtime = detail?.runtime, runtime > 0 { parts.append("\(runtime) Min.") }
        if let genres = detail?.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    private var actions: some View {
        HStack(spacing: 24) {
            if let primary = primaryRequest {
                NavigationLink(value: AppRoute.play(primary.request)) {
                    Label(primary.label, systemImage: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)

                NavigationLink(value: AppRoute.play(withAutoStart(primary.request, false))) {
                    Label("Streams", systemImage: "list.bullet")
                }
            }
            if !isSeries, let saved, saved.position >= 15 {
                NavigationLink(value: AppRoute.play(movieRequest(resume: 0))) {
                    Label("Von vorne", systemImage: "arrow.counterclockwise")
                }
            }
            Button {
                model.toggleFavorite(shown)
            } label: {
                Image(systemName: model.isFavorite(shown) ? "heart.fill" : "heart")
                    .foregroundStyle(model.isFavorite(shown) ? .red : .white)
            }
        }
        .font(.system(size: 24, weight: .semibold))
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
        guard let first = episodes.first else { return nil }
        return ("Abspielen · \(first.label)", episodeRequest(first))
    }

    // MARK: - Staffeln & Folgen

    private var seasonBar: some View {
        let seasons = detail?.seasons ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(seasons) { season in
                    Button {
                        guard selectedSeason != season.seasonNumber else { return }
                        selectedSeason = season.seasonNumber
                        Task { await loadEpisodes(season.seasonNumber) }
                    } label: {
                        Text(season.name)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(selectedSeason == season.seasonNumber ? Theme.accent : .white)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .focusSection()
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
                        LazyHStack(alignment: .top, spacing: 40) {
                            ForEach(episodes) { episode in
                                NavigationLink(value: AppRoute.play(episodeRequest(episode))) {
                                    EpisodeCard(episode: episode, progress: episodeProgress(episode))
                                }
                                .buttonStyle(PosterButtonStyle())
                                .id(episode.id)
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                    .onAppear {
                        if let saved, saved.season == selectedSeason, let episode = saved.episode {
                            proxy.scrollTo("\(saved.season ?? 0)-\(episode)", anchor: .leading)
                        }
                    }
                }
                .focusSection()
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
            if selectedSeason == season { episodes = loaded }
        } catch {
            episodes = []
            status = error.localizedDescription
        }
    }
}

private struct EpisodeCard: View {
    var episode: EpisodeInfo
    var progress: Double?
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PosterArtwork(url: episode.stillURL, size: Theme.stillSize, progress: progress, symbol: "tv")
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episodeNumber). \(episode.name)")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Text(episode.overview.isEmpty ? episode.label : episode.overview)
                    .font(.system(size: 18))
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
