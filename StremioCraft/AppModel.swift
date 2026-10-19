import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    @ObservationIgnored private let defaults = UserDefaults.standard
    private let continueKey = "continueWatching"
    private let favoriteKey = "favorites"
    private let watchedKey = "watched"
    private let lovedKey = "loved"
    private let pendingInfuseKey = "pendingInfuse"
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
    private let zoomKey = "uiZoom"

    /// Darstellungsgrösse auf iPad und Mac (siehe `Zoom`).
    private(set) var zoom: Double = Zoom.standard

    var country: String
    var tmdbKeyOverride: String
    var torrentio = TorrentioOptions()
    var catalogs: [CatalogEntry] = CatalogEntry.defaults
    var player: PlayerChoice = .platformDefault
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
    @ObservationIgnored private var lovedBuckets: [String: [FavoriteItem]] = [:]
    /// ♥ Lieblingstitel des aktiven Profils (getrennt von der Merkliste „Meine Liste“).
    var loved: [FavoriteItem] = []
    @ObservationIgnored private var watchedBuckets: [String: Set<String>] = [:]
    /// Gesehene Filme ("movie-<id>") und Folgen ("tv-<id>-<staffel>-<folge>") des aktiven Profils.
    var watched: Set<String> = []
    @ObservationIgnored private var progressBuckets: [String: [WatchProgress]] = [:]
    @ObservationIgnored private var loadedSignature = ""
    @ObservationIgnored private var loadGeneration = 0
    /// An Infuse übergebene Wiedergabe. Dauerhaft gespeichert: iPadOS beendet die App oft,
    /// während Infuse läuft – der Rückruf mit der Position käme sonst ins Leere.
    @ObservationIgnored private var pendingInfuse: PlaybackRequest? {
        get {
            defaults.data(forKey: pendingInfuseKey).flatMap { try? JSONDecoder().decode(PlaybackRequest.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: pendingInfuseKey)
            } else {
                defaults.removeObject(forKey: pendingInfuseKey)
            }
        }
    }
    @ObservationIgnored private var recommendationTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Unveränderlich, daher ohne Main-Actor-Bindung – wird auch aus Hintergrund-Tasks geschrieben.
    private nonisolated static let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
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
        player = defaults.string(forKey: playerKey).flatMap(PlayerChoice.init(rawValue:)) ?? .platformDefault
        autoPlayBest = defaults.object(forKey: autoPlayKey) as? Bool ?? true
        zoom = defaults.object(forKey: zoomKey) as? Double ?? Zoom.standard
        Theme.zoom = zoom
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
        let lovedItems = loved.map(\.media)
        let personal = Set(entries.filter(\.isPersonal).map(\.id))
        loadedSignature = catalogSignature

        await withTaskGroup(of: (String, Result<[MediaItem], Error>).self) { group in
            for entry in entries {
                group.addTask {
                    do {
                        let items = try await Self.fetchItems(entry, apiKey: key, country: region, favorites: favoriteItems, loved: lovedItems)
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
        favorites: [MediaItem],
        loved: [MediaItem]
    ) async throws -> [MediaItem] {
        switch entry.source {
        case .tmdbTrending:
            return try await TMDBClient.fetchTrending(apiKey: apiKey, country: country)
        case .trending(let type):
            return try await TMDBClient.fetchTrending(apiKey: apiKey, country: country, type: type)
        case .favorites:
            return favorites
        case .loved:
            return loved
        case .newOnProviders:
            return try await DiscoverCache.shared.firstPage(.newOnAllProviders, apiKey: apiKey, country: country)
        case .recommendations:
            return await recommendations(loved: loved, favorites: favorites, apiKey: apiKey, country: country)
        case .provider(let id):
            guard let provider = TMDBClient.providers.first(where: { $0.id == id }) else { return [] }
            return try await TMDBClient.fetchProviderRow(apiKey: apiKey, provider: provider, country: country)
        case .url(let url):
            return try await ListClient.load(url, apiKey: apiKey, country: country).items
        }
    }

    /// Empfehlungen auf Basis der Lieblingstitel (♥, doppelt gewichtet) und von Meine Liste:
    /// je Runde zwei Treffer pro Lieblingstitel, einer pro Merklisten-Titel; ohne Doppelte und
    /// ohne Titel, die schon markiert sind.
    private nonisolated static func recommendations(loved: [MediaItem], favorites: [MediaItem], apiKey: String, country: String) async -> [MediaItem] {
        let lovedSeeds = Array(loved.prefix(6))
        let lovedIDs = Set(lovedSeeds.map(\.id))
        let seeds: [(item: MediaItem, weight: Int)] = lovedSeeds.map { ($0, 2) }
            + favorites.filter { !lovedIDs.contains($0.id) }.prefix(4).map { ($0, 1) }
        guard !seeds.isEmpty else { return [] }
        let lists = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask {
                    let items = (try? await TMDBClient.fetchRecommendations(
                        apiKey: apiKey, tmdbId: seed.item.tmdbId, mediaType: seed.item.normalizedType, country: country
                    )) ?? []
                    return (index, items)
                }
            }
            var result = Array(repeating: [MediaItem](), count: seeds.count)
            for await (index, items) in group { result[index] = items }
            return result
        }
        var seen = Set((loved + favorites).map(\.id))
        var merged: [MediaItem] = []
        var cursors = Array(repeating: 0, count: lists.count)
        while merged.count < 60, cursors.indices.contains(where: { cursors[$0] < lists[$0].count }) {
            for index in lists.indices {
                for _ in 0..<seeds[index].weight where cursors[index] < lists[index].count {
                    let item = lists[index][cursors[index]]
                    cursors[index] += 1
                    if seen.insert(item.id).inserted { merged.append(item) }
                }
            }
        }
        return Array(merged.prefix(60))
    }

    /// Persönliche Reihen sofort aktualisieren, Empfehlungen kurz danach neu berechnen.
    private func refreshPersonalRows() {
        for index in rows.indices {
            switch catalogs.first(where: { $0.id == rows[index].id })?.source {
            case .favorites:
                rows[index].items = favorites.map(\.media)
                rows[index].isLoading = false
            case .loved:
                rows[index].items = loved.map(\.media)
                rows[index].isLoading = false
            default:
                break
            }
        }
        recommendationTask?.cancel()
        guard let entry = catalogs.first(where: { $0.enabled && $0.source == .recommendations }), hasTMDBKey else { return }
        let key = tmdbAPIKey
        let region = country
        let lovedSeeds = loved.map(\.media)
        let favoriteSeeds = favorites.map(\.media)
        recommendationTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let items = await Self.recommendations(loved: lovedSeeds, favorites: favoriteSeeds, apiKey: key, country: region)
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
        guard let index = catalogs.firstIndex(where: { $0.id == entry.id }) else { return }
        catalogs[index].enabled.toggle()
        saveCatalogs()
    }

    func moveCatalog(_ entry: CatalogEntry, by offset: Int) {
        guard let index = catalogs.firstIndex(where: { $0.id == entry.id }) else { return }
        let target = index + offset
        guard catalogs.indices.contains(target) else { return }
        catalogs.swapAt(index, target)
        saveCatalogs()
    }

    func moveCatalog(_ entry: CatalogEntry, toTop: Bool) {
        guard let index = catalogs.firstIndex(where: { $0.id == entry.id }) else { return }
        let moved = catalogs.remove(at: index)
        if toTop {
            catalogs.insert(moved, at: 0)
        } else {
            catalogs.append(moved)
        }
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
            switch $0.source {
            case .favorites:
                return CatalogRow(id: $0.id, title: $0.title, items: favorites.map(\.media))
            case .loved:
                return CatalogRow(id: $0.id, title: $0.title, items: loved.map(\.media))
            default:
                return CatalogRow(id: $0.id, title: $0.title, items: stored[$0.id] ?? [], isLoading: true)
            }
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
        for base in [favoriteKey, lovedKey, continueKey, recentSearchesKey, watchedKey] {
            defaults.removeObject(forKey: bucketKey(base, profile.id))
        }
        favoriteBuckets[profile.id] = nil
        lovedBuckets[profile.id] = nil
        progressBuckets[profile.id] = nil
        watchedBuckets[profile.id] = nil
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
            lovedBuckets[bucketName(id)] = decodeList(FavoriteItem.self, key: bucketKey(lovedKey, id))
            progressBuckets[bucketName(id)] = decodeList(WatchProgress.self, key: bucketKey(continueKey, id))
            watchedBuckets[bucketName(id)] = Set(defaults.stringArray(forKey: bucketKey(watchedKey, id)) ?? [])
        }
        refreshFavorites()
        refreshContinueWatching()
        refreshWatched()
        recentSearches = defaults.stringArray(forKey: bucketKey(recentSearchesKey, activeProfileID)) ?? []
    }

    /// Bei „Alle“ die Vereinigung aller Profile, sonst nur das aktive Profil.
    private func refreshFavorites() {
        favorites = visibleItems(favoriteBuckets)
        loved = visibleItems(lovedBuckets)
    }

    private func visibleItems(_ buckets: [String: [FavoriteItem]]) -> [FavoriteItem] {
        if let id = activeProfileID { return buckets[id] ?? [] }
        var seen = Set<String>()
        return bucketIDs.flatMap { buckets[bucketName($0)] ?? [] }.filter { seen.insert($0.id).inserted }
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

    // MARK: - Gesehen

    static func movieKey(_ tmdbId: Int) -> String { "movie-\(tmdbId)" }
    static func episodeKey(_ tmdbId: Int, _ season: Int, _ episode: Int) -> String { "tv-\(tmdbId)-\(season)-\(episode)" }

    /// Nur Filme; Serien werden pro Folge markiert.
    func isWatched(_ item: MediaItem) -> Bool {
        item.normalizedType == "movie" && watched.contains(Self.movieKey(item.tmdbId))
    }

    func isWatched(_ episode: EpisodeInfo, of series: MediaItem) -> Bool {
        watched.contains(Self.episodeKey(series.tmdbId, episode.seasonNumber, episode.episodeNumber))
    }

    /// Markieren landet im aktiven Profil (bzw. bei „Alle“ im gemeinsamen Bereich);
    /// Entfernen bei „Alle“ entfernt aus allen Profilen – wie bei Meine Liste.
    func setWatched(_ keys: [String], _ value: Bool) {
        let targets: [String?] = value ? [activeProfileID] : (activeProfileID.map { [$0] } ?? bucketIDs)
        for id in targets {
            var set = watchedBuckets[bucketName(id)] ?? []
            if value { set.formUnion(keys) } else { set.subtract(keys) }
            watchedBuckets[bucketName(id)] = set
            defaults.set(Array(set), forKey: bucketKey(watchedKey, id))
        }
        refreshWatched()
    }

    /// Gesehenes aus „Weiterschauen“ nehmen (z. B. nach manuellem Markieren).
    func clearProgressIfWatched(_ media: MediaItem) {
        guard let entry = progress(for: media) else { return }
        let done: Bool
        if let season = entry.season, let episode = entry.episode {
            done = watched.contains(Self.episodeKey(media.tmdbId, season, episode))
        } else {
            done = media.normalizedType == "movie" && watched.contains(Self.movieKey(media.tmdbId))
        }
        if done { removeProgress(entry) }
    }

    private func refreshWatched() {
        let next = activeProfileID.map { watchedBuckets[$0] ?? [] }
            ?? bucketIDs.reduce(into: Set<String>()) { $0.formUnion(watchedBuckets[bucketName($1)] ?? []) }
        if next != watched { watched = next }
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
        toggle(item, in: &favoriteBuckets, wasMarked: isFavorite(item), key: favoriteKey)
        refreshFavorites()
        refreshPersonalRows()
    }

    // MARK: - Lieblingstitel (♥)

    func isLoved(_ item: MediaItem) -> Bool {
        loved.contains { $0.tmdbId == item.tmdbId && $0.mediaType == item.normalizedType }
    }

    func toggleLoved(_ item: MediaItem) {
        toggle(item, in: &lovedBuckets, wasMarked: isLoved(item), key: lovedKey)
        refreshFavorites()
        refreshPersonalRows()
    }

    /// Gemeinsame Logik für Meine Liste und Lieblingstitel: Hinzufügen landet im aktiven Profil
    /// (bzw. bei „Alle“ im gemeinsamen Bereich); Entfernen bei „Alle“ entfernt aus allen Profilen.
    private func toggle(_ item: MediaItem, in buckets: inout [String: [FavoriteItem]], wasMarked: Bool, key base: String) {
        let type = item.normalizedType
        let matches: (FavoriteItem) -> Bool = { $0.tmdbId == item.tmdbId && $0.mediaType == type }
        let targets: [String?] = wasMarked ? (activeProfileID.map { [$0] } ?? bucketIDs) : [activeProfileID]
        for id in targets {
            var list = buckets[bucketName(id)] ?? []
            if wasMarked {
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
            buckets[bucketName(id)] = list
            save(list, key: bucketKey(base, id))
        }
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
        // Fast ganz geschaut → automatisch als gesehen markieren; bei Serien die nächste Folge vormerken.
        if let duration, duration > 0, position >= duration * 0.92 {
            let key = media.normalizedType == "tv"
                ? season.flatMap { s in episode.map { Self.episodeKey(media.tmdbId, s, $0) } }
                : Self.movieKey(media.tmdbId)
            if let key { setWatched([key], true) }
            if media.normalizedType == "tv", let season, let episode {
                Task { await queueNextEpisode(after: media, season: season, episode: episode) }
            }
        }
        progressBuckets[bucket] = list
        save(list, key: bucketKey(continueKey, activeProfileID))
        refreshContinueWatching()
    }

    /// Trägt nach einer fertigen Folge die nächste noch nicht gesehene und bereits ausgestrahlte
    /// Folge als „Als Nächstes“ in „Weiterschauen“ ein – auch über das Staffelende hinweg.
    func queueNextEpisode(after media: MediaItem, season: Int, episode: Int) async {
        guard hasTMDBKey else { return }
        let key = tmdbAPIKey
        let profile = activeProfileID // Profil kann während des Ladens wechseln
        guard let detail = try? await TMDBClient.fetchDetail(apiKey: key, item: media) else { return }
        let seasons = detail.seasons.map(\.seasonNumber).filter { $0 >= season }.sorted()
        var next: EpisodeInfo?
        for number in seasons {
            guard let episodes = try? await TMDBClient.fetchEpisodes(apiKey: key, tmdbId: media.tmdbId, season: number) else { break }
            let candidates = episodes.filter { number > season || $0.episodeNumber > episode }
            guard let first = candidates.first else { continue }
            if !first.isAired { break } // noch nicht ausgestrahlt: nichts vormerken
            if let unwatched = candidates.first(where: { $0.isAired && !watched.contains(Self.episodeKey(media.tmdbId, number, $0.episodeNumber)) }) {
                next = unwatched
                break
            }
        }
        guard let next else { return }
        let bucket = bucketName(profile)
        var list = progressBuckets[bucket] ?? []
        // Hat inzwischen jemand eine neuere Folge der Serie begonnen, nichts überschreiben.
        if let current = list.first(where: { $0.tmdbId == media.tmdbId && $0.mediaType == "tv" }),
           current.upNext != true,
           (current.season ?? 0, current.episode ?? 0) >= (next.seasonNumber, next.episodeNumber) {
            return
        }
        list.removeAll { $0.tmdbId == media.tmdbId && $0.mediaType == "tv" }
        list.append(WatchProgress(
            tmdbId: media.tmdbId,
            mediaType: "tv",
            title: detail.media.title,
            overview: detail.media.overview,
            posterURL: detail.media.posterURL ?? media.posterURL,
            year: detail.media.year,
            position: 0,
            duration: next.runtime.map { Double($0 * 60) },
            season: next.seasonNumber,
            episode: next.episodeNumber,
            episodeTitle: next.name,
            updatedAt: Date(),
            upNext: true
        ))
        progressBuckets[bucket] = list
        save(list, key: bucketKey(continueKey, profile))
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
        #if DEBUG
        case "finish":
            // Test: stremiocraft://finish/<tmdbId>/<staffel>/<folge> simuliert „Folge fertig geschaut“.
            let parts = url.pathComponents.filter { $0 != "/" }.compactMap(Int.init)
            guard parts.count == 3 else { return }
            let series = MediaItem(tmdbId: parts[0], mediaType: "tv", title: "", overview: "")
            saveProgress(media: series, position: 2900, duration: 3000, season: parts[1], episode: parts[2], episodeTitle: nil)
            return
        #endif
        case "lists":
            // stremiocraft://lists
            deepLink = .lists
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
            // Position robust lesen (Punkt oder Komma); ohne zugeordnete Übergabe nichts speichern.
            guard let request = pendingInfuse,
                  let raw = value("position"),
                  let position = Double(raw.replacingOccurrences(of: ",", with: ".")),
                  position > 0 else {
                pendingInfuse = nil
                return
            }
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

    /// Region direkt wechseln (z. B. über die Bubble auf der Startseite); die Reihen laden neu,
    /// weil sich `catalogSignature` ändert.
    func setCountry(_ code: String) {
        guard code != country else { return }
        country = code
        defaults.set(code, forKey: countryKey)
    }

    /// Setzt die Darstellungsgrösse; die Oberfläche wird dadurch neu aufgebaut.
    func setZoom(_ value: Double) {
        let clamped = min(max(value, Zoom.steps.first!), Zoom.steps.last!)
        guard clamped != zoom else { return }
        Theme.zoom = clamped
        zoom = clamped
        defaults.set(clamped, forKey: zoomKey)
    }

    /// Eine Stufe grösser (+1) oder kleiner (−1).
    func stepZoom(_ direction: Int) {
        let index = Zoom.steps.firstIndex { $0 >= zoom - 0.001 } ?? Zoom.steps.count - 1
        let next = min(max(index + direction, 0), Zoom.steps.count - 1)
        setZoom(Zoom.steps[next])
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
