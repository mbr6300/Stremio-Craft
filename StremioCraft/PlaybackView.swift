import AVKit
import Combine
import SwiftUI
import UIKit

struct PlaybackView: View {
    @Environment(AppModel.self) private var model
    var request: PlaybackRequest

    @State private var streams: [StreamCandidate] = []
    @State private var status = "Streams werden bei Torrentio gesucht…"
    @State private var banner: String?
    @State private var playerURL: URL?
    @State private var isResolving = false
    @State private var didAutoStart = false

    var body: some View {
        Group {
            if let playerURL {
                PlayerScreen(
                    url: playerURL,
                    resume: request.resumeSeconds,
                    banner: banner
                ) { position, duration in
                    model.saveProgress(
                        media: request.media,
                        position: position,
                        duration: duration,
                        season: request.season,
                        episode: request.episode,
                        episodeTitle: request.episodeTitle
                    )
                }
            } else {
                streamList
            }
        }
        .background(Color.black)
        .task { await loadStreams() }
    }

    private var streamList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(request.media.title)
                    .font(.largeTitle.bold())
                if let episode = request.episode, let season = request.season {
                    Text(String(format: "S%02dE%02d %@", season, episode, request.episodeTitle ?? ""))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text(status)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if isResolving {
                    ProgressView()
                }
                if let banner {
                    Text(banner)
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                ForEach(streams) { stream in
                    Button {
                        Task { await play(stream) }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stream.quality)
                                .font(.headline)
                            Text("\(stream.size)  ·  \(stream.directURL == nil ? "Real-Debrid" : "Direkter Link")")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(stream.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(12)
                    }
                    .buttonStyle(.card)
                    .disabled(isResolving)
                }
            }
            .padding(48)
        }
    }

    private func loadStreams() async {
        guard model.hasTMDBKey else {
            status = "TMDB-API-Schlüssel fehlt. Ohne ihn gibt es keine IMDb-ID für Torrentio."
            return
        }
        let token = KeychainStore.loadToken()
        if token == nil {
            status = "Real-Debrid API-Token fehlt. Bitte in den Einstellungen eintragen. Torrentio liefert dann Info-Hashes, die lokal freigeschaltet werden."
        }
        do {
            let imdb = try await TMDBClient.imdbId(
                apiKey: model.tmdbAPIKey,
                tmdbId: request.media.tmdbId,
                mediaType: request.media.normalizedType
            )
            guard let imdb, imdb.hasPrefix("tt") else {
                status = "Keine IMDb-ID bei TMDB. Torrentio kann diesen Titel nicht auflösen."
                return
            }
            let found = try await TorrentioClient.streams(
                options: model.torrentio,
                token: token,
                imdbId: imdb,
                mediaType: request.media.normalizedType,
                season: request.season,
                episode: request.episode
            )
            streams = found
            if found.isEmpty {
                status = "Keine Streams. Torrentio hat für diesen Titel nichts geliefert."
                return
            }
            status = "\(found.count) Streams. Beste Qualität zuerst, wie in Stremio-VMB."
            if request.autoStart, !didAutoStart, let best = found.first {
                didAutoStart = true
                await play(best)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func play(_ stream: StreamCandidate) async {
        isResolving = true
        defer { isResolving = false }
        do {
            let url: URL
            if let direct = stream.directURL {
                url = direct
            } else {
                guard let token = KeychainStore.loadToken() else {
                    banner = "Real-Debrid API-Token fehlt. Bitte in den Einstellungen eintragen."
                    return
                }
                guard let hash = stream.infoHash else {
                    banner = "Dieser Stream hat keine abspielbare Adresse."
                    return
                }
                status = "Real-Debrid schaltet \(stream.quality) frei…"
                url = try await RealDebridClient.resolve(token: token, infoHash: hash, fileIndex: stream.fileIndex)
            }
            handoff(url)
        } catch {
            banner = error.localizedDescription
            status = "Stream konnte nicht gestartet werden."
        }
    }

    private func handoff(_ url: URL) {
        let title = playbackTitle
        if let infuse = Self.infuseURL(stream: url, title: title), UIApplication.shared.canOpenURL(infuse) {
            UIApplication.shared.open(infuse, options: [:]) { success in
                Task { @MainActor in
                    if success {
                        banner = "Wiedergabe an Infuse übergeben."
                        model.saveProgress(
                            media: request.media,
                            position: max(request.resumeSeconds, 15),
                            duration: nil,
                            season: request.season,
                            episode: request.episode,
                            episodeTitle: request.episodeTitle
                        )
                    } else {
                        fallback(url)
                    }
                }
            }
            return
        }
        fallback(url)
    }

    private func fallback(_ url: URL) {
        if Self.needsInfuse(url) {
            banner = "Dieses Format braucht Infuse. Infuse ist nicht installiert oder die Adresse konnte nicht geöffnet werden."
            playerURL = nil
            return
        }
        banner = "Infuse ist nicht verfügbar. Wiedergabe in der App."
        playerURL = url
    }

    private var playbackTitle: String {
        if let season = request.season, let episode = request.episode {
            return "\(request.media.title) \(String(format: "S%02dE%02d", season, episode))"
        }
        return request.media.title
    }

    static func infuseURL(stream: URL, title: String) -> URL? {
        var components = URLComponents()
        components.scheme = "infuse"
        components.host = "x-callback-url"
        components.path = "/play"
        components.queryItems = [
            URLQueryItem(name: "url", value: stream.absoluteString),
            URLQueryItem(name: "title", value: title)
        ]
        return components.url
    }

    static func needsInfuse(_ url: URL) -> Bool {
        let haystack = url.absoluteString.lowercased()
        return [".mkv", ".avi", ".wmv", ".flv", ".m2ts", ".divx", ".rmvb"].contains { haystack.contains($0) }
    }
}

struct PlayerScreen: View {
    var url: URL
    var resume: Double
    var banner: String?
    var onProgress: (Double, Double) -> Void

    @StateObject private var controller = PlayerController()
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoPlayer(player: controller.player)
                .ignoresSafeArea()
            if let text = failure ?? banner {
                Text(text)
                    .font(.headline)
                    .padding(16)
                    .background(.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(36)
            }
        }
        .onAppear {
            controller.onProgress = onProgress
            controller.onFailure = { message in
                failure = "\(message) Dieses Format braucht vermutlich Infuse."
            }
            controller.load(url: url, resume: resume)
        }
        .onDisappear {
            controller.teardown()
        }
    }
}

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    var onProgress: ((Double, Double) -> Void)?
    var onFailure: ((String) -> Void)?
    private var observer: Any?
    private var statusCancellable: AnyCancellable?
    private var didSeek = false

    func load(url: URL, resume: Double) {
        let item = AVPlayerItem(url: url)
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == .failed {
                    self.onFailure?(item.error?.localizedDescription ?? "Wiedergabe fehlgeschlagen.")
                } else if status == .readyToPlay, !self.didSeek, resume > 1 {
                    self.didSeek = true
                    self.player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
            }
        player.replaceCurrentItem(with: item)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self else { return }
                let duration = self.player.currentItem?.duration.seconds ?? 0
                self.onProgress?(seconds, duration.isFinite ? duration : 0)
            }
        }
        player.play()
    }

    func teardown() {
        let duration = player.currentItem?.duration.seconds ?? 0
        onProgress?(player.currentTime().seconds, duration.isFinite ? duration : 0)
        if let observer {
            player.removeTimeObserver(observer)
            self.observer = nil
        }
        statusCancellable = nil
        player.pause()
    }
}
