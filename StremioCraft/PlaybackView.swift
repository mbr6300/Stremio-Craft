import AVKit
import Combine
import SwiftUI
import UIKit

struct PlaybackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Laufende Wiedergabe; wechselt bei „Nächste Folge“ im integrierten Player.
    @State private var current: PlaybackRequest
    /// Bereitgelegte nächste Folge (Stream schon freigeschaltet).
    @State private var upNext: (request: PlaybackRequest, url: URL)?
    @State private var preparingNext = false

    init(request: PlaybackRequest) {
        _current = State(initialValue: request)
    }

    @State private var streams: [StreamCandidate] = []
    @State private var status = "Streams werden gesucht…"
    @State private var banner: String?
    @State private var playerURL: URL?
    @State private var resolvingId: String?
    @State private var isLoading = true
    @State private var didLoad = false
    @State private var lastResolved: (stream: StreamCandidate, url: URL)?

    var body: some View {
        #if canImport(KSPlayer)
        // Player als Vollbild-Ebene über allem, damit Seiten- oder Tab-Leiste
        // weder das Bild noch den Schliessen-Knopf des Players verdecken.
        content(showsPlayer: false)
            .fullScreenCover(isPresented: Binding(
                get: { playerURL != nil },
                set: { presented in
                    guard !presented, playerURL != nil else { return }
                    playerURL = nil
                    // Nach dem Schauen zur Detailseite statt zurück in die Streamliste
                    // (der Navigationsstapel reagiert darauf, siehe `NavigationTab`).
                    model.finishedPlayback = current.media
                }
            )) {
                if let playerURL {
                    // Fortschritt an die Folge binden, zu der der Player gehört – beim Wechsel zur
                    // nächsten Folge meldet der alte Player seine letzte Position noch nach.
                    let playing = current
                    KSPlayerScreen(
                        url: playerURL,
                        title: playerTitle,
                        resume: current.resumeSeconds,
                        audioLanguage: model.playbackLanguages.audio,
                        subtitleLanguage: model.playbackLanguages.subtitle,
                        nextLabel: upNext.map { next in
                            [next.request.episodeLabel, next.request.episodeTitle].compactMap { $0 }.joined(separator: " · ")
                        },
                        onNext: playNext
                    ) { position, duration in
                        saveProgress(playing, position: position, duration: duration)
                    }
                    .id(playerURL)
                }
            }
        #else
        content(showsPlayer: true)
        #endif
    }

    private func content(showsPlayer: Bool) -> some View {
        Group {
            if showsPlayer, let playerURL {
                PlayerScreen(url: playerURL, resume: current.resumeSeconds, onProgress: saveBuiltInProgress)
            } else {
                ZStack {
                    BackdropLayer(url: current.media.backdropURL)
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
                Text(current.media.title)
                    .font(.system(size: Theme.s(56), weight: .heavy))
                    .lineLimit(1)
                if let label = current.episodeLabel {
                    Text("\(label)  ·  \(current.episodeTitle ?? "")")
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
                if streams.isEmpty {
                    // Ohne fokussierbares Element gibt tvOS die Menü-Taste ans System weiter und die
                    // App wird verlassen – darum immer einen Knopf anbieten.
                    HStack(spacing: Theme.s(20)) {
                        Button("Zurück") { dismiss() }
                            .buttonStyle(PillButtonStyle(prominent: !isLoading))
                        if !isLoading {
                            Button("Erneut suchen") {
                                Task {
                                    isLoading = true
                                    status = "Streams werden gesucht…"
                                    await loadStreams()
                                }
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                    .tvFocusSection()
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
                tmdbId: current.media.tmdbId,
                mediaType: current.media.normalizedType
            )
            guard let imdb, imdb.hasPrefix("tt") else {
                status = "Keine IMDb-ID bei TMDB. Torrentio kann diesen Titel nicht auflösen."
                return
            }
            let raw = try await TorrentioClient.streams(
                options: model.torrentio,
                token: token,
                imdbId: imdb,
                mediaType: current.media.normalizedType,
                season: current.season,
                episode: current.episode
            )
            // Nach den eigenen Regeln ordnen (Einstellungen → Stream-Auswahl) und bei Serien die
            // zuletzt gewählte Gruppe/Auflösung bevorzugen.
            let found = StreamPicker.sort(raw, preferences: model.streamPreferences, memory: model.streamMemory(for: current.media))
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
            guard current.autoStart, token != nil else { return }
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
            model.rememberStream(stream, for: current.media)
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
        guard let infuse = Self.infuseURL(stream: url, filename: infuseFileName(stream, url: url), position: current.resumeSeconds) else {
            banner = "Infuse-Adresse konnte nicht gebaut werden."
            return
        }
        model.beginInfuseSession(current)
        openExternal(infuse, app: "Infuse", missingHint: "Ist Infuse (ab Version 8.4.7) installiert?")
    }

    /// VLC für tvOS/iPadOS: `vlc-x-callback://x-callback-url/stream?url=…` spielt direkt ab;
    /// auf dem Mac wird die Stream-Adresse direkt an VLC übergeben.
    /// VLC kann weder an einer Position starten noch die Position zurückmelden.
    private func openVLC(_ url: URL) {
        if current.resumeSeconds >= 15 {
            banner = "VLC startet von vorne – zum Fortsetzen bei \(WatchProgress.clock(current.resumeSeconds)) vorspulen."
        }
        #if targetEnvironment(macCatalyst)
        status = "Übergabe an VLC…"
        Platform.openInMacApp(bundleID: "org.videolan.vlc", url: url) { success in
            if success {
                status = "In VLC geöffnet."
                recordHandoff()
            } else {
                banner = "VLC liess sich nicht öffnen. Ist VLC im Programme-Ordner installiert?"
                status = "Übergabe fehlgeschlagen."
            }
        }
        #else
        guard let vlc = Self.vlcURL(stream: url) else {
            banner = "VLC-Adresse konnte nicht gebaut werden."
            return
        }
        openExternal(vlc, app: "VLC", missingHint: "Ist VLC installiert?")
        #endif
    }

    private func openExternal(_ target: URL, app: String, missingHint: String) {
        status = "Übergabe an \(app)…"
        UIApplication.shared.open(target, options: [:]) { success in
            Task { @MainActor in
                if success {
                    status = "In \(app) geöffnet."
                    recordHandoff()
                } else {
                    banner = "\(app) liess sich nicht öffnen. \(missingHint)"
                    status = "Übergabe fehlgeschlagen."
                }
            }
        }
    }

    /// Sofort in „Weiterschauen“ aufnehmen; Infuse meldet die echte Position beim Schliessen.
    private func recordHandoff() {
        guard model.progress(for: current.media) == nil else { return }
        model.saveProgress(
            media: current.media,
            position: max(current.resumeSeconds, 15),
            duration: current.durationHint,
            season: current.season,
            episode: current.episode,
            episodeTitle: current.episodeTitle
        )
    }

    private func saveBuiltInProgress(position: Double, duration: Double) {
        saveProgress(current, position: position, duration: duration)
    }

    private func saveProgress(_ playing: PlaybackRequest, position: Double, duration: Double) {
        model.saveProgress(
            media: playing.media,
            position: position,
            duration: duration,
            season: playing.season,
            episode: playing.episode,
            episodeTitle: playing.episodeTitle
        )
        // Gegen Ende einer Folge die nächste bereitlegen, damit sie nahtlos anschliesst.
        if playing == current, playing.season != nil, upNext == nil, !preparingNext, duration > 60, duration - position <= 150 {
            preparingNext = true
            Task { await prepareNext(after: playing) }
        }
    }

    // MARK: - Nächste Folge

    /// Sucht die nächste ausgestrahlte Folge, wählt ihren Stream nach den Regeln und schaltet ihn frei.
    private func prepareNext(after playing: PlaybackRequest) async {
        guard let season = playing.season, let episode = playing.episode, model.hasTMDBKey,
              let token = KeychainStore.loadToken() else { return }
        let key = model.tmdbAPIKey
        let media = playing.media
        var next: EpisodeInfo?
        for number in [season, season + 1] {
            guard let episodes = try? await TMDBClient.fetchEpisodes(apiKey: key, tmdbId: media.tmdbId, season: number) else { break }
            if let found = episodes.first(where: { number > season || $0.episodeNumber > episode }) {
                next = found.isAired ? found : nil
                break
            }
        }
        guard let next,
              let imdb = try? await TMDBClient.imdbId(apiKey: key, tmdbId: media.tmdbId, mediaType: "tv"),
              let found = try? await TorrentioClient.streams(
                  options: model.torrentio, token: token, imdbId: imdb, mediaType: "tv",
                  season: next.seasonNumber, episode: next.episodeNumber
              ) else { return }
        let sorted = StreamPicker.sort(found, preferences: model.streamPreferences, memory: model.streamMemory(for: media))
        let anyMarked = sorted.contains { $0.directURL != nil }
        guard let best = anyMarked ? sorted.first(where: \.isCached) : sorted.first else { return }
        let url: URL
        if let direct = best.directURL {
            url = direct
        } else if let hash = best.infoHash,
                  let resolved = try? await RealDebridClient.resolve(token: token, infoHash: hash, fileIndex: best.fileIndex) {
            url = resolved
        } else {
            return
        }
        guard current == playing else { return }
        let request = PlaybackRequest(
            media: media,
            season: next.seasonNumber,
            episode: next.episodeNumber,
            episodeTitle: next.name,
            resumeSeconds: 0,
            autoStart: true,
            durationHint: next.runtime.map { Double($0 * 60) }
        )
        upNext = (request, url)
    }

    /// Wechselt im offenen Player zur bereitgelegten Folge.
    private func playNext() {
        guard let next = upNext, playerURL != nil else { return }
        upNext = nil
        preparingNext = false
        current = next.request
        lastResolved = nil
        playerURL = next.url
    }

    private var playerTitle: String {
        [current.media.title, current.episodeLabel, current.episodeTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func startBuiltIn(_ url: URL) {
        #if !canImport(KSPlayer)
        // Nur AVPlayer braucht den Hinweis; KSPlayer (FFmpeg) spielt auch MKV.
        if Self.needsInfuse(url) {
            banner = "Dieses Format (z. B. MKV) kann der integrierte Player meist nicht – Infuse empfohlen."
        }
        #endif
        playerURL = url
    }

    /// Infuse sucht Metadaten anhand des Dateinamens, daher „Titel (Jahr).mkv“ bzw. „Serie S01E02.mkv“.
    private func infuseFileName(_ stream: StreamCandidate, url: URL) -> String {
        let source = stream.fileName ?? url.lastPathComponent
        let ext = (source as NSString).pathExtension.lowercased()
        var base = current.media.title
        if let label = current.episodeLabel {
            base += " \(label)"
        } else if let year = current.media.year {
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
        load(item: AVPlayerItem(url: url), resume: resume)
    }

    func load(item: AVPlayerItem, resume: Double) {
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
