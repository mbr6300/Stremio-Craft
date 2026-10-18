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
    private let catalogsVersionKey = "catalogEntriesVersion"
    private let recentSearchesKey = "recentSearches"
    private let playerKey = "playerChoice"
    private let autoPlayKey = "autoPlayBest"
    private let profilesKey = "profiles"
    private let activeProfileKey = "activeProfile"

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
    /// Von außen angeforderte Ansicht (Deep Link), wird vom Entdecken-Bereich geöffnet.
    var deepLink: AppRoute?
    /// Die letzten 10 Suchbegriffe des aktiven Profils, neuester zuerst.
    var recentSearches: [String] = []
    var profiles: [Profile] = []
    /// Gewählter Menüpunkt; z. B. nach dem Profilwechsel zurück zu Entdecken.
    var selectedTab: AppTab = .home
    /// `nil` = „Alle“.
    var activeProfileID: String?

    /// Favoriten und Fortschritt je Profil; Schlüssel "" steht für „Alle“.
    @ObservationIgnored private var favoriteBuckets: [String: [FavoriteItem]] = [:]
    @ObservationIgnored private var progressBuckets: [String: [WatchProgress]] = [:]
    @ObservationIgnored private var loadedSignature = ""
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var pendingInfuse: PlaybackRequest?
    @ObservationIgnored private var recommendationTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

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
            if defaults.integer(forKey: catalogsVersionKey) < CatalogEntry.defaultsVersion {
                catalogs = CatalogEntry.migrate(stored)
                save(catalogs, key: catalogsKey)
            } else {
                catalogs = stored
            }
        }
        defaults.set(CatalogEntry.defaultsVersion, forKey: catalogsVersionKey)
        player = defaults.string(forKey: playerKey).flatMap(PlayerChoice.init(rawValue:)) ?? .infuse
        autoPlayBest = defaults.object(forKey: autoPlayKey) as? Bool ?? true
        profiles = decodeList(Profile.self, key: profilesKey)
        activeProfileID = defaults.string(forKey: activeProfileKey).flatMap { id in
            profiles.contains { $0.id == id } ? id : nil
        }
        hasRealDebridToken = KeychainStore.loadToken() != nil
        loadPersonalData()
        rows = cachedRows()
    }

    // MARK: - Kataloge

    /// Startet das Laden in einer eigenen Task. Hinge es an der `.task` der Startseite, würde ein
    /// Neuaufbau der Ansicht alle Anfragen abbrechen – und wegen der schon gesetzten Signatur nie wiederholen.
    func loadCatalogsIfNeeded() {
        guard catalogSignature != loadedSignature else { return }
        loadTask?.cancel()
        loadTask = Task { await loadCatalogs() }
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
        let favoriteItems = favorites.map(\.media)
        let personal = Set(entries.filter(\.isPersonal).map(\.id))
        loadedSignature = catalogSignature

        await withTaskGroup(of: (String, Result<[MediaItem], Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do {
                        let items = try await Self.fetchItems(entry, apiKey: key, country: region, favorites: favoriteItems)
                        return (entry.id, .success(items))
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
                    // Leere persönliche Reihen einfach ausblenden statt Hinweis zeigen.
                    row.message = items.isEmpty && !personal.contains(id) ? "Keine Titel gefunden." : nil
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

    private nonisolated static func fetchItems(
        _ entry: CatalogEntry,
        apiKey: String,
        country: String,
        favorites: [MediaItem]
    ) async throws -> [MediaItem] {
        switch entry.source {
        case .tmdbTrending:
            return try await TMDBClient.fetchTrending(apiKey: apiKey, country: country)
        case .trending(let type):
            return try await TMDBClient.fetchTrending(apiKey: apiKey, country: country, type: type)
        case .favorites:
            return favorites
        case .newOnProviders:
            return try await DiscoverCache.shared.firstPage(.newOnAllProviders, apiKey: apiKey, country: country)
        case .recommendations:
            return await recommendations(for: favorites, apiKey: apiKey, country: country)
        case .provider(let id):
            guard let provider = TMDBClient.providers.first(where: { $0.id == id }) else { return [] }
            return try await TMDBClient.fetchProviderRow(apiKey: apiKey, provider: provider, country: country)
        case .url(let url):
            return try await ListClient.load(url, apiKey: apiKey, country: country).items
        }
    }

    /// Empfehlungen zu den neuesten Favoriten, abwechselnd gemischt, ohne Doppelte und ohne die Favoriten selbst.
    private nonisolated static func recommendations(for favorites: [MediaItem], apiKey: String, country: String) async -> [MediaItem] {
        let seeds = Array(favorites.prefix(8))
        guard !seeds.isEmpty else { return [] }
        let lists = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    let items = (try? await TMDBClient.fetchRecommendations(
                        apiKey: apiKey, tmdbId: seed.tmdbId, mediaType: seed.normalizedType, country: country
                    )) ?? []
                    return (index, items)
                }
            }
            var result = Array(repeating: [MediaItem](), count: seeds.count)
            for await (index, items) in group { result[index] = items }
            return result
        }
        var seen = Set(favorites.map(\.id))
        var merged: [MediaItem] = []
        let depth = lists.map(\.count).max() ?? 0
        for position in 0..<depth {
            for list in lists where position < list.count {
                let item = list[position]
                if seen.insert(item.id).inserted { merged.append(item) }
            }
        }
        return Array(merged.prefix(60))
    }

    /// Favoriten-Reihe sofort aktualisieren, Empfehlungen kurz danach neu berechnen.
    private func refreshPersonalRows() {
        let favoriteRows = Set(catalogs.filter { $0.source == .favorites }.map(\.id))
        for index in rows.indices where favoriteRows.contains(rows[index].id) {
            rows[index].items = favorites.map(\.media)
            rows[index].isLoading = false
        }
        recommendationTask?.cancel()
        guard let entry = catalogs.first(where: { $0.enabled && $0.source == .recommendations }), hasTMDBKey else { return }
        let key = tmdbAPIKey
        let region = country
        let seeds = favorites.map(\.media)
        recommendationTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let items = await Self.recommendations(for: seeds, apiKey: key, country: region)
            guard !Task.isCancelled, let index = rows.firstIndex(where: { $0.id == entry.id }) else { return }
            rows[index].items = items
            rows[index].isLoading = false
            storeRows()
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
            let items = $0.source == .favorites ? favorites.map(\.media) : stored[$0.id] ?? []
            return CatalogRow(id: $0.id, title: $0.title, items: items, isLoading: $0.source != .favorites)
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

    // MARK: - Profile

    /// Aktives Profil; `nil` heißt „Alle“ (gemeinsame Sicht auf alle Profile).
    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileID }
    }

    func switchProfile(to id: String?) {
        guard id != activeProfileID else { return }
        activeProfileID = id
        defaults.set(id, forKey: activeProfileKey)
        loadPersonalData()
        refreshPersonalRows()
    }

    @discardableResult
    func saveProfile(_ profile: Profile) -> Profile {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var stored = profile
        stored.name = name.isEmpty ? "Profil \(profiles.count + 1)" : name
        if let index = profiles.firstIndex(where: { $0.id == stored.id }) {
            profiles[index] = stored
        } else {
            profiles.append(stored)
        }
        save(profiles, key: profilesKey)
        return stored
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save(profiles, key: profilesKey)
        for base in [favoriteKey, continueKey, recentSearchesKey] {
            defaults.removeObject(forKey: bucketKey(base, profile.id))
        }
        favoriteBuckets[profile.id] = nil
        progressBuckets[profile.id] = nil
        if activeProfileID == profile.id {
            activeProfileID = nil
            defaults.removeObject(forKey: activeProfileKey)
        }
        loadPersonalData()
        refreshPersonalRows()
    }

    /// „Alle“ nutzt die bisherigen Schlüssel (so bleiben alte Daten erhalten), Profile hängen ihre ID an.
    private func bucketKey(_ base: String, _ profileID: String?) -> String {
        profileID.map { "\(base).\($0)" } ?? base
    }

    /// Alle Speicherbereiche: `nil` für „Alle“ plus jedes Profil.
    private var bucketIDs: [String?] { [nil] + profiles.map { Optional($0.id) } }

    private func bucketName(_ id: String?) -> String { id ?? "" }

    private func loadPersonalData() {
        for id in bucketIDs where favoriteBuckets[bucketName(id)] == nil {
            favoriteBuckets[bucketName(id)] = decodeList(FavoriteItem.self, key: bucketKey(favoriteKey, id))
            progressBuckets[bucketName(id)] = decodeList(WatchProgress.self, key: bucketKey(continueKey, id))
        }
        refreshFavorites()
        refreshContinueWatching()
        recentSearches = defaults.stringArray(forKey: bucketKey(recentSearchesKey, activeProfileID)) ?? []
    }

    /// Bei „Alle“ die Vereinigung aller Profile, sonst nur das aktive Profil.
    private func refreshFavorites() {
        if let id = activeProfileID {
            favorites = favoriteBuckets[id] ?? []
            return
        }
        var seen = Set<String>()
        favorites = bucketIDs.flatMap { favoriteBuckets[bucketName($0)] ?? [] }.filter { seen.insert($0.id).inserted }
    }

    private func refreshContinueWatching() {
        let source = activeProfileID.map { progressBuckets[$0] ?? [] }
            ?? bucketIDs.flatMap { progressBuckets[bucketName($0)] ?? [] }
        var seen = Set<String>()
        let next = source
            .filter(\.isActive)
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { seen.insert($0.id).inserted }
        if next != continueWatching { continueWatching = next }
    }

    // MARK: - Suchverlauf

    func addRecentSearch(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else { return }
        var next = recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        next.insert(term, at: 0)
        next = Array(next.prefix(10))
        guard next != recentSearches else { return }
        recentSearches = next
        defaults.set(next, forKey: bucketKey(recentSearchesKey, activeProfileID))
    }

    func removeRecentSearch(_ term: String) {
        recentSearches.removeAll { $0 == term }
        defaults.set(recentSearches, forKey: bucketKey(recentSearchesKey, activeProfileID))
    }

    func clearRecentSearches() {
        recentSearches = []
        defaults.removeObject(forKey: bucketKey(recentSearchesKey, activeProfileID))
    }

    // MARK: - Favoriten & Fortschritt

    func isFavorite(_ item: MediaItem) -> Bool {
        favorites.contains { $0.tmdbId == item.tmdbId && $0.mediaType == item.normalizedType }
    }

    func toggleFavorite(_ item: MediaItem) {
        let type = item.normalizedType
        let matches: (FavoriteItem) -> Bool = { $0.tmdbId == item.tmdbId && $0.mediaType == type }
        // Bei „Alle“ entfernt das Abwählen den Titel aus allen Profilen; Hinzufügen landet im gemeinsamen Bereich.
        let wasFavorite = isFavorite(item)
        let targets: [String?] = wasFavorite ? (activeProfileID.map { [$0] } ?? bucketIDs) : [activeProfileID]
        for id in targets {
            var list = favoriteBuckets[bucketName(id)] ?? []
            if wasFavorite {
                list.removeAll(where: matches)
            } else {
                list.insert(FavoriteItem(
                    tmdbId: item.tmdbId,
                    mediaType: type,
                    title: item.title,
                    overview: item.overview,
                    posterURL: item.posterURL,
                    year: item.year,
                    backdropURL: item.backdropURL,
                    rating: item.rating,
                    imdbId: item.imdbId
                ), at: 0)
            }
            favoriteBuckets[bucketName(id)] = list
            save(list, key: bucketKey(favoriteKey, id))
        }
        refreshFavorites()
        refreshPersonalRows()
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
        let bucket = bucketName(activeProfileID)
        var list = progressBuckets[bucket] ?? []
        list.removeAll { $0.id == entry.id }
        if entry.isActive {
            list.append(entry)
        }
        progressBuckets[bucket] = list
        save(list, key: bucketKey(continueKey, activeProfileID))
        refreshContinueWatching()
    }

    func removeProgress(_ entry: WatchProgress) {
        // Bei „Alle“ aus allen Profilen entfernen, sonst nur aus dem aktiven.
        for id in activeProfileID.map({ [Optional($0)] }) ?? bucketIDs {
            var list = progressBuckets[bucketName(id)] ?? []
            list.removeAll { $0.id == entry.id }
            progressBuckets[bucketName(id)] = list
            save(list, key: bucketKey(continueKey, id))
        }
        refreshContinueWatching()
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
        case "detail":
            // stremiocraft://detail/movie/155 bzw. stremiocraft://detail/tv/1396
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, ["movie", "tv"].contains(parts[0]), let id = Int(parts[1]) else { return }
            deepLink = .detail(MediaItem(tmdbId: id, mediaType: parts[0], title: "", overview: ""))
            return
        case "genre":
            // stremiocraft://genre/movie/35
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, let id = Int(parts[1]),
                  let genre = (parts[0] == "tv" ? Genre.series : Genre.movie).first(where: { $0.id == id }) else { return }
            deepLink = .discover(genre.query(type: parts[0] == "tv" ? "tv" : "movie"))
            return
        case "profile":
            // stremiocraft://profile/<id> bzw. stremiocraft://profile/all
            guard let id = url.pathComponents.last else { return }
            switchProfile(to: id == "all" ? nil : profiles.first { $0.id == id }?.id)
            selectedTab = .home
            return
        case "tab":
            // stremiocraft://tab/profiles
            if let tab = url.pathComponents.last.flatMap(AppTab.init(rawValue:)) { selectedTab = tab }
            return
        case "row":
            // stremiocraft://row/new-on-providers
            guard let id = url.pathComponents.last, id != "/" else { return }
            deepLink = .row(id)
            return
        case "provider":
            // stremiocraft://provider/netflix
            guard let id = url.pathComponents.last, TMDBClient.providers.contains(where: { $0.id == id }) else { return }
            deepLink = .provider(id)
            return
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
