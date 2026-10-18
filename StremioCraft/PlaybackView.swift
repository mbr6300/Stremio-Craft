import AVKit
import Combine
import SwiftUI
import UIKit

struct PlaybackView: View {
    @Environment(AppModel.self) private var model
    var request: PlaybackRequest

    @State private var streams: [StreamCandidate] = []
    @State private var status = "Streams werden gesucht…"
    @State private var banner: String?
    @State private var playerURL: URL?
    @State private var resolvingId: String?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var lastResolved: (stream: StreamCandidate, url: URL)?

    var body: some View {
        Group {
            if let playerURL {
                PlayerScreen(url: playerURL, resume: request.resumeSeconds) { position, duration in
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
                ZStack {
                    BackdropLayer(url: request.media.backdropURL)
                    streamList
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            guard !didLoad else { return }
            didLoad = true
            await loadStreams()
        }
    }

    // MARK: - Ansicht

    private var streamList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s(18)) {
                Text(request.media.title)
                    .font(.system(size: Theme.s(56), weight: .heavy))
                    .lineLimit(1)
                if let label = request.episodeLabel {
                    Text("\(label)  ·  \(request.episodeTitle ?? "")")
                        .font(.system(size: Theme.s(26), weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                HStack(spacing: Theme.s(14)) {
                    if isLoading || resolvingId != nil {
                        ProgressView()
                    }
                    Text(status)
                        .font(.system(size: Theme.s(22)))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let notice = banner ?? model.playbackNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: Theme.s(22), weight: .semibold))
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: Theme.s(1300), alignment: .leading)
                }
                if let lastResolved, model.player != .builtIn {
                    HStack(spacing: Theme.s(20)) {
                        Button("Erneut an \(model.player.label)") { hand(lastResolved.url, stream: lastResolved.stream, to: model.player) }
                            .buttonStyle(PillButtonStyle(prominent: true))
                        ForEach(PlayerChoice.allCases.filter { $0 != model.player }) { other in
                            Button(other == .builtIn ? "Integrierter Player" : "In \(other.label)") {
                                hand(lastResolved.url, stream: lastResolved.stream, to: other)
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                    .tvFocusSection()
                }
                LazyVStack(alignment: .leading, spacing: Theme.s(18)) {
                    ForEach(streams) { stream in
                        Button {
                            Task { await play(stream, with: model.player) }
                        } label: {
                            StreamRow(stream: stream, isResolving: resolvingId == stream.id)
                        }
                        .cardButtonStyle()
                        .disabled(resolvingId != nil)
                        .contextMenu {
                            Button("In Infuse öffnen") { Task { await play(stream, with: .infuse) } }
                            Button("In VLC öffnen") { Task { await play(stream, with: .vlc) } }
                            Button("Im integrierten Player") { Task { await play(stream, with: .builtIn) } }
                        }
                    }
                }
                .padding(.top, Theme.s(12))
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, Theme.s(60))
        }
    }

    // MARK: - Streams

    private func loadStreams() async {
        defer { isLoading = false }
        guard model.hasTMDBKey else {
            status = "TMDB-API-Schlüssel fehlt. Ohne ihn gibt es keine IMDb-ID für Torrentio."
            return
        }
        let token = KeychainStore.loadToken()
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
            guard !found.isEmpty else {
                status = "Keine Streams gefunden."
                return
            }
            let cached = found.filter(\.isCached).count
            status = cached > 0 ? "\(found.count) Streams · \(cached) sofort verfügbar ⚡" : "\(found.count) Streams"
            if token == nil {
                banner = "Kein Real-Debrid-Token hinterlegt – bitte in den Einstellungen eintragen."
            }
            guard request.autoStart, token != nil else { return }
            // Nur automatisch starten, wenn der Stream sofort verfügbar ist. Ohne RD-Markierung
            // (Info-Hash-Modus) den besten nehmen.
            let anyMarked = found.contains { $0.directURL != nil }
            if let best = anyMarked ? found.first(where: \.isCached) : found.first {
                await play(best, with: model.player)
            } else {
                status += " · keiner im Real-Debrid-Cache, bitte wählen"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func play(_ stream: StreamCandidate, with choice: PlayerChoice) async {
        resolvingId = stream.id
        banner = nil
        defer { resolvingId = nil }
        do {
            let url: URL
            if let direct = stream.directURL {
                url = direct
            } else {
                guard let token = KeychainStore.loadToken() else {
                    banner = "Real-Debrid-Token fehlt. Bitte in den Einstellungen eintragen."
                    return
                }
                guard let hash = stream.infoHash else {
                    banner = "Dieser Stream hat keine abspielbare Adresse."
                    return
                }
                status = "Real-Debrid schaltet \(stream.quality) frei…"
                url = try await RealDebridClient.resolve(token: token, infoHash: hash, fileIndex: stream.fileIndex)
            }
            lastResolved = (stream, url)
            hand(url, stream: stream, to: choice)
        } catch {
            banner = error.localizedDescription
            status = "Stream konnte nicht gestartet werden."
        }
    }

    // MARK: - Übergabe

    private func hand(_ url: URL, stream: StreamCandidate, to choice: PlayerChoice) {
        switch choice {
        case .infuse: openInfuse(url, stream: stream)
        case .vlc: openVLC(url)
        case .builtIn: startBuiltIn(url)
        }
    }

    private func openInfuse(_ url: URL, stream: StreamCandidate) {
        guard let infuse = Self.infuseURL(stream: url, filename: infuseFileName(stream, url: url), position: request.resumeSeconds) else {
            banner = "Infuse-Adresse konnte nicht gebaut werden."
            return
        }
        model.beginInfuseSession(request)
        openExternal(infuse, app: "Infuse", missingHint: "Ist Infuse (ab Version 8.4.7) installiert?")
    }

    /// VLC für tvOS: `vlc-x-callback://x-callback-url/stream?url=…` spielt direkt ab.
    /// VLC kann weder an einer Position starten noch die Position zurückmelden.
    private func openVLC(_ url: URL) {
        guard let vlc = Self.vlcURL(stream: url) else {
            banner = "VLC-Adresse konnte nicht gebaut werden."
            return
        }
        if request.resumeSeconds >= 15 {
            banner = "VLC startet von vorne – zum Fortsetzen bei \(WatchProgress.clock(request.resumeSeconds)) vorspulen."
        }
        openExternal(vlc, app: "VLC", missingHint: "Ist VLC installiert?")
    }

    private func openExternal(_ target: URL, app: String, missingHint: String) {
        status = "Übergabe an \(app)…"
        UIApplication.shared.open(target, options: [:]) { success in
            Task { @MainActor in
                if success {
                    status = "In \(app) geöffnet."
                    // Sofort in „Weiterschauen“ aufnehmen; Infuse meldet die echte Position beim Schliessen.
                    if model.progress(for: request.media) == nil {
                        model.saveProgress(
                            media: request.media,
                            position: max(request.resumeSeconds, 15),
                            duration: request.durationHint,
                            season: request.season,
                            episode: request.episode,
                            episodeTitle: request.episodeTitle
                        )
                    }
                } else {
                    banner = "\(app) liess sich nicht öffnen. \(missingHint)"
                    status = "Übergabe fehlgeschlagen."
                }
            }
        }
    }

    private func startBuiltIn(_ url: URL) {
        if Self.needsInfuse(url) {
            banner = "Dieses Format (z. B. MKV) kann der integrierte Player meist nicht – Infuse empfohlen."
        }
        playerURL = url
    }

    /// Infuse sucht Metadaten anhand des Dateinamens, daher „Titel (Jahr).mkv“ bzw. „Serie S01E02.mkv“.
    private func infuseFileName(_ stream: StreamCandidate, url: URL) -> String {
        let source = stream.fileName ?? url.lastPathComponent
        let ext = (source as NSString).pathExtension.lowercased()
        var base = request.media.title
        if let label = request.episodeLabel {
            base += " \(label)"
        } else if let year = request.media.year {
            base += " (\(year))"
        }
        base = base.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined()
        return ext.isEmpty || ext.count > 4 ? "\(base).mkv" : "\(base).\(ext)"
    }

    /// Alle Werte streng kodiert – sonst gehen `&`, `+` oder `?` aus der Stream-Adresse
    /// in Infuse verloren (das alte `URLQueryItem` liess `+`, `/`, `:` und `?` stehen).
    static func infuseURL(stream: URL, filename: String, position: Double) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        var parts = ["url=\(encode(stream.absoluteString))", "filename=\(encode(filename))"]
        if position >= 15 {
            parts.append("position=\(Int(position))")
        }
        parts.append("x-success=\(encode("stremiocraft://infuse-success"))")
        parts.append("x-error=\(encode("stremiocraft://infuse-error"))")
        return URL(string: "infuse://x-callback-url/play?" + parts.joined(separator: "&"))
    }

    static func vlcURL(stream: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // VLC dekodiert den Wert, wenn er mit einem kodierten „://“ beginnt.
        guard let encoded = stream.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)")
    }

    static func needsInfuse(_ url: URL) -> Bool {
        let haystack = url.absoluteString.lowercased()
        return [".mkv", ".avi", ".wmv", ".flv", ".m2ts", ".divx", ".rmvb"].contains { haystack.contains($0) }
    }
}

private struct StreamRow: View {
    var stream: StreamCandidate
    var isResolving: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.s(22)) {
            VStack(spacing: Theme.s(8)) {
                Text(qualityBadge)
                    .font(.system(size: Theme.s(22), weight: .heavy))
                    .padding(.horizontal, Theme.s(14))
                    .padding(.vertical, Theme.s(6))
                    .background(Theme.accent.opacity(stream.rank >= 80 ? 1 : 0.45), in: Capsule())
                if stream.isCached {
                    Label("Sofort", systemImage: "bolt.fill")
                        .font(.system(size: Theme.s(16), weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }
            .frame(width: Theme.s(140))
            VStack(alignment: .leading, spacing: Theme.s(6)) {
                Text(stream.quality)
                    .font(.system(size: Theme.s(22), weight: .semibold))
                    .lineLimit(1)
                Text(stream.title.replacingOccurrences(of: "\n", with: "  ·  "))
                    .font(.system(size: Theme.s(18)))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 20)
            if isResolving {
                ProgressView()
            } else {
                Text(stream.size)
                    .font(.system(size: Theme.s(20), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.s(24))
        .padding(.vertical, Theme.s(16))
        .frame(maxWidth: Theme.s(1400), alignment: .leading)
    }

    private var qualityBadge: String {
        switch stream.rank {
        case 100: return "4K"
        case 80: return "1080p"
        case 60: return "720p"
        case 40: return "SD"
        default: return stream.quality.components(separatedBy: " ").first?.uppercased() ?? "?"
        }
    }
}

struct PlayerScreen: View {
    var url: URL
    var resume: Double
    var onProgress: (Double, Double) -> Void

    @StateObject private var controller = PlayerController()
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoPlayer(player: controller.player)
                .ignoresSafeArea()
            if let failure {
                Text("\(failure) Dieses Format braucht vermutlich Infuse.")
                    .font(.headline)
                    .padding(Theme.s(16))
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.s(12)))
                    .padding(Theme.s(36))
            }
        }
        .onAppear {
            controller.onProgress = onProgress
            controller.onFailure = { failure = $0 }
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
        // Seltener speichern: jeder Speichervorgang aktualisiert „Weiterschauen“ und damit die Startseite.
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 20, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, self.player.rate > 0 else { return }
                let duration = self.player.currentItem?.duration.seconds ?? 0
                self.onProgress?(seconds, duration.isFinite ? duration : 0)
            }
        }
        player.play()
    }

    func teardown() {
        let duration = player.currentItem?.duration.seconds ?? 0
        let position = player.currentTime().seconds
        if position.isFinite, position > 0 {
            onProgress?(position, duration.isFinite ? duration : 0)
        }
        if let observer {
            player.removeTimeObserver(observer)
            self.observer = nil
        }
        statusCancellable = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
