import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) private var model
    var item: MediaItem

    @State private var detail: TitleDetail?
    @State private var episodes: [EpisodeInfo] = []
    @State private var selectedSeason = 1
    @State private var selectedEpisode: EpisodeInfo?
    @State private var status = "Details werden geladen…"
    @State private var failed = false

    private var shown: MediaItem { detail?.media ?? item }
    private var saved: WatchProgress? { model.progress(for: shown) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 40) {
                    PosterCard(title: shown.title, subtitle: nil, posterURL: shown.posterURL, progress: nil, showsCaption: false)
                        .frame(width: 250)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(shown.title)
                            .font(.system(size: 52, weight: .bold))
                            .lineLimit(3)
                        metaLine
                        Text(shown.overview.isEmpty ? "Keine Beschreibung." : shown.overview)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: 1100, alignment: .leading)
                        actions
                        if failed {
                            Text(status)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if shown.normalizedType == "tv" {
                    seasonPicker
                    episodeList
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 48)
            .padding(.bottom, 200)
        }
        .background(backdrop)
        .task { await load() }
        .onChange(of: selectedSeason) { _, season in
            Task { await loadEpisodes(season) }
        }
    }

    private var backdrop: some View {
        ZStack {
            Color.black
            if let url = shown.backdropURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill().opacity(0.28)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    private var metaLine: some View {
        let genres = detail?.genres.joined(separator: ", ") ?? ""
        let runtime = detail?.runtime.map { "\($0) Min." } ?? ""
        let rating = shown.rating.map { String(format: "★ %.1f", $0) } ?? ""
        let parts = [shown.yearText, rating, runtime, genres].filter { !$0.isEmpty }
        return Text(parts.joined(separator: "  ·  "))
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 20) {
            if shown.normalizedType == "movie" {
                NavigationLink(value: playMovie(resume: false)) {
                    Label("Abspielen", systemImage: "play.fill")
                }
                if let saved {
                    NavigationLink(value: playMovie(resume: true, progress: saved)) {
                        Label("Fortsetzen \(WatchProgress.clock(saved.position))", systemImage: "gobackward")
                    }
                }
            } else if let episode = selectedEpisode ?? resumeEpisode {
                NavigationLink(value: playEpisode(episode, resume: resumeMatches(episode))) {
                    Label(resumeMatches(episode) ? "Fortsetzen \(episode.label)" : "Abspielen \(episode.label)", systemImage: "play.fill")
                }
            }
            Button(model.isFavorite(shown) ? "Favorit entfernen" : "Zu Favoriten") {
                model.toggleFavorite(shown)
            }
        }
        .font(.title3)
    }

    private var resumeEpisode: EpisodeInfo? {
        guard let saved, let season = saved.season, let episode = saved.episode else { return nil }
        return EpisodeInfo(
            seasonNumber: season,
            episodeNumber: episode,
            name: saved.episodeTitle ?? "Folge \(episode)",
            overview: "",
            stillURL: nil
        )
    }

    private var seasonPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Staffeln")
                .font(.title2.weight(.semibold))
            if (detail?.seasons ?? []).isEmpty {
                Text(status)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(detail?.seasons ?? []) { season in
                            Button(season.name) {
                                selectedSeason = season.seasonNumber
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedSeason == season.seasonNumber ? .red : .gray)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var episodeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folgen")
                .font(.title2.weight(.semibold))
            if episodes.isEmpty {
                Text("Keine Folgen geladen.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(episodes) { episode in
                    Button {
                        selectedEpisode = episode
                    } label: {
                        HStack(alignment: .top, spacing: 16) {
                            Text(episode.label)
                                .font(.headline.monospacedDigit())
                                .frame(width: 120, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(episode.name)
                                    .font(.headline)
                                if !episode.overview.isEmpty {
                                    Text(episode.overview)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if selectedEpisode?.id == episode.id {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: 1200, alignment: .leading)
                    }
                    .buttonStyle(.card)
                }
            }
        }
    }

    private func playMovie(resume: Bool, progress: WatchProgress? = nil) -> PlaybackRequest {
        PlaybackRequest(
            media: shown,
            season: nil,
            episode: nil,
            episodeTitle: nil,
            resumeSeconds: resume ? (progress?.position ?? 0) : 0,
            autoStart: true
        )
    }

    private func playEpisode(_ episode: EpisodeInfo, resume: Bool) -> PlaybackRequest {
        PlaybackRequest(
            media: shown,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            episodeTitle: episode.name,
            resumeSeconds: resume ? (saved?.position ?? 0) : 0,
            autoStart: true
        )
    }

    private func resumeMatches(_ episode: EpisodeInfo) -> Bool {
        saved?.season == episode.seasonNumber && saved?.episode == episode.episodeNumber && (saved?.position ?? 0) >= 15
    }

    private func load() async {
        guard model.hasTMDBKey else {
            status = "TMDB-API-Schlüssel fehlt. Details und Folgen brauchen denselben Schlüssel wie Stremio-VMB."
            failed = true
            return
        }
        do {
            let loaded = try await TMDBClient.fetchDetail(apiKey: model.tmdbAPIKey, item: item)
            detail = loaded
            failed = false
            if loaded.media.normalizedType == "tv" {
                let season = saved?.season ?? loaded.seasons.first?.seasonNumber ?? 1
                selectedSeason = season
                await loadEpisodes(season)
                if let saved, let episode = saved.episode {
                    selectedEpisode = episodes.first { $0.episodeNumber == episode } ?? resumeEpisode
                } else {
                    selectedEpisode = episodes.first
                }
            }
        } catch {
            status = error.localizedDescription
            failed = true
        }
    }

    private func loadEpisodes(_ season: Int) async {
        guard shown.normalizedType == "tv", model.hasTMDBKey else { return }
        do {
            episodes = try await TMDBClient.fetchEpisodes(apiKey: model.tmdbAPIKey, tmdbId: shown.tmdbId, season: season)
            if selectedEpisode?.seasonNumber != season {
                selectedEpisode = episodes.first
            }
        } catch {
            episodes = []
            status = error.localizedDescription
        }
    }
}


