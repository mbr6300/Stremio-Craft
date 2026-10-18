import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored private let defaults = UserDefaults.standard
    private let continueKey = "continueWatching"
    private let favoriteKey = "favorites"
    private let tmdbKey = "tmdbAPIKey"
    private let countryKey = "discoverCountry"
    private let torrentioKey = "torrentioOptions"
    private let catalogsKey = "catalogEntries"
    private let playerKey = "playerChoice"
    private let autoPlayKey = "autoPlayBest"

    var country: String
    var tmdbKeyOverride: String
    var torrentio = TorrentioOptions()
    var catalogs: [CatalogEntry] = CatalogEntry.defaults
    var player: PlayerChoice = .infuse
    var autoPlayBest = true
    var continueWatching: [WatchProgress] = []
    var favorites: [FavoriteItem] = []
    var rows: [CatalogRow] = []
    var hasRealDebridToken = false
    /// Rückmeldung von Infuse (x-callback), wird in der Wiedergabe-Ansicht angezeigt.
    var playbackNotice: String?

    @ObservationIgnored private var allProgress: [WatchProgress] = []
    @ObservationIgnored private var loadedSignature = ""
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pendingInfuse: PlaybackRequest?

    private static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("catalog-rows.json")

    var tmdbAPIKey: String {
        let override = tmdbKeyOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        return Self.bundledTMDBKey
    }

    var hasTMDBKey: Bool { !tmdbAPIKey.isEmpty }

    init() {
        country = defaults.string(forKey: countryKey) ?? "CH"
        tmdbKeyOverride = defaults.string(forKey: tmdbKey) ?? ""
        if let data = defaults.data(forKey: torrentioKey),
           let stored = try? JSONDecoder().decode(TorrentioOptions.self, from: data) {
            torrentio = stored
        }
        if let data = defaults.data(forKey: catalogsKey),
           let stored = try? JSONDecoder().decode([CatalogEntry].self, from: data) {
            catalogs = stored
        }
        player = defaults.string(forKey: playerKey).flatMap(PlayerChoice.init(rawValue:)) ?? .infuse
        autoPlayBest = defaults.object(forKey: autoPlayKey) as? Bool ?? true
        allProgress = decodeList(WatchProgress.self, key: continueKey)
        favorites = decodeList(FavoriteItem.self, key: favoriteKey)
        hasRealDebridToken = KeychainStore.loadToken() != nil
        refreshContinueWatching()
        rows = cachedRows()
    }

    // MARK: - Kataloge

    func loadCatalogsIfNeeded() async {
        guard catalogSignature != loadedSignature else { return }
        await loadCatalogs()
    }

    /// Ändert sich, wenn Region, Schlüssel oder die aktiven Reihen wechseln. Reihenfolge zählt nicht.
    var catalogSignature: String {
        "\(country)|\(tmdbAPIKey)|" + catalogs.filter(\.enabled).map { "\($0.id):\($0.source)" }.sorted().joined(separator: ",")
    }

    /// Lädt alle Reihen parallel. Bereits bekannte Inhalte (Disk-Cache) bleiben sichtbar,
    /// jede Reihe wird einzeln ersetzt, sobald sie fertig ist.
    func loadCatalogs() async {
        loadGeneration += 1
        let generation = loadGeneration
        let entries = catalogs.filter(\.enabled)
        guard hasTMDBKey else {
            rows = entries.map {
                CatalogRow(id: $0.id, title: $0.title, items: [], message: "TMDB-API-Schlüssel fehlt. Bitte in den Einstellungen eintragen.")
            }
            loadedSignature = ""
            return
        }
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = entries.map { entry in
            var row = previous[entry.id] ?? CatalogRow(id: entry.id, title: entry.title, items: [])
            row.title = entry.title
            row.isLoading = true
            row.message = nil
            return row
        }
        let key = tmdbAPIKey
        let region = country
        loadedSignature = catalogSignature

        await withTaskGroup(of: (String, Result<[MediaItem], Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do {
                        return (entry.id, .success(try await Self.fetchItems(entry, apiKey: key, country: region)))
                    } catch {
                        return (entry.id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                guard generation == loadGeneration, let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                var row = rows[index]
                row.isLoading = false
                switch result {
                case .success(let items):
                    row.items = items
                    row.message = items.isEmpty ? "Keine Titel gefunden." : nil
                case .failure(let error):
                    // Ältere Inhalte behalten, Fehler nur zeigen, wenn nichts da ist.
                    row.message = row.items.isEmpty ? error.localizedDescription : nil
                }
                rows[index] = row
            }
        }
        if generation == loadGeneration {
            storeRows()
        }
    }

    private nonisolated static func fetchItems(_ entry: CatalogEntry, apiKey: String, country: String) async throws -> [MediaItem] {
        switch entry.source {
        case .tmdbTrending:
            return try await TMDBClient.fetchTrending(apiKey: apiKey, country: country)
        case .provider(let id):
            guard let provider = TMDBClient.providers.first(where: { $0.id == id }) else { return [] }
            return try await TMDBClient.fetchProviderRow(apiKey: apiKey, provider: provider, country: country)
        case .url(let url):
            return try await ListClient.load(url, apiKey: apiKey, country: country).items
        }
    }

    func addList(url: String, title: String) async throws -> CatalogEntry {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppFailure.message("Bitte eine Adresse eingeben.") }
        guard hasTMDBKey else { throw AppFailure.message("Für Listen wird der TMDB-Schlüssel benötigt.") }
        let resolved = try await ListClient.load(trimmed, apiKey: tmdbAPIKey, country: country)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CatalogEntry(
            id: "url-\(UUID().uuidString.prefix(8))",
            title: name.isEmpty ? (resolved.title ?? "Eigene Liste") : name,
            source: .url(trimmed)
        )
        catalogs.append(entry)
        saveCatalogs()
        rows.append(CatalogRow(id: entry.id, title: entry.title, items: resolved.items))
        loadedSignature = catalogSignature
        storeRows()
        return entry
    }

    func toggleCatalog(_ entry: CatalogEntry) {
        guard let index = catalogs.firstIndex(of: entry) else { return }
        catalogs[index].enabled.toggle()
        saveCatalogs()
    }

    func moveCatalog(_ entry: CatalogEntry, by offset: Int) {
        guard let index = catalogs.firstIndex(of: entry) else { return }
        let target = index + offset
        guard catalogs.indices.contains(target) else { return }
        catalogs.swapAt(index, target)
        saveCatalogs()
    }

    func removeCatalog(_ entry: CatalogEntry) {
        catalogs.removeAll { $0.id == entry.id }
        saveCatalogs()
    }

    func resetCatalogs() {
        catalogs = CatalogEntry.defaults
        saveCatalogs()
    }

    private func saveCatalogs() {
        save(catalogs, key: catalogsKey)
        // Reihenfolge/Sichtbarkeit sofort übernehmen, fehlende Reihen werden beim nächsten Laden geholt.
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = catalogs.filter(\.enabled).map { entry in
            var row = byId[entry.id] ?? CatalogRow(id: entry.id, title: entry.title, items: [], isLoading: true)
            row.title = entry.title
            return row
        }
    }

    private func cachedRows() -> [CatalogRow] {
        let stored = (try? Data(contentsOf: Self.cacheURL))
            .flatMap { try? JSONDecoder().decode([String: [MediaItem]].self, from: $0) } ?? [:]
        return catalogs.filter(\.enabled).map {
            CatalogRow(id: $0.id, title: $0.title, items: stored[$0.id] ?? [], isLoading: true)
        }
    }

    private func storeRows() {
        let snapshot = Dictionary(rows.filter { !$0.items.isEmpty }.map { ($0.id, $0.items) }, uniquingKeysWith: { first, _ in first })
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        }
    }

    // MARK: - Favoriten & Fortschritt

    func isFavorite(_ item: MediaItem) -> Bool {
        favorites.contains { $0.tmdbId == item.tmdbId && $0.mediaType == item.normalizedType }
    }

    func toggleFavorite(_ item: MediaItem) {
        let type = item.normalizedType
        if let index = favorites.firstIndex(where: { $0.tmdbId == item.tmdbId && $0.mediaType == type }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(FavoriteItem(
                tmdbId: item.tmdbId,
                mediaType: type,
                title: item.title,
                overview: item.overview,
                posterURL: item.posterURL,
                year: item.year
            ), at: 0)
        }
        save(favorites, key: favoriteKey)
    }

    func progress(for item: MediaItem) -> WatchProgress? {
        continueWatching.first { $0.tmdbId == item.tmdbId && $0.mediaType == item.normalizedType }
    }

    func saveProgress(
        media: MediaItem,
        position: Double,
        duration: Double?,
        season: Int?,
        episode: Int?,
        episodeTitle: String?
    ) {
        let entry = WatchProgress(
            tmdbId: media.tmdbId,
            mediaType: media.normalizedType,
            title: media.title,
            overview: media.overview,
            posterURL: media.posterURL,
            year: media.year,
            position: position,
            duration: duration,
            season: season,
            episode: episode,
            episodeTitle: episodeTitle,
            updatedAt: Date()
        )
        allProgress.removeAll { $0.id == entry.id }
        if entry.isActive {
            allProgress.append(entry)
        }
        save(allProgress, key: continueKey)
        refreshContinueWatching()
    }

    func removeProgress(_ entry: WatchProgress) {
        allProgress.removeAll { $0.id == entry.id }
        save(allProgress, key: continueKey)
        refreshContinueWatching()
    }

    private func refreshContinueWatching() {
        let next = allProgress.filter(\.isActive).sorted { $0.updatedAt > $1.updatedAt }
        if next != continueWatching { continueWatching = next }
    }

    // MARK: - Infuse-Rückmeldung

    func beginInfuseSession(_ request: PlaybackRequest) {
        pendingInfuse = request
        playbackNotice = nil
    }

    /// `stremiocraft://infuse-success?position=…` bzw. `stremiocraft://infuse-error?errorMessage=…`
    func handleCallback(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value: (String) -> String? = { name in items.first { $0.name == name }?.value }
        switch url.host {
        case "infuse-success":
            guard let request = pendingInfuse, let position = value("position").flatMap(Double.init) else { return }
            saveProgress(
                media: request.media,
                position: position,
                duration: request.durationHint,
                season: request.season,
                episode: request.episode,
                episodeTitle: request.episodeTitle
            )
            playbackNotice = "Infuse beendet bei \(WatchProgress.clock(position))."
        case "infuse-error":
            playbackNotice = "Infuse meldet: \(value("errorMessage") ?? "Wiedergabe fehlgeschlagen.")"
        default:
            break
        }
        pendingInfuse = nil
    }

    // MARK: - Einstellungen

    func saveSettings(country: String, tmdbKey: String, torrentio: TorrentioOptions) {
        self.country = country
        tmdbKeyOverride = tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.torrentio = torrentio
        defaults.set(self.country, forKey: countryKey)
        defaults.set(tmdbKeyOverride, forKey: self.tmdbKey)
        save(torrentio, key: torrentioKey)
    }

    func savePlayer(_ choice: PlayerChoice, autoPlay: Bool) {
        player = choice
        autoPlayBest = autoPlay
        defaults.set(choice.rawValue, forKey: playerKey)
        defaults.set(autoPlay, forKey: autoPlayKey)
    }

    func setRealDebridToken(_ token: String?) throws {
        if let token, !token.isEmpty {
            try KeychainStore.saveToken(token)
        } else {
            KeychainStore.deleteToken()
        }
        hasRealDebridToken = KeychainStore.loadToken() != nil
    }

    private func decodeList<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static let bundledTMDBKey: String = {
        guard let url = Bundle.main.url(forResource: "LocalSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = object["TMDB_API_KEY"] as? String else {
            return ""
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}
