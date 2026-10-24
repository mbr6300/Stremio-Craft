import Foundation

struct MediaItem: Identifiable, Hashable, Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String
    var overview: String
    var posterURL: URL?
    var backdropURL: URL?
    var year: Int?
    var rating: Double?
    /// Bekannt bei Titeln aus IMDb-basierten Listen; sonst über TMDB nachgeschlagen.
    var imdbId: String?

    var id: String { "\(normalizedType)-\(tmdbId)" }

    var normalizedType: String {
        mediaType == "series" || mediaType == "tv" ? "tv" : "movie"
    }

    var yearText: String {
        year.map(String.init) ?? ""
    }
}

struct SeasonInfo: Identifiable, Hashable {
    var seasonNumber: Int
    var name: String
    var episodeCount: Int
    var id: Int { seasonNumber }
}

struct EpisodeInfo: Identifiable, Hashable {
    var seasonNumber: Int
    var episodeNumber: Int
    var name: String
    var overview: String
    var stillURL: URL?
    var runtime: Int?
    /// Ausstrahlung ("yyyy-MM-dd"); in der Zukunft = noch nicht verfügbar.
    var airDate: String?
    var id: String { "\(seasonNumber)-\(episodeNumber)" }

    var isAired: Bool {
        guard let airDate, airDate.count >= 10 else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return airDate <= formatter.string(from: Date())
    }
    /// Ausstrahlungsdatum lesbar, z. B. „12. März 2026“.
    var airDateText: String? {
        guard let airDate, airDate.count >= 10 else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: String(airDate.prefix(10))) else { return nil }
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "de_CH")))
    }
    var label: String { String(format: "S%02dE%02d", seasonNumber, episodeNumber) }
}

struct TitleDetail {
    var media: MediaItem
    var imdbId: String?
    var runtime: Int?
    var genres: [String]
    var seasons: [SeasonInfo]
}

struct StreamCandidate: Identifiable, Hashable {
    var id: String
    var title: String
    var quality: String
    var size: String
    var infoHash: String?
    var fileIndex: Int
    var directURL: URL?
    var rank: Int
    /// Torrentio markiert sofort verfügbare Real-Debrid-Streams mit `[RD+]`.
    var isCached = false
    var fileName: String?
}

/// Eine Zeile auf der Startseite. Reihenfolge und Sichtbarkeit sind in den Einstellungen änderbar.
struct CatalogEntry: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var source: CatalogSource
    var enabled = true

    var isBuiltIn: Bool {
        if case .url = source { return false }
        return true
    }

    /// Reihen aus den eigenen Favoriten; leer werden sie ausgeblendet.
    var isPersonal: Bool { source == .favorites || source == .loved || source == .recommendations }

    /// Erhöhen, wenn neue Standardreihen dazukommen; bestehende Einstellungen werden dann ergänzt.
    static let defaultsVersion = 5

    static let defaults: [CatalogEntry] = [
        CatalogEntry(id: "favorites", title: "Meine Liste", source: .favorites),
        CatalogEntry(id: "loved", title: "♥ Lieblingstitel", source: .loved),
        CatalogEntry(id: "recommended", title: "Empfohlen für dich", source: .recommendations),
        CatalogEntry(id: "new-on-providers", title: "Neu & im Trend auf deinen Plattformen", source: .newOnProviders),
        CatalogEntry(id: "trending-movies", title: "Im Trend · Filme", source: .trending("movie")),
        CatalogEntry(id: "trending-series", title: "Im Trend · Serien", source: .trending("tv")),
        CatalogEntry(id: "imdb-top", title: "IMDb Top 250 · Filme", source: .url("https://www.imdb.com/chart/top/")),
        CatalogEntry(id: "imdb-top-tv", title: "IMDb Top 250 · Serien", source: .url("https://www.imdb.com/chart/toptv/")),
        CatalogEntry(id: "imdb-popular-movies", title: "Beliebt auf IMDb · Filme", source: .url("https://www.imdb.com/chart/moviemeter/")),
        CatalogEntry(id: "imdb-popular-series", title: "Beliebt auf IMDb · Serien", source: .url("https://www.imdb.com/chart/tvmeter/"))
    ] + TMDBClient.providers.map {
        CatalogEntry(id: $0.id, title: $0.name, source: .provider($0.id))
    }

    /// Ergänzt neue Standardreihen an ihrer Standardposition, ohne eigene Reihenfolge,
    /// Sichtbarkeit oder eigene Listen anzutasten.
    static func migrate(_ stored: [CatalogEntry]) -> [CatalogEntry] {
        // v1 hatte eine gemischte Trend-Reihe; sie wird durch Filme/Serien ersetzt.
        var result = stored.filter { $0.id != "trending" }
        let renamed = ["imdb-top": ("IMDb Top 250", "IMDb Top 250 · Filme")]
        for index in result.indices {
            if let (old, new) = renamed[result[index].id], result[index].title == old {
                result[index].title = new
            }
        }
        for (position, entry) in defaults.enumerated() where !result.contains(where: { $0.id == entry.id }) {
            result.insert(entry, at: min(position, result.count))
        }
        return result
    }
}

enum CatalogSource: Codable, Hashable {
    /// Gemischter TMDB-Trend (nur noch für alte Einstellungen).
    case tmdbTrending
    /// TMDB-Trend der Woche für "movie" oder "tv".
    case trending(String)
    case provider(String)
    /// Die eigenen Favoriten.
    case favorites
    /// ♥ Lieblingstitel.
    case loved
    /// TMDB-Empfehlungen auf Basis der Favoriten.
    case recommendations
    /// Neue, populäre Titel quer über alle Streaming-Anbieter.
    case newOnProviders
    /// IMDb-Liste/-Chart, MDBList, TMDB-Liste, Stremio-Addon-Katalog oder beliebige Seite mit IMDb-IDs.
    case url(String)
}

/// Region für Kataloge und Streaming-Verfügbarkeit (TMDB `watch_region`).
struct Region: Identifiable, Hashable {
    var id: String
    var name: String
    var flag: String

    static let all: [Region] = [
        Region(id: "CH", name: "Schweiz", flag: "🇨🇭"),
        Region(id: "DE", name: "Deutschland", flag: "🇩🇪"),
        Region(id: "AT", name: "Österreich", flag: "🇦🇹"),
        Region(id: "US", name: "USA", flag: "🇺🇸"),
        Region(id: "GB", name: "Grossbritannien", flag: "🇬🇧"),
        Region(id: "FR", name: "Frankreich", flag: "🇫🇷"),
        Region(id: "IT", name: "Italien", flag: "🇮🇹")
    ]

    static func named(_ id: String) -> Region {
        all.first { $0.id == id } ?? Region(id: id, name: id, flag: "🌐")
    }
}

/// Filter der Startseite.
enum MediaFilter: String, CaseIterable, Identifiable {
    case all, movie, tv
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Alle"
        case .movie: return "Filme"
        case .tv: return "Serien"
        }
    }

    func matches(_ item: MediaItem) -> Bool {
        self == .all || item.normalizedType == rawValue
    }
}

enum PlayerChoice: String, Codable, CaseIterable, Identifiable {
    case infuse
    case vlc
    case builtIn
    var id: String { rawValue }

    /// Auf dem Mac ist Infuse kaum verbreitet; der integrierte Player (KSPlayer) spielt dort alles.
    static var platformDefault: PlayerChoice { Platform.isMac ? .builtIn : .infuse }

    var label: String {
        switch self {
        case .infuse: return "Infuse"
        case .vlc: return "VLC"
        case .builtIn: return "Integrierter Player (MKV & MP4)"
        }
    }
}

struct WatchProgress: Identifiable, Hashable, Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String
    var overview: String
    var posterURL: URL?
    var year: Int?
    var position: Double
    var duration: Double?
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var updatedAt: Date
    /// Serie: vorherige Folge fertig, diese ist die nächste (noch nicht begonnen).
    var upNext: Bool?

    var id: String { "stream:\(tmdbId):\(mediaType == "tv" ? "tv" : "movie")" }

    var media: MediaItem {
        MediaItem(
            tmdbId: tmdbId,
            mediaType: mediaType,
            title: title,
            overview: overview,
            posterURL: posterURL,
            backdropURL: nil,
            year: year,
            rating: nil
        )
    }

    var isActive: Bool {
        if upNext == true { return true }
        guard position >= 15 else { return false }
        guard let duration, duration > 0 else { return true }
        return position < duration * 0.92
    }

    var subtitle: String {
        var parts: [String] = []
        if upNext == true { parts.append("Als Nächstes") }
        if let season, let episode {
            parts.append(String(format: "S%02dE%02d", season, episode))
        }
        // Zeit vor dem Folgentitel, damit sie bei langen Titeln nicht abgeschnitten wird.
        if upNext != true { parts.append(Self.clock(position)) }
        if let episodeTitle, !episodeTitle.isEmpty {
            parts.append(episodeTitle)
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct FavoriteItem: Identifiable, Hashable, Codable {
    var tmdbId: Int
    var mediaType: String
    var title: String
    var overview: String
    var posterURL: URL?
    var year: Int?
    var backdropURL: URL?
    var rating: Double?
    var imdbId: String?
    var id: String { "\(mediaType)-\(tmdbId)" }

    var media: MediaItem {
        MediaItem(
            tmdbId: tmdbId,
            mediaType: mediaType,
            title: title,
            overview: overview,
            posterURL: posterURL,
            backdropURL: backdropURL,
            year: year,
            rating: rating,
            imdbId: imdbId
        )
    }
}

struct PlaybackRequest: Hashable, Codable {
    var media: MediaItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var resumeSeconds: Double
    var autoStart: Bool
    /// Laufzeit laut TMDB in Sekunden. Infuse meldet nur die Position zurück.
    var durationHint: Double?

    var episodeLabel: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }
}

enum AppRoute: Hashable {
    case detail(MediaItem)
    case play(PlaybackRequest)
    case lists
    /// Vollständige TMDB-Liste (Genre, Plattform-Reihe …) als Raster.
    case discover(DiscoverQuery)
    /// Seite einer Streaming-Plattform (Netflix, Disney+ …).
    case provider(String)
    /// Vollständige Startseiten-Reihe als Raster.
    case row(String)
    /// Ordner der eigenen Mediathek (WebDAV-`href`, Anzeigename).
    case mediaFolder(String, String)
}

extension AppRoute {
    /// Beschriftung für „alles anzeigen“: bei Plattformen deren Name, sonst der Name der Liste.
    func seeAllTitle(catalogs: [CatalogEntry]) -> String {
        switch self {
        case .provider(let id):
            return providerTitle(id) ?? "Alle anzeigen"
        case .row(let id):
            guard let entry = catalogs.first(where: { $0.id == id }) else { return "Alle anzeigen" }
            if case .provider(let providerId) = entry.source, let title = providerTitle(providerId) { return title }
            return "Ganze Liste „\(entry.title)“ anzeigen"
        case .discover(let query):
            return "Ganze Liste „\(query.title)“ anzeigen"
        default:
            return "Alle anzeigen"
        }
    }

    private func providerTitle(_ id: String) -> String? {
        TMDBClient.providers.first { $0.id == id }.map { "Ganzes \($0.name)-Angebot anzeigen" }
    }
}

struct CatalogRow: Identifiable, Equatable {
    var id: String
    var title: String
    var items: [MediaItem]
    var message: String?
    var isLoading = false
}

enum AppFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        }
    }
}

struct TorrentioOptions: Equatable, Codable {
    var providers: String = ""
    var sort: String = ""
    var qualityFilter: String = ""
    var language: String = ""
}
