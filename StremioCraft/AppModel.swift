import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private let defaults = UserDefaults.standard
    private let continueKey = "continueWatching"
    private let favoriteKey = "favorites"
    private let tmdbKey = "tmdbAPIKey"
    private let countryKey = "discoverCountry"
    private let torrentioKey = "torrentioOptions"

    var country: String
    var tmdbKeyOverride: String
    var torrentio = TorrentioOptions()
    var continueWatching: [WatchProgress] = []
    var favorites: [FavoriteItem] = []
    var rows: [CatalogRow] = []
    var isLoadingCatalog = false
    var hasRealDebridToken = false
    private var loadedSignature = ""

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
        reloadLocal()
    }

    func reloadLocal() {
        continueWatching = decodeList(WatchProgress.self, key: continueKey)
            .filter(\.isActive)
            .sorted { $0.updatedAt > $1.updatedAt }
        favorites = decodeList(FavoriteItem.self, key: favoriteKey)
        hasRealDebridToken = KeychainStore.loadToken() != nil
    }

    func loadCatalogsIfNeeded() async {
        let signature = "\(country)|\(tmdbAPIKey)"
        guard signature != loadedSignature else { return }
        await loadCatalogs()
    }

    func loadCatalogs() async {
        reloadLocal()
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        guard hasTMDBKey else {
            rows = Self.placeholderRows(message: "TMDB-API-Schlüssel fehlt. In den Einstellungen eintragen, derselbe Schlüssel wie in Stremio-VMB.")
            loadedSignature = ""
            return
        }
        let key = tmdbAPIKey
        let region = country
        var next: [CatalogRow] = []
        do {
            let top = try await TMDBClient.fetchTopMovies(apiKey: key, country: region)
            next.append(CatalogRow(
                id: "imdb",
                title: "IMDb Top 100",
                items: top,
                message: top.isEmpty ? "Keine Titel von TMDB." : nil
            ))
        } catch {
            next.append(CatalogRow(id: "imdb", title: "IMDb Top 100", items: [], message: error.localizedDescription))
        }
        for provider in TMDBClient.providers {
            do {
                let items = try await TMDBClient.fetchProviderRow(apiKey: key, provider: provider, country: region)
                next.append(CatalogRow(
                    id: provider.id,
                    title: provider.name,
                    items: items,
                    message: items.isEmpty ? "Keine Titel für \(provider.name) in \(region)." : nil
                ))
            } catch {
                next.append(CatalogRow(id: provider.id, title: provider.name, items: [], message: error.localizedDescription))
            }
        }
        rows = next
        loadedSignature = "\(region)|\(key)"
    }

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
        var stored = decodeList(WatchProgress.self, key: continueKey).filter { $0.id != entry.id }
        if entry.isActive {
            stored.append(entry)
        }
        save(stored, key: continueKey)
        reloadLocal()
    }

    func saveSettings(country: String, tmdbKey: String, torrentio: TorrentioOptions) {
        self.country = country
        tmdbKeyOverride = tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.torrentio = torrentio
        defaults.set(self.country, forKey: countryKey)
        defaults.set(tmdbKeyOverride, forKey: self.tmdbKey)
        if let data = try? JSONEncoder().encode(torrentio) {
            defaults.set(data, forKey: torrentioKey)
        }
        loadedSignature = ""
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

    private static var bundledTMDBKey: String {
        guard let url = Bundle.main.url(forResource: "LocalSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = object["TMDB_API_KEY"] as? String else {
            return ""
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func placeholderRows(message: String) -> [CatalogRow] {
        [CatalogRow(id: "imdb", title: "IMDb Top 100", items: [], message: message)]
            + TMDBClient.providers.map {
                CatalogRow(id: $0.id, title: $0.name, items: [], message: message)
            }
    }
}
